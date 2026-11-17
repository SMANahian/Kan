import Foundation
import KanCore

/// Turns a recorded call into a transcript (`Transcribing`).
///
/// Per track (mic = "me", call app = "them"): load 16 kHz mono → echo gate on the mic → Silero VAD →
/// diarize "them" → language-ID units ≤ 15 s, restricted to {bn, en} and smoothed per speaker →
/// decode chunks per language (English with turbo, Bangla with the Bangla model; stock models get
/// shorter Bangla chunks) → post-process → assemble speakers, echo flags (only where echo is
/// plausible: loudspeaker output or a measured echo delay) and ids. `echoSuppression` off skips
/// both echo steps.
///
/// Models load one at a time (language ID → English → Bangla, reused when it is the same file) and
/// are freed before the next one loads and when the job ends. Calls are serialized: a second
/// `transcribe` waits for the first. Cancelling the calling task stops within one chunk and throws
/// `TranscriptionError.cancelled`. A call without speech yields an empty transcript, not an error.
///
/// Thread-safety: safe to call from any task; all mutable job state lives in a per-call job object,
/// and whisper.cpp work is confined to that job's serial worker queue.
public final class TranscriptionPipeline: Transcribing, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var threads: Int32 = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        public var useGPU = true
        public var vad = VADParameters()
        public var routing = LanguageRouting()
        /// `modelsDirectory` is replaced by the model store's FluidAudio directory.
        public var diarization = SpeakerDiarizer.Configuration()
        /// A Bangla sentence with English terms: stock Whisper then keeps English terms in Latin script
        /// inside Bangla. Guarded by a repetition check (falls back to the unprompted result). nil disables.
        public var codeSwitchPrompt: String? = "আজকের meeting-এ আমরা কিছু technical বিষয় নিয়ে আলোচনা করবো।"
        /// Gain for mic frames identified as loudspeaker echo (0.1 ≈ −20 dB).
        public var echoAttenuation: Float = 0.1
        /// A truncated chunk is halved and retried up to this many times.
        public var maxTruncationSplits = 3

        public init() {}
    }

    public let models: ModelStore
    public let configuration: Configuration
    private let jobs = AsyncLock()

    public init(models: ModelStore = ModelStore(), configuration: Configuration = Configuration()) {
        self.models = models
        self.configuration = configuration
    }

    /// Initial prompt: the user's vocabulary (only Bengali-script terms for the Bangla fine-tune, whose
    /// tokenizer lost English) followed by the code-switch sentence for stock-model Bangla.
    public static func initialPrompt(vocabulary: String, language: String, spec: ModelSpec,
                                     codeSwitch: String?) -> String? {
        var terms = vocabulary.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if language == "bn" && spec.banglaTokenizer { terms = terms.filter(TextPostProcessor.containsBengali) }
        var parts: [String] = []
        var glossary = ""
        for term in terms where glossary.count + term.count < 300 {
            glossary += glossary.isEmpty ? term : ", \(term)"
        }
        if !glossary.isEmpty { parts.append(glossary + (language == "bn" ? "।" : ".")) }
        if let codeSwitch, !codeSwitch.isEmpty { parts.append(codeSwitch) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Loads (then frees) the models a transcription with `settings` would use — the Whisper models
    /// its choices resolve to and, when speakers are separated, the speaker models — so first-use
    /// costs (Metal kernel compilation ~6 s, the CoreML compile of the speaker models ~16 s, both paid
    /// again after an app update) don't land on the first real call. Optional; call when the Mac is
    /// idle (it briefly needs the memory of the largest model). Waits for, and is waited on by,
    /// `transcribe`.
    public func warmUp(settings: KanSettings) async {
        let started = Date()
        _ = try? await jobs.run {
            let resolved = models.resolveModels(general: settings.generalModelID, english: settings.englishModelID,
                                                bangla: settings.banglaModelID)
            var diarization = configuration.diarization
            diarization.modelsDirectory = models.fluidAudioDirectory
            diarization.allowDownload = false
            if settings.diarize, SpeakerDiarizer.modelsInstalled(at: diarization.modelsDirectory) {
                do {
                    try await SpeakerDiarizer(configuration: diarization).prepareModels()
                } catch {
                    KanLog.warning("Warm-up of the speaker models failed: \(error.localizedDescription)", category: "transcribe")
                }
            }
            let specs = [resolved.general, resolved.english, resolved.bangla].compactMap { $0 }
            var seen = Set<String>()
            let worker = SerialWorker(label: "com.nahian.Kan.transcribe.warmup")
            for spec in specs where seen.insert(spec.id).inserted {
                let url = models.location(of: spec)
                let useGPU = configuration.useGPU
                do {
                    _ = try await worker.run { _ in try WhisperEngine(spec: spec, url: url, useGPU: useGPU).loadSeconds }
                } catch {
                    KanLog.warning("Warm-up of \(spec.id) failed: \(error.localizedDescription)", category: "transcribe")
                }
            }
        }
        KanLog.info(String(format: "Transcription models warmed up in %.1f s", Date().timeIntervalSince(started)),
                    category: "transcribe")
    }

    /// `warmUp(settings:)` with default settings: the "auto" models and the speaker models.
    public func warmUp() async {
        await warmUp(settings: KanSettings())
    }

    public func transcribe(_ request: TranscriptionRequest,
                           progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> TranscriptionOutput {
        try await jobs.run {
            let job = TranscriptionJob(request: request, models: models, configuration: configuration, progress: progress)
            do {
                return try await job.run()
            } catch let error as TranscriptionError {
                KanLog.error("Transcription of \(request.callID) failed: \(error.localizedDescription)", category: "transcribe")
                throw error
            } catch {
                if error is CancellationError || Task.isCancelled {
                    KanLog.info("Transcription of \(request.callID) cancelled", category: "transcribe")
                    throw TranscriptionError.cancelled
                }
                KanLog.error("Transcription of \(request.callID) failed: \(error.localizedDescription)", category: "transcribe")
                throw TranscriptionError.engineFailed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Job

/// Maps a stage-local fraction onto overall progress. Sendable so worker threads can report.
private struct ProgressMapper: Sendable {
    let stage: PipelineStage
    let base: Double
    let weight: Double
    let sink: @Sendable (PipelineProgress) -> Void

    func callAsFunction(_ fraction: Double, _ message: String? = nil) {
        sink(PipelineProgress(stage: stage, fraction: min(1, base + weight * min(1, max(0, fraction))), message: message))
    }
}

/// Owns at most one loaded whisper model. Confined to the job's worker queue.
private final class EngineHost {
    private(set) var engine: WhisperEngine?
    private(set) var loadSeconds = 0.0

    func engine(for spec: ModelSpec, url: URL, useGPU: Bool) throws -> WhisperEngine {
        if let engine, engine.url == url, engine.isUsable { return engine }
        engine = nil   // free the previous (or an unusable) model before loading the next
        let loaded = try WhisperEngine(spec: spec, url: url, useGPU: useGPU)
        loadSeconds += loaded.loadSeconds
        engine = loaded
        return loaded
    }

    func unload() { engine = nil }
}

private struct Track: Sendable {
    let channel: AudioChannel
    var samples: [Float]
    var probabilities = SpeechProbabilities.empty
    var speech: [TimeRange] = []

    init(channel: AudioChannel, samples: [Float]) {
        self.channel = channel
        self.samples = samples
    }

    var duration: Double { Double(samples.count) / AudioLoader.sampleRate }
    var speechSeconds: Double { speech.reduce(0) { $0 + $1.duration } }
}

/// A track's language-ID units and the diarized speaker of each (nil on the mic track, or without
/// diarization).
private struct TrackUnits: Sendable {
    let track: Track
    let ranges: [TimeRange]
    let speakers: [String?]
}

/// What decoding one chunk produced, merged into the job's counters on the async side.
private struct ChunkOutcome {
    var segments: [RecognizedSegment] = []
    var truncationSplits = 0
    var promptFallbacks = 0
    var droppedHallucinations = 0
    var droppedNoSpeech = 0

    mutating func absorb(_ other: ChunkOutcome) {
        segments += other.segments
        truncationSplits += other.truncationSplits
        promptFallbacks += other.promptFallbacks
        droppedHallucinations += other.droppedHallucinations
        droppedNoSpeech += other.droppedNoSpeech
    }
}

private final class TranscriptionJob {
    let request: TranscriptionRequest
    let models: ModelStore
    let configuration: TranscriptionPipeline.Configuration
    let sink: @Sendable (PipelineProgress) -> Void
    let worker = SerialWorker(label: "com.nahian.Kan.transcribe")
    /// Only touched inside `worker.run`.
    let host = EngineHost()

    var warnings: [String] = []
    var stats: [String: Double] = [:]
    var modelsUsed: [String] = []
    private var stageEnd = 0.0
    private var progress: ProgressMapper

    init(request: TranscriptionRequest, models: ModelStore, configuration: TranscriptionPipeline.Configuration,
         progress: @escaping @Sendable (PipelineProgress) -> Void) {
        self.request = request
        self.models = models
        self.configuration = configuration
        sink = progress
        self.progress = ProgressMapper(stage: .preparing, base: 0, weight: 0, sink: progress)
    }

    private func begin(_ stage: PipelineStage, weight: Double, _ message: String? = nil) {
        progress = ProgressMapper(stage: stage, base: stageEnd, weight: weight, sink: sink)
        stageEnd = min(1, stageEnd + weight)
        progress(0, message)
    }

    /// Starts `stage` when it has work; otherwise just moves overall progress past it.
    private func begin(_ stage: PipelineStage, weight: Double, if hasWork: Bool) {
        if hasWork {
            begin(stage, weight: weight)
        } else {
            stageEnd = min(1, stageEnd + weight)
        }
    }

    private func use(_ id: String) {
        if !modelsUsed.contains(id) { modelsUsed.append(id) }
    }

    private func warn(_ message: String) {
        warnings.append(message)
        KanLog.warning("\(request.callID): \(message)", category: "transcribe")
    }

    func run() async throws -> TranscriptionOutput {
        do {
            let output = try await body()
            _ = try? await worker.run { [host] _ in host.unload() }
            return output
        } catch {
            _ = try? await worker.run { [host] _ in host.unload() }
            throw error
        }
    }

    private func body() async throws -> TranscriptionOutput {
        let started = Date()
        begin(.preparing, weight: 0)
        let resolved = models.resolveModels(general: request.generalModelID, english: request.englishModelID,
                                            bangla: request.banglaModelID)
        resolved.notes.forEach(warn)

        // Tracks share one clock starting at call start (the recorder pads gaps with silence).
        guard request.meFile != nil || request.themFile != nil else { throw TranscriptionError.noAudio }
        var me = try await loadTrack(.me, request.meFile)
        var them = try await loadTrack(.them, request.themFile)
        guard me != nil || them != nil else {
            throw TranscriptionError.audioUnreadable(warnings.last ?? "no track could be read")
        }
        let callDuration = max(me?.duration ?? 0, them?.duration ?? 0)
        stats["seconds.audio"] = callDuration
        if let them, them.duration >= 10, AudioLoader.isDigitalSilence(them.samples) {
            warn("The call audio track is completely silent — macOS may be blocking System Audio Recording for Kan.")
        }

        guard let vadSpec = resolved.vad else { throw TranscriptionError.modelMissing("Silero VAD (\(ModelCatalog.vadID))") }

        // Echo handling (`echoSuppression`; off means the mic track is never touched). The gate runs
        // on every two-track call — it changes nothing unless it measures a speaker → mic delay — but
        // the transcript dedup only where echo is plausible: the recorder saw a loudspeaker output or
        // the gate measured a delay. Headphone calls can't contain echo, and people repeat each
        // other's words all the time.
        var echoLag: Double?
        if request.echoSuppression, let mic = me, let call = them {
            let attenuation = configuration.echoAttenuation
            let (gated, report) = try await worker.run { _ -> ([Float], EchoGate.Report) in
                var samples = mic.samples
                let report = EchoGate.suppress(mic: &samples, call: call.samples, attenuation: attenuation)
                return (samples, report)
            }
            if let lag = report.lagSeconds {
                me?.samples = gated
                echoLag = lag
                stats["echo.lagMs"] = lag * 1000
                stats["echo.correlation"] = Double(report.correlation)
                stats["echo.gatedFraction"] = report.flaggedFraction
                stats["echo.mutedSeconds"] = report.mutedRanges.reduce(0) { $0 + $1.duration }
                KanLog.info("Echo gate: lag \(Int(lag * 1000)) ms, \(String(format: "%.1f", report.flaggedFraction * 100)) % of mic frames flagged, "
                            + String(format: "%.1f s muted", stats["echo.mutedSeconds"] ?? 0), category: "transcribe")
            }
        }
        // The call → mic lags the transcript dedup considers (nil: no dedup).
        var echo: ClosedRange<Double>?
        if request.echoSuppression, me != nil, them != nil, request.loudspeakerSuspected || echoLag != nil {
            echo = echoLag.map { $0...$0 } ?? EchoDedup.unmeasuredLag
        }

        // 1. Speech detection.
        begin(.detectingSpeech, weight: 0.05)
        var stageStart = Date()
        let vadURL = models.location(of: vadSpec)
        let parameters = configuration.vad
        let meSamples = me?.samples, themSamples = them?.samples
        let vadProgress = progress
        let totalSamples = Double((meSamples?.count ?? 0) + (themSamples?.count ?? 0))
        let (meProbabilities, themProbabilities) = try await worker.run { flag -> (SpeechProbabilities?, SpeechProbabilities?) in
            let detector = try VoiceActivityDetector(modelURL: vadURL)
            let meShare = Double(meSamples?.count ?? 0) / max(1, totalSamples)
            let first = try meSamples.map { try detector.probabilities($0, cancel: flag) { vadProgress($0 * meShare) } }
            let second = try themSamples.map {
                try detector.probabilities($0, cancel: flag) { vadProgress(meShare + $0 * (1 - meShare)) }
            }
            return (first, second)
        }
        func applySpeech(_ probabilities: SpeechProbabilities?, to track: inout Track?) {
            guard var updated = track, let probabilities else { return }
            updated.probabilities = probabilities
            updated.speech = SpeechSegmenter.segments(from: probabilities, parameters: parameters,
                                                      audioDuration: updated.duration)
            track = updated
        }
        applySpeech(meProbabilities, to: &me)
        applySpeech(themProbabilities, to: &them)
        use(vadSpec.id)
        stats["seconds.vad"] = Date().timeIntervalSince(stageStart)
        stats["speech.me"] = me?.speechSeconds ?? 0
        stats["speech.them"] = them?.speechSeconds ?? 0
        let tracks = [me, them].compactMap { $0 }.filter { !$0.speech.isEmpty }
        guard !tracks.isEmpty else {
            KanLog.info("\(request.callID): no speech found", category: "transcribe")
            return finish(segmentsFrom: [], [], diarization: nil, hasMe: me != nil, echo: nil, started: started)
        }

        // 2. Speaker separation on the remote track.
        try Task.checkCancellation()
        var diarization: SpeakerDiarization?
        let remoteSpeech = request.diarize ? them.flatMap { $0.speech.isEmpty ? nil : $0 } : nil
        begin(.separatingSpeakers, weight: 0.10, if: remoteSpeech != nil)
        if let remote = remoteSpeech { diarization = await diarize(remote) }

        // 3. Language identification.
        try Task.checkCancellation()
        let lidSpec = resolved.general ?? resolved.english
        var mode = request.languageMode
        if mode == .auto && lidSpec == nil {
            guard resolved.bangla != nil else { throw TranscriptionError.modelMissing("Whisper large-v3 (q5_0)") }
            warn("No general Whisper model is installed — all speech was treated as Bangla.")
            mode = .bangla
        }
        begin(.identifyingLanguage, weight: 0.10, if: mode == .auto)
        stageStart = Date()
        var units: [AudioChannel: [LanguageUnit]] = [:]
        let lidLimits = ChunkLimits(banglaTokenizer: false)
        // Remote speech is cut where the speaker changes, so every chunk has one voice (the Bangla
        // fine-tune has no word timestamps to split a chunk by speaker afterwards).
        let turns = diarization?.turns ?? []
        let changes = ChunkPlanner.speakerChangePoints(turns)
        let planned = tracks.map { track -> TrackUnits in
            let speech = track.channel == .them ? ChunkPlanner.cut(track.speech, at: changes) : track.speech
            let ranges = ChunkPlanner.languageUnits(speech: speech, probabilities: track.probabilities, limits: lidLimits)
            // The mic is one voice; a remote unit belongs to the diarized speaker it overlaps most.
            let speakers = ranges.map { track.channel == .them ? TranscriptAssembler.nearestSpeaker(to: $0, turns: turns) : nil }
            return TrackUnits(track: track, ranges: ranges, speakers: speakers)
        }
        let unitCount = planned.reduce(0) { $0 + $1.ranges.count }
        stats["units.lid"] = Double(unitCount)
        if mode == .auto, let lidSpec {
            use(lidSpec.id)
            let evidence = try await identifyLanguages(planned, spec: lidSpec, total: unitCount)
            for (channel, unitEvidence) in evidence {
                let decisions = LanguageRouter.decide(unitEvidence, mode: .auto, routing: configuration.routing)
                units[channel] = zip(unitEvidence, decisions).map {
                    LanguageUnit(range: $0.range, language: $1.language, speaker: $0.speaker)
                }
                stats["units.inherited", default: 0] += Double(decisions.filter(\.inherited).count)
            }
        } else {
            let language = mode == .bangla ? "bn" : "en"
            for plan in planned {
                units[plan.track.channel] = zip(plan.ranges, plan.speakers).map {
                    LanguageUnit(range: $0, language: language, speaker: $1)
                }
            }
        }
        stats["seconds.lid"] = Date().timeIntervalSince(stageStart)

        // 4–5. Decoding, English first, then Bangla.
        let englishSpec = resolved.english ?? resolved.general
        let banglaSpec = resolved.bangla ?? resolved.general ?? resolved.english
        let limits = ChunkLimits(banglaTokenizer: banglaSpec?.banglaTokenizer ?? false)
        var english: [(Track, DecodeChunk)] = []
        var bangla: [(Track, DecodeChunk)] = []
        for track in tracks {
            for chunk in ChunkPlanner.decodeChunks(units: units[track.channel] ?? [], probabilities: track.probabilities, limits: limits) {
                if chunk.language == "bn" { bangla.append((track, chunk)) } else { english.append((track, chunk)) }
            }
        }
        stats["chunks.en"] = Double(english.count)
        stats["chunks.bn"] = Double(bangla.count)
        if !english.isEmpty && englishSpec == nil {
            throw TranscriptionError.modelMissing("Whisper large-v3-turbo or large-v3 (English)")
        }
        if !bangla.isEmpty && banglaSpec == nil { throw TranscriptionError.modelMissing("the Bangla model (\(ModelCatalog.autoPreference[.bangla]?.first ?? ""))") }
        if let banglaSpec, !bangla.isEmpty, !banglaSpec.banglaTokenizer,
           !models.isInstalled("bengali-medium-q8_0"), !models.isInstalled("bengali-medium-q5_0") {
            warn("Bangla model not installed — used \(banglaSpec.displayName) with short chunks. Download the Bangla model for much better Bangla.")
        }

        let englishCost = english.reduce(0) { $0 + $1.1.range.duration }
        let banglaCost = 4 * bangla.reduce(0) { $0 + $1.1.range.duration }
        let decodeWeight = 0.70
        let englishWeight = englishCost + banglaCost > 0 ? decodeWeight * englishCost / (englishCost + banglaCost) : decodeWeight / 2
        var outcome = ChunkOutcome()

        try Task.checkCancellation()
        begin(.transcribingEnglish, weight: englishWeight, if: !english.isEmpty)
        stageStart = Date()
        if let englishSpec, !english.isEmpty { outcome.absorb(try await decode(english, spec: englishSpec)) }
        stats["seconds.english"] = Date().timeIntervalSince(stageStart)

        begin(.transcribingBangla, weight: decodeWeight - englishWeight, if: !bangla.isEmpty)
        stageStart = Date()
        if let banglaSpec, !bangla.isEmpty { outcome.absorb(try await decode(bangla, spec: banglaSpec)) }
        stats["seconds.bangla"] = Date().timeIntervalSince(stageStart)

        stats["fallbacks.truncation"] = Double(outcome.truncationSplits)
        stats["fallbacks.prompt"] = Double(outcome.promptFallbacks)
        stats["fallbacks"] = Double(outcome.truncationSplits + outcome.promptFallbacks) + (stats["fallbacks.diarization"] ?? 0)
        stats["dropped.hallucination"] = Double(outcome.droppedHallucinations)
        stats["dropped.noSpeech"] = Double(outcome.droppedNoSpeech)
        stats["seconds.load"] = (try? await worker.run { [host] _ in host.loadSeconds }) ?? 0

        let meSegments = outcome.segments.filter { $0.channel == .me }
        let themSegments = outcome.segments.filter { $0.channel == .them }
        return finish(segmentsFrom: meSegments, themSegments, diarization: diarization, hasMe: me != nil,
                      echo: echo, started: started)
    }

    // MARK: Steps

    private func loadTrack(_ channel: AudioChannel, _ url: URL?) async throws -> Track? {
        guard let url else { return nil }
        do {
            let samples = try await worker.run { _ in try AudioLoader.load(url) }
            return Track(channel: channel, samples: samples)
        } catch let error as TranscriptionError {
            warn("Could not read the \(channel == .me ? "microphone" : "call audio") track: \(error.localizedDescription)")
            return nil
        }
    }

    private func diarize(_ track: Track) async -> SpeakerDiarization? {
        var configuration = self.configuration.diarization
        configuration.modelsDirectory = models.fluidAudioDirectory
        guard SpeakerDiarizer.modelsInstalled(at: configuration.modelsDirectory) || configuration.allowDownload else {
            warn("Speaker models are not installed — all remote speech is attributed to one speaker.")
            return nil
        }
        do {
            let maxSpeakers = request.maxRemoteSpeakers.flatMap { $0 > 0 ? $0 : nil }
            let result = try await SpeakerDiarizer(configuration: configuration)
                .diarize(track.samples, speechSeconds: track.speechSeconds, maxSpeakers: maxSpeakers)
            use(result.method == .hybrid ? "fluidaudio-sortformer+wespeaker" : "fluidaudio-vbx")
            stats["seconds.diarization"] = result.seconds
            stats["speakers.diarized"] = Double(Set(result.turns.map(\.speaker)).count)
            if result.usedFallback { stats["fallbacks.diarization"] = 1 }
            return result
        } catch {
            if Task.isCancelled { return nil }
            warn("Speaker separation failed (\(error.localizedDescription)) — all remote speech is attributed to one speaker.")
            return nil
        }
    }

    /// Language evidence per unit. A unit shorter than `routing.minimumDuration` takes its language
    /// from its own speaker's confident units, so it skips the (≈0.5 s) encoder pass when that speaker
    /// has one. It is measured otherwise — a participant who only gives short answers would else get
    /// another voice's language, and a track without any confident unit has nothing to inherit.
    private func identifyLanguages(_ planned: [TrackUnits], spec: ModelSpec,
                                   total: Int) async throws -> [(AudioChannel, [LanguageEvidence])] {
        let url = models.location(of: spec)
        let useGPU = configuration.useGPU, threads = configuration.threads
        let routing = configuration.routing
        let report = progress
        let result = try await worker.run { [host] flag -> ([(AudioChannel, [LanguageEvidence])], Int) in
            try flag.check()
            let engine = try host.engine(for: spec, url: url, useGPU: useGPU)
            var done = 0, measured = 0
            func measure(_ index: Int, of plan: TrackUnits) throws -> LanguageEvidence {
                try flag.check()
                let range = plan.ranges[index]
                let probabilities = try engine.languageProbabilities(plan.track.samples.samples(in: range), threads: threads)
                measured += 1
                return LanguageRouter.evidence(range: range, speaker: plan.speakers[index],
                                               weakBanglaLanguageID: spec.weakBanglaLanguageID) { code in
                    WhisperEngine.languageID(code).map { Double(probabilities[$0]) } ?? 0
                }
            }
            let evidence = try planned.map { plan -> (AudioChannel, [LanguageEvidence]) in
                var units: [LanguageEvidence?] = plan.ranges.map { _ in nil }
                for index in plan.ranges.indices where plan.ranges[index].duration >= routing.minimumDuration {
                    units[index] = try measure(index, of: plan)
                    done += 1
                    report(Double(done) / Double(max(1, total)))
                }
                let settled = LanguageRouter.settledSpeakers(units.compactMap { $0 }, routing: routing)
                for index in plan.ranges.indices where units[index] == nil {
                    units[index] = settled.contains(plan.speakers[index])
                        ? LanguageRouter.undecided(plan.ranges[index], speaker: plan.speakers[index])
                        : try measure(index, of: plan)
                    done += 1
                    report(Double(done) / Double(max(1, total)))
                }
                return (plan.track.channel, units.enumerated().map {
                    $1 ?? LanguageRouter.undecided(plan.ranges[$0], speaker: plan.speakers[$0])
                })
            }
            return (evidence, measured)
        }
        stats["units.lidMeasured"] = Double(result.1)
        return result.0
    }

    private func decode(_ chunks: [(Track, DecodeChunk)], spec: ModelSpec) async throws -> ChunkOutcome {
        use(spec.id)
        let url = models.location(of: spec)
        let total = chunks.reduce(0) { $0 + $1.1.range.duration }
        var done = 0.0
        var outcome = ChunkOutcome()
        for (index, (track, chunk)) in chunks.enumerated() {
            try Task.checkCancellation()
            let options = decodeOptions(language: chunk.language, spec: spec, codeSwitch: true)
            let plain = decodeOptions(language: chunk.language, spec: spec, codeSwitch: false)
            let maxSplits = configuration.maxTruncationSplits
            let useGPU = configuration.useGPU
            let codeSwitchPrompt = configuration.codeSwitchPrompt
            let result = try await worker.run { [host] flag in
                try flag.check()
                let engine = try host.engine(for: spec, url: url, useGPU: useGPU)
                return try Self.decode(chunk, track: track, engine: engine, options: options, plainOptions: plain,
                                       codeSwitchPrompt: codeSwitchPrompt, maxSplits: maxSplits, depth: 0, cancel: flag)
            }
            outcome.absorb(result)
            done += chunk.range.duration
            progress(done / max(total, 1e-9), "\(index + 1) of \(chunks.count)")
        }
        return outcome
    }

    /// Decodes one chunk on the worker queue: prompt guard, truncation retry, post-processing.
    private static func decode(_ chunk: DecodeChunk, track: Track, engine: WhisperEngine, options: WhisperDecodeOptions,
                               plainOptions: WhisperDecodeOptions, codeSwitchPrompt: String?, maxSplits: Int, depth: Int,
                               cancel: CancellationFlag) throws -> ChunkOutcome {
        var outcome = ChunkOutcome()
        let samples = track.samples.samples(in: chunk.range)
        var result = try engine.decode(samples, options: options, cancel: cancel)
        if options.prompt != plainOptions.prompt {
            let text = result.segments.map(\.text).joined(separator: " ")
            let leaked = codeSwitchPrompt.map { EchoDedup.similarity(text, $0) >= 0.5 } ?? false
            if result.truncated || leaked || TextPostProcessor.hasRepeatedPhrase(text) {
                result = try engine.decode(samples, options: plainOptions, cancel: cancel)
                outcome.promptFallbacks += 1
            }
        }
        if result.truncated, depth < maxSplits,
           let (first, second) = ChunkPlanner.halve(chunk.range, probabilities: track.probabilities) {
            outcome.truncationSplits += 1
            for half in [first, second] {
                var part = try decode(DecodeChunk(range: half, language: chunk.language), track: track, engine: engine,
                                      options: options, plainOptions: plainOptions, codeSwitchPrompt: codeSwitchPrompt,
                                      maxSplits: maxSplits, depth: depth + 1, cancel: cancel)
                for index in part.segments.indices where !part.segments[index].flags.contains(.truncatedRetry) {
                    part.segments[index].flags.append(.truncatedRetry)
                }
                outcome.absorb(part)
            }
            return outcome
        }
        if result.truncated {
            KanLog.warning("Chunk \(chunk.range) (\(chunk.language)) still truncated after \(depth) splits", category: "transcribe")
        }
        for segment in result.segments {
            postProcess(segment, chunk: chunk, track: track, truncated: result.truncated, into: &outcome)
        }
        return outcome
    }

    private static func postProcess(_ raw: WhisperSegment, chunk: DecodeChunk, track: Track, truncated: Bool,
                                    into outcome: inout ChunkOutcome) {
        let offset = chunk.range.start
        let range = TimeRange(offset + raw.range.start, offset + raw.range.end).clamped(to: chunk.range)
        var words = raw.words.compactMap { word -> RecognizedWord? in
            let text = TextPostProcessor.clean(word.text)
            guard !text.isEmpty else { return nil }
            let start = min(max(offset + word.start, range.start), range.end)
            return RecognizedWord(text: text, start: start, end: min(max(offset + word.end, start), range.end),
                                  probability: word.probability)
        }
        let kept = TextPostProcessor.deloopIndices(words.map(\.text))
        let collapsed = kept.count < words.count
        words = kept.map { words[$0] }
        let text = TextPostProcessor.clean(words.isEmpty ? raw.text : words.map(\.text).joined(separator: " "))

        let nearSilent = AudioLoader.rmsDecibels(track.samples.samples(in: range)) < -45
            || track.probabilities.mean(in: range) < 0.2
        if let reason = TextPostProcessor.dropReason(text: text, language: chunk.language,
                                                      noSpeechProbability: raw.noSpeechProbability,
                                                      averageLogProbability: raw.averageLogProbability,
                                                      nearSilent: nearSilent) {
            switch reason {
            case .hallucination: outcome.droppedHallucinations += 1
            case .noSpeech, .empty: outcome.droppedNoSpeech += 1
            }
            // Never the text itself: the log outlives deleted calls and gets shared for support.
            KanLog.debug("Dropped \(reason.rawValue) segment \(range) (\(chunk.language), \(text.count) characters)",
                         category: "transcribe")
            return
        }
        var flags: [SegmentFlag] = []
        if collapsed { flags.append(.hallucinationSuspect) }
        if truncated || raw.meanTokenProbability < TextPostProcessor.lowConfidenceProbability { flags.append(.lowConfidence) }
        outcome.segments.append(RecognizedSegment(channel: track.channel, range: range, text: text, language: chunk.language,
                                                  words: words, confidence: raw.meanTokenProbability, flags: flags))
    }

    private func decodeOptions(language: String, spec: ModelSpec, codeSwitch: Bool) -> WhisperDecodeOptions {
        let bangla = language == "bn"
        // Normal Bangla's 32-token entropy dips to ~2.0 with the stock tokenizer (≥ 2.6 with the
        // Bangla tokenizer), so the default 2.4 would trigger needless fallbacks.
        let entropy: Float = bangla && !spec.banglaTokenizer ? 1.8 : 2.4
        return WhisperDecodeOptions(language: language, prompt: TranscriptionPipeline.initialPrompt(
            vocabulary: request.vocabulary, language: language, spec: spec,
            codeSwitch: codeSwitch && bangla && !spec.banglaTokenizer ? configuration.codeSwitchPrompt : nil),
            entropyThreshold: entropy, threads: configuration.threads, noTimestamps: !spec.timestamps)
    }

    // MARK: Finish

    /// `echo`: the call → mic lags for the echo dedup, nil to skip it.
    private func finish(segmentsFrom me: [RecognizedSegment], _ them: [RecognizedSegment], diarization: SpeakerDiarization?,
                        hasMe: Bool, echo: ClosedRange<Double>?, started: Date) -> TranscriptionOutput {
        begin(.assembling, weight: max(0, 1 - stageEnd))
        let assembled = TranscriptAssembler.assemble(TranscriptAssembler.Input(
            me: me, them: them, turns: diarization?.turns ?? [], embeddings: diarization?.embeddings ?? [:],
            userName: request.userName, includeMe: hasMe, flagEchoes: echo != nil,
            echoLag: echo ?? EchoDedup.unmeasuredLag))
        let total = Date().timeIntervalSince(started)
        stats["seconds.total"] = total
        if let audio = stats["seconds.audio"], audio > 0 { stats["rtf"] = total / audio }
        stats["segments"] = Double(assembled.segments.count)
        stats["speakers.remote"] = Double(assembled.speakers.filter { !$0.isMe }.count)
        stats["echo.flagged"] = Double(assembled.echoSuspects)
        sink(PipelineProgress(stage: .finishing, fraction: 1))
        KanLog.info("\(request.callID): \(assembled.segments.count) segments, \(assembled.speakers.count) speakers, "
                    + "languages \(assembled.languages), \(String(format: "%.1f", total)) s for "
                    + "\(String(format: "%.1f", stats["seconds.audio"] ?? 0)) s of audio", category: "transcribe")
        return TranscriptionOutput(segments: assembled.segments, speakers: assembled.speakers, languages: assembled.languages,
                                   speakerEmbeddings: assembled.speakerEmbeddings, modelsUsed: modelsUsed,
                                   warnings: warnings, stats: stats)
    }
}
