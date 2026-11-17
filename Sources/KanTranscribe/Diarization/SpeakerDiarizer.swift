import FluidAudio
import Foundation
import KanCore

/// One stretch of speech by one (anonymous) speaker.
public struct SpeakerTurn: Sendable, Hashable, Codable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = max(start, end)
    }

    public var range: TimeRange { TimeRange(start, end) }
}

/// "Who spoke when" on the remote track.
public struct SpeakerDiarization: Sendable {
    public enum Method: String, Sendable {
        /// Sortformer turns → WeSpeaker embeddings → global AHC.
        case hybrid
        /// FluidAudio's VBx `OfflineDiarizerManager`.
        case vbx
    }

    public var turns: [SpeakerTurn]
    /// L2-normalized 256-d WeSpeaker centroid per speaker label.
    public var embeddings: [String: [Float]]
    public var method: Method
    /// The hybrid failed or was unsuitable and VBx was used instead.
    public var usedFallback: Bool
    public var seconds: Double

    public static func empty(_ method: Method) -> SpeakerDiarization {
        SpeakerDiarization(turns: [], embeddings: [:], method: method, usedFallback: false, seconds: 0)
    }
}

/// Serializes FluidAudio model loading/downloading and owns `ModelHub.offlineMode` (a process-wide
/// switch): models that are installed load with the network off; missing ones may be fetched.
/// The resting state is offline.
enum FluidAudioModelAccess {
    private static let lock = AsyncLock()

    /// FluidAudio mirrors its log lines to stderr (all of them in debug builds); keep them in the
    /// unified log only so `kan` output and Kan's own log stay clean.
    static func configureLogging() { _ = loggingConfigured }

    private static let loggingConfigured: Void = { AppLogger.mirrorsToConsole = false }()

    static func run<T>(allowNetwork: Bool, _ body: () async throws -> T) async throws -> T {
        configureLogging()
        return try await lock.run {
            ModelHub.offlineMode = !allowNetwork
            defer { ModelHub.offlineMode = true }
            return try await body()
        }
    }

    static var sortformerConfig: SortformerConfig {
        var config = SortformerConfig.highContextV2_1
        config.precision = .palettized
        return config
    }

    /// Paths (relative to the FluidAudio models directory) that must exist for diarization.
    static var requiredPaths: [String] {
        var paths = ModelNames.OfflineDiarizer.requiredModels.sorted().map { "\(Repo.diarizer.folderName)/\($0)" }
        if let bundle = ModelNames.Sortformer.bundle(for: sortformerConfig) {
            paths.append("\(Repo.sortformer.folderName)/\(bundle)")
        }
        return paths
    }

    static func installed(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        return requiredPaths.allSatisfy { path in
            let url = directory.appendingPathComponent(path)
            if path.hasSuffix(".mlmodelc") {
                return fileManager.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                    && !containsPartialDownload(url)
            }
            return fileManager.fileExists(atPath: url.path)
        }
    }

    private static func containsPartialDownload(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let item as URL in enumerator where item.pathExtension == "partial" { return true }
        return false
    }

    /// Downloads (when missing) and compiles every diarization model. `progress` 0…1.
    static func prepareAll(directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await run(allowNetwork: true) {
            _ = try await OfflineDiarizerModels.load(from: directory) { update in
                progress(0.2 * update.fractionCompleted)
            }
            progress(0.2)
            _ = try await SortformerModels.loadFromHuggingFace(config: sortformerConfig, cacheDirectory: directory) { update in
                progress(0.2 + 0.8 * update.fractionCompleted)
            }
            progress(1)
        }
    }
}

/// Speaker diarization of the remote ("them") track with FluidAudio 0.18.3.
///
/// Primary method (best in the spike on every test file, including 6 speakers, 60 minutes and two
/// similar South-Asian female voices): Sortformer high-context v2.1 (palettized) finds turns → turns
/// are cut into ≤ 4 s units → WeSpeaker `embedSpans` on units ≥ 0.8 s → duration-weighted
/// average-linkage AHC on cosine (cut 0.55) → clusters with < max(4 s, 0.5 % of speech) are folded
/// into the nearest big one → short units inherit by Sortformer slot. VBx (`OfflineDiarizerManager`)
/// is the fallback for very long calls, too many units, or a Sortformer failure.
///
/// Thread-safety: an actor; only Sendable models are kept as state, and the non-Sendable FluidAudio
/// managers are created per job.
public actor SpeakerDiarizer {
    public struct Configuration: Sendable {
        public var modelsDirectory: URL = KanPaths.fluidAudioModels
        /// Fetch missing models through FluidAudio (installed ones always load offline).
        public var allowDownload = true
        public var cosineThreshold: Float = 0.55
        public var unitMaxLength = 4.0
        public var minimumEmbeddingLength = 0.8
        public var minimumClusterSeconds = 4.0
        public var minimumClusterFraction = 0.005
        /// Short units take the majority label of their Sortformer slot within ± this many seconds.
        public var slotVoteWindow = 90.0
        public var turnMergeGap = 0.25
        /// Use VBx when the remote side has more speech than this (Sortformer's speaker cache drifts)…
        public var vbxAboveSpeechSeconds = 90.0 * 60
        /// …or the track is longer than this (Sortformer holds about 1.2 GB per hour of audio)…
        public var vbxAboveAudioSeconds = 3.0 * 3600
        /// …or Sortformer produced more units than this (AHC cost grows quickly).
        public var vbxAboveUnits = 1_500

        public init() {}
    }

    public let configuration: Configuration
    private var offlineModels: OfflineDiarizerModels?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        FluidAudioModelAccess.configureLogging()
    }

    public static func modelsInstalled(at directory: URL = KanPaths.fluidAudioModels) -> Bool {
        FluidAudioModelAccess.installed(at: directory)
    }

    /// Frees the CoreML models.
    public func unloadModels() { offlineModels = nil }

    /// Loads (and on first use compiles) both model sets without diarizing anything.
    public func prepareModels() async throws {
        _ = try await loadOfflineModels()
        let sortformer = try await makeSortformer()
        sortformer.value.cleanup()
    }

    /// Diarizes 16 kHz mono `samples`. `speechSeconds` is the VAD speech total (chooses the method).
    public func diarize(_ samples: [Float], speechSeconds: Double, maxSpeakers: Int?) async throws -> SpeakerDiarization {
        let start = Date()
        guard !samples.isEmpty else { return .empty(.hybrid) }
        var result: SpeakerDiarization
        let audioSeconds = Double(samples.count) / AudioLoader.sampleRate
        if speechSeconds > configuration.vbxAboveSpeechSeconds || audioSeconds > configuration.vbxAboveAudioSeconds {
            KanLog.info("Diarizing \(Int(speechSeconds / 60)) min of remote speech (\(Int(audioSeconds / 60)) min of audio) with VBx",
                        category: "diarize")
            result = try await diarizeVBx(samples, maxSpeakers: maxSpeakers)
        } else {
            do {
                result = try await diarizeHybrid(samples, maxSpeakers: maxSpeakers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                KanLog.warning("Sortformer diarization failed (\(error.localizedDescription)); using VBx", category: "diarize")
                result = try await diarizeVBx(samples, maxSpeakers: maxSpeakers)
                result.usedFallback = true
            }
        }
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    // MARK: - Models

    private func loadOfflineModels() async throws -> OfflineDiarizerModels {
        if let offlineModels { return offlineModels }
        let directory = configuration.modelsDirectory
        let allowNetwork = configuration.allowDownload && !Self.modelsInstalled(at: directory)
        let models = try await FluidAudioModelAccess.run(allowNetwork: allowNetwork) {
            try await OfflineDiarizerModels.load(from: directory)
        }
        offlineModels = models
        return models
    }

    private func makeSortformer() async throws -> UncheckedSendable<SortformerDiarizer> {
        let directory = configuration.modelsDirectory
        let allowNetwork = configuration.allowDownload && !Self.modelsInstalled(at: directory)
        let config = FluidAudioModelAccess.sortformerConfig
        let models = try await FluidAudioModelAccess.run(allowNetwork: allowNetwork) {
            UncheckedSendable(try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: directory))
        }
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models.value)
        return UncheckedSendable(diarizer)
    }

    // MARK: - Hybrid

    private struct Unit {
        var slot: Int
        var range: TimeRange
    }

    private func diarizeHybrid(_ samples: [Float], maxSpeakers: Int?) async throws -> SpeakerDiarization {
        let sortformer = try await makeSortformer()
        // processComplete is synchronous and checks Task cancellation between chunks, so it runs in
        // its own task that inherits our cancellation.
        let work = Task.detached(priority: .utility) { () throws -> [(slot: Int, range: TimeRange)] in
            let timeline = try sortformer.value.processComplete(samples, sourceSampleRate: nil,
                                                                keepingEnrolledSpeakers: false)
            var segments: [(slot: Int, range: TimeRange)] = []
            for (slot, speaker) in timeline.speakers {
                for segment in speaker.finalizedSegments + speaker.tentativeSegments where segment.endTime > segment.startTime {
                    segments.append((slot, TimeRange(Double(segment.startTime), Double(segment.endTime))))
                }
            }
            return segments.sorted { $0.range.start < $1.range.start }
        }
        let segments: [(slot: Int, range: TimeRange)]
        do {
            segments = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            sortformer.value.cleanup()   // the task has finished once `value` returns or throws
            throw error
        }
        sortformer.value.cleanup()
        try Task.checkCancellation()
        guard !segments.isEmpty else { return .empty(.hybrid) }

        let audioEnd = Double(samples.count) / AudioLoader.sampleRate
        var units: [Unit] = []
        for segment in segments {
            let range = segment.range.clamped(to: TimeRange(0, audioEnd))
            guard range.duration > 0 else { continue }
            let pieces = max(1, Int((range.duration / configuration.unitMaxLength).rounded(.up)))
            let step = range.duration / Double(pieces)
            for k in 0..<pieces {
                units.append(Unit(slot: segment.slot, range: TimeRange(range.start + Double(k) * step,
                                                                       range.start + Double(k + 1) * step)))
            }
        }
        if units.count > configuration.vbxAboveUnits {
            KanLog.info("\(units.count) speaker units; using VBx", category: "diarize")
            var result = try await diarizeVBx(samples, maxSpeakers: maxSpeakers)
            result.usedFallback = true
            return result
        }

        let embedded = units.indices.filter { units[$0].range.duration >= configuration.minimumEmbeddingLength }
        guard !embedded.isEmpty else {
            // Only very short turns: trust Sortformer's slots.
            return SpeakerDiarization(turns: mergeTurns(units.map { ($0, "slot\($0.slot)") }), embeddings: [:],
                                      method: .hybrid, usedFallback: false, seconds: 0)
        }
        let models = try await loadOfflineModels()
        let manager = OfflineDiarizerManager(config: Self.vbxConfig(maxSpeakers: nil))
        manager.initialize(models: models)
        let embeddings = try await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: samples),
                                                      spans: embedded.map { units[$0].range.start..<units[$0].range.end })
        try Task.checkCancellation()
        guard embeddings.count == embedded.count else {
            throw TranscriptionError.engineFailed("speaker embedding returned \(embeddings.count) of \(embedded.count) vectors")
        }

        let weights = embedded.map { units[$0].range.duration }
        let totalSpeech = units.reduce(0) { $0 + $1.range.duration }
        let labels = SpeakerClustering.agglomerative(
            embeddings, weights: weights, threshold: configuration.cosineThreshold,
            minClusterWeight: max(configuration.minimumClusterSeconds, configuration.minimumClusterFraction * totalSpeech),
            maxClusters: maxSpeakers)

        var unitLabel = [Int?](repeating: nil, count: units.count)
        for (k, index) in embedded.enumerated() { unitLabel[index] = labels[k] }
        let resolved = units.indices.map { index -> Int in
            if let label = unitLabel[index] { return label }
            // Short unit: majority (by duration) of its Sortformer slot nearby, else the nearest labelled unit.
            var votes: [Int: Double] = [:]
            for other in units.indices where units[other].slot == units[index].slot
                && abs(units[other].range.start - units[index].range.start) <= configuration.slotVoteWindow {
                if let label = unitLabel[other] { votes[label, default: 0] += units[other].range.duration }
            }
            if let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
                return best.key
            }
            let nearest = embedded.min { units[$0].range.gap(to: units[index].range) < units[$1].range.gap(to: units[index].range) }
            return nearest.flatMap { unitLabel[$0] } ?? 0
        }

        let centroids = SpeakerClustering.centroids(embeddings, weights: weights, labels: labels)
        var named: [String: [Float]] = [:]
        for (label, centroid) in centroids { named[Self.label(label)] = centroid }
        let turns = mergeTurns(units.indices.map { (units[$0], Self.label(resolved[$0])) })
        return SpeakerDiarization(turns: turns, embeddings: named, method: .hybrid, usedFallback: false, seconds: 0)
    }

    private static func label(_ cluster: Int) -> String { "C\(cluster)" }

    private func mergeTurns(_ labelled: [(Unit, String)]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for (unit, label) in labelled.sorted(by: { $0.0.range.start < $1.0.range.start }) {
            if let last = turns.last, last.speaker == label, unit.range.start - last.end <= configuration.turnMergeGap {
                turns[turns.count - 1].end = max(last.end, unit.range.end)
            } else {
                turns.append(SpeakerTurn(speaker: label, start: unit.range.start, end: unit.range.end))
            }
        }
        return turns
    }

    // MARK: - VBx

    static func vbxConfig(maxSpeakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        // The default warm start (0.07) merged similar voices in short calls.
        config.clustering.warmStartFa = 0.3
        config.embedding.minSegmentDurationSeconds = 0.5
        config.zeroVoteReembed = .init(enabled: true, minDurationSeconds: 0.4)
        config.segmentation.batchSize = 8
        if let maxSpeakers, maxSpeakers > 0 { config = config.withSpeakers(min: nil, max: maxSpeakers) }
        return config
    }

    private func diarizeVBx(_ samples: [Float], maxSpeakers: Int?) async throws -> SpeakerDiarization {
        let models = try await loadOfflineModels()
        let manager = OfflineDiarizerManager(config: Self.vbxConfig(maxSpeakers: maxSpeakers))
        manager.initialize(models: models)
        let result = try await manager.process(audio: samples)
        try Task.checkCancellation()
        let turns = result.segments
            .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        let embeddings = (result.speakerDatabase ?? [:]).mapValues(SpeakerClustering.normalized)
        return SpeakerDiarization(turns: turns, embeddings: embeddings, method: .vbx, usedFallback: false, seconds: 0)
    }
}
