import Foundation
import KanCore
import KanTestKit
import KanTranscribe

/// Reference turns of two_speakers_en.wav (A, B, A, B; 0.8 s silences between clips).
private let twoSpeakerTurns: [TimeRange] = {
    let durations = [7.28525, 6.66475, 5.138813, 4.237687]
    var start = 0.0
    return durations.map { duration in
        defer { start += duration + 0.8 }
        return TimeRange(start, start + duration)
    }
}()

/// Speaker with the most segment time inside each reference turn.
private func dominantSpeakers(_ output: TranscriptionOutput, turns: [TimeRange]) -> [String?] {
    turns.map { turn in
        var time: [String: Double] = [:]
        for segment in output.segments where !segment.flags.contains(.echoSuspect) {
            time[segment.speakerID, default: 0] += TimeRange(segment.start, segment.end).overlap(with: turn)
        }
        return time.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }
}

/// Consecutive runs of the same value.
private func runs<T: Equatable>(_ values: [T]) -> [T] {
    values.reduce(into: [T]()) { result, value in if result.last != value { result.append(value) } }
}

private func request(me: URL? = nil, them: URL? = nil, mode: LanguageMode = .auto, bangla: String = "auto",
                     loudspeaker: Bool = false, echoSuppression: Bool = true, userName: String = "Nahian") -> TranscriptionRequest {
    TranscriptionRequest(callID: .generate(), meFile: me, themFile: them, languageMode: mode, userName: userName,
                         echoSuppression: echoSuppression, loudspeakerSuspected: loudspeaker, banglaModelID: bangla)
}

/// The mic track of the loudspeaker test calls: a1 and a2, plus −12 dB of b1 and b2 arriving `lag` s
/// after the remote side played them, plus a little room noise.
private func echoCall(lag: Double, seed: UInt64, name: String) throws -> (me: URL, them: URL) {
    let a1 = try TestAudio.load("a1.wav"), a2 = try TestAudio.load("a2.wav")
    let b1 = try TestAudio.load("b1.wav"), b2 = try TestAudio.load("b2.wav")
    let duration = 26.5 + lag
    let them = TestAudio.timeline([(b1, 8.0, 1), (b2, 21.5, 1)], duration: duration)
    var mic = TestAudio.timeline([(a1, 0, 1), (a2, 15.5, 1), (b1, 8 + lag, 0.25), (b2, 21.5 + lag, 0.25)], duration: duration)
    var rng = SeededGenerator(seed: seed)
    for i in mic.indices { mic[i] += Float.random(in: -0.002...0.002, using: &rng) }
    let scratch = scratchDirectory(name)
    let meURL = scratch.appendingPathComponent("\(name)-me.wav"), themURL = scratch.appendingPathComponent("\(name)-them.wav")
    try TestAudio.writeWAV(mic, to: meURL)
    try TestAudio.writeWAV(them, to: themURL)
    return (meURL, themURL)
}

/// Mic segments whose text is that of the remote clips b1/b2 (leaked or repeated speech).
private func remoteWords(_ output: TranscriptionOutput) -> [TranscriptSegment] {
    output.segments.filter { segment in
        segment.speakerID == Speaker.meID
            && max(EchoDedup.similarity(segment.text, GroundTruth.b1), EchoDedup.similarity(segment.text, GroundTruth.b2)) >= 0.5
    }
}

/// The part of `samples` after its longest pause (≥ 150 ms below −45 dBFS, away from the edges).
private func afterLongestPause(_ samples: [Float]) -> [Float] {
    let hop = 320   // 20 ms
    let quiet = stride(from: 0, to: samples.count - hop, by: hop).map { AudioLoader.rmsDecibels(samples[$0..<($0 + hop)]) < -45 }
    var best = (start: 0, length: 0), run = 0
    for (index, isQuiet) in quiet.enumerated() {
        run = isQuiet ? run + 1 : 0
        if run > best.length, index * hop > 16_000, index * hop < samples.count - 16_000 { best = (index - run + 1, run) }
    }
    guard best.length >= 8 else { return samples }
    return Array(samples[((best.start + best.length) * hop - 800)...])
}

func integrationSuites() -> [TestSuite] {
    let suite = TestSuite("Integration")

    suite.test("installed models are ready") {
        let readiness = InstalledModels.store.readiness(for: KanSettings())
        print("      resolved: \(readiness.resolved.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))")
        for line in readiness.missing { print("      missing: \(line)") }
        for line in readiness.recommendations { print("      recommendation: \(line)") }
        try InstalledModels.requireAnyWhisper()
        try expect(readiness.canTranscribe)
    }

    suite.test("warm-up loads every installed model and returns") {
        try InstalledModels.requireAnyWhisper()
        let started = Date()
        await offlinePipeline().warmUp()
        print(String(format: "      warm-up took %.1f s", Date().timeIntervalSince(started)))
    }

    suite.test("Silero VAD finds the four turns of two_speakers_en") {
        try InstalledModels.require(ModelCatalog.vadID)
        let vadURL = try expectNotNil(InstalledModels.store.spec(ModelCatalog.vadID)).fileName
        let detector = try VoiceActivityDetector(modelURL: InstalledModels.store.directory.appendingPathComponent(vadURL))
        let samples = try TestAudio.load("two_speakers_en.wav")
        let probabilities = try detector.probabilities(samples)
        try expectEqual(probabilities.values.count, (samples.count + 511) / 512)
        let segments = SpeechSegmenter.segments(from: probabilities, audioDuration: Double(samples.count) / 16_000)
        print("      speech: \(segments.map(\.description).joined(separator: " "))")
        for turn in twoSpeakerTurns {
            let covered = segments.reduce(0) { $0 + $1.overlap(with: turn) }
            try expect(covered >= 0.8 * turn.duration, "turn \(turn) covered \(covered) s")
        }
        try expect(segments.allSatisfy { segment in twoSpeakerTurns.contains { $0.overlap(with: segment) > 0 } })
    }

    suite.test("speaker diarization separates the two voices of two_speakers_en") {
        guard SpeakerDiarizer.modelsInstalled(at: InstalledModels.store.fluidAudioDirectory) else {
            throw TestSkip("speaker models not installed")
        }
        var configuration = SpeakerDiarizer.Configuration()
        configuration.modelsDirectory = InstalledModels.store.fluidAudioDirectory
        configuration.allowDownload = false
        let samples = try TestAudio.load("two_speakers_en.wav")
        let result = try await SpeakerDiarizer(configuration: configuration).diarize(samples, speechSeconds: 23, maxSpeakers: nil)
        print("      \(result.method.rawValue) in \(String(format: "%.2f", result.seconds)) s: "
              + result.turns.map { "\($0.speaker)\($0.range)" }.joined(separator: " "))
        try expectEqual(result.method, .hybrid)
        try expectEqual(Set(result.turns.map(\.speaker)).count, 2)
        let labels = twoSpeakerTurns.map { turn in
            result.turns.max { $0.range.overlap(with: turn) < $1.range.overlap(with: turn) }?.speaker
        }
        try expect(labels[0] == labels[2] && labels[1] == labels[3] && labels[0] != labels[1], "\(labels)")
        try expectEqual(result.embeddings.count, 2)
        for vector in result.embeddings.values {
            try expectEqual(vector.count, 256)
            try expectClose(Double(vector.reduce(0) { $0 + $1 * $1 }), 1, tolerance: 1e-3)
        }
        let vectors = Array(result.embeddings.values)
        let similarity = SpeakerClustering.cosine(vectors[0], vectors[1])
        print("      cross-speaker cosine \(String(format: "%.3f", similarity))")
        try expect(similarity < 0.7)
    }

    suite.test("VBx fallback diarization also separates the two voices") {
        guard SpeakerDiarizer.modelsInstalled(at: InstalledModels.store.fluidAudioDirectory) else {
            throw TestSkip("speaker models not installed")
        }
        var configuration = SpeakerDiarizer.Configuration()
        configuration.modelsDirectory = InstalledModels.store.fluidAudioDirectory
        configuration.allowDownload = false
        configuration.vbxAboveSpeechSeconds = 0   // force the long-call path
        let samples = try TestAudio.load("two_speakers_en.wav")
        let result = try await SpeakerDiarizer(configuration: configuration).diarize(samples, speechSeconds: 23, maxSpeakers: nil)
        print("      \(result.method.rawValue) in \(String(format: "%.2f", result.seconds)) s: "
              + result.turns.map { "\($0.speaker)\($0.range)" }.joined(separator: " "))
        try expectEqual(result.method, .vbx)
        let labels = twoSpeakerTurns.map { turn in
            result.turns.max { $0.range.overlap(with: turn) < $1.range.overlap(with: turn) }?.speaker
        }
        try expect(labels[0] == labels[2] && labels[1] == labels[3] && labels[0] != labels[1], "\(labels)")
        try expectEqual(result.embeddings.count, 2)
        for vector in result.embeddings.values {
            try expectClose(Double(vector.reduce(0) { $0 + $1 * $1 }), 1, tolerance: 1e-3)
        }
        let capped = try await SpeakerDiarizer(configuration: configuration).diarize(samples, speechSeconds: 23, maxSpeakers: 1)
        try expectEqual(Set(capped.turns.map(\.speaker)).count, 1, "maxSpeakers 1")
    }

    suite.test("(1) two_speakers_en as 'them': two speakers in A,B,A,B order, English WER") {
        try InstalledModels.requireAnyWhisper()
        let output = try await transcribe(request(them: TestAudio.url("two_speakers_en.wav")), label: "two_speakers_en")
        printTranscript(output)
        try expect(!output.speakers.contains { $0.isMe }, "no mic track, no 'me'")
        try expectEqual(output.speakers.map(\.id), ["s1", "s2"])
        let order = dominantSpeakers(output, turns: twoSpeakerTurns)
        try expectEqual(order, ["s1", "s2", "s1", "s2"])
        try expect(output.segments.allSatisfy { $0.language == "en" })
        let wer = Metrics.wer(output.segments.map(\.text).joined(separator: " "), GroundTruth.twoSpeakers)
        print("      English WER \(percent(wer))")
        try expect(wer <= 0.10)
        try expectEqual(output.speakerEmbeddings.count, 2)
        try expectEqual(output.segments.map(\.id), Array(0..<output.segments.count))
    }

    suite.test("(2) bangla.wav: all bn in Bengali script; CER with the Bangla model and with large-v3") {
        try InstalledModels.requireAnyWhisper()
        var rows: [(String, Double, String)] = []
        var candidates: [(label: String, bangla: String, prompt: String??)] = []
        if InstalledModels.store.isInstalled("bengali-medium-q8_0") { candidates.append(("bengali-medium-q8_0", "bengali-medium-q8_0", nil)) }
        if InstalledModels.store.isInstalled("large-v3") {
            candidates.append(("large-v3 (no prompt)", "large-v3", .some(nil)))
            candidates.append(("large-v3 + code-switch prompt", "large-v3", nil))
        }
        if InstalledModels.store.isInstalled("large-v3-turbo") { candidates.append(("large-v3-turbo (no prompt)", "large-v3-turbo", .some(nil))) }
        guard !candidates.isEmpty else { throw TestSkip("neither the Bangla model nor large-v3 is installed") }
        for candidate in candidates {
            let output = try await transcribe(request(them: TestAudio.url("bangla.wav"), bangla: candidate.bangla),
                                              with: offlinePipeline(codeSwitchPrompt: candidate.prompt), label: candidate.label)
            printTranscript(output)
            let text = output.segments.map(\.text).joined(separator: " ")
            let cer = Metrics.cer(text, GroundTruth.bangla)
            rows.append((candidate.label, cer, String(format: "RTF %.2f", output.stats["rtf"] ?? 0)))
            try expect(!output.segments.isEmpty)
            try expect(output.segments.allSatisfy { $0.language == "bn" }, "all chunks must be routed to Bangla")
            try expectEqual(output.languages, ["bn"])
            if candidate.prompt == nil && candidate.label.contains("prompt") {
                try expect(TextPostProcessor.containsBengali(text))   // English terms may come out in Latin
            } else {
                try expect(TextPostProcessor.bengaliLetterFraction(text) >= 0.95, "Bengali script: \(text)")
            }
            // Measured on this TTS clip: Bangla model 6.7 %, large-v3 20 %, turbo 28 %.
            let limit = candidate.bangla.hasPrefix("bengali") ? 0.15 : candidate.bangla.contains("turbo") ? 0.45 : 0.35
            try expect(cer <= limit, "CER \(cer) > \(limit)")
        }
        for (label, cer, rtf) in rows { print("      CER \(label): \(percent(cer)) (\(rtf))") }
    }

    suite.test("(3) mixed_bn_en.wav: per-chunk languages bn, en, bn, en") {
        try InstalledModels.requireAnyWhisper()
        let output = try await transcribe(request(them: TestAudio.url("mixed_bn_en.wav")), label: "mixed_bn_en")
        printTranscript(output)
        try expectEqual(runs(output.segments.map(\.language)), ["bn", "en", "bn", "en"])
        try expectEqual(output.stats["chunks.bn"], 2)
        try expectEqual(output.stats["chunks.en"], 2)
        let english = output.segments.filter { $0.language == "en" }.map(\.text).joined(separator: " ")
        let bangla = output.segments.filter { $0.language == "bn" }.map(\.text).joined(separator: " ")
        let wer = Metrics.wer(english, GroundTruth.a1 + " " + GroundTruth.b1)
        let cer = Metrics.cer(bangla, GroundTruth.bangla)
        print("      English WER \(percent(wer)), Bangla CER \(percent(cer))")
        try expect(wer <= 0.10)
        try expect(cer <= (InstalledModels.store.isInstalled("bengali-medium-q8_0") ? 0.15 : 0.35))
    }

    suite.test("(4) simulated call: me = a1 + a2, them = b1 + b2 alternating") {
        try InstalledModels.requireAnyWhisper()
        let a1 = try TestAudio.load("a1.wav"), a2 = try TestAudio.load("a2.wav")
        let b1 = try TestAudio.load("b1.wav"), b2 = try TestAudio.load("b2.wav")
        let duration = 26.5
        let scratch = scratchDirectory("simulated-call")
        let meURL = scratch.appendingPathComponent("call-me.wav"), themURL = scratch.appendingPathComponent("call-them.wav")
        try TestAudio.writeWAV(TestAudio.timeline([(a1, 0, 1), (a2, 15.5, 1)], duration: duration), to: meURL)
        try TestAudio.writeWAV(TestAudio.timeline([(b1, 8.0, 1), (b2, 21.5, 1)], duration: duration), to: themURL)
        let output = try await transcribe(request(me: meURL, them: themURL), label: "simulated call")
        printTranscript(output)
        try expectEqual(output.speakers.map(\.id), ["me", "s1"])
        try expectEqual(output.speakers.map(\.name), ["Nahian", "Speaker 1"])
        try expectEqual(runs(output.segments.map(\.speakerID)), ["me", "s1", "me", "s1"])
        try expect(!output.segments.contains { $0.flags.contains(.echoSuspect) }, "no echo on separate tracks")
        let mine = output.segments.filter { $0.speakerID == "me" }.map(\.text).joined(separator: " ")
        let theirs = output.segments.filter { $0.speakerID == "s1" }.map(\.text).joined(separator: " ")
        try expect(Metrics.wer(mine, GroundTruth.a1 + " " + GroundTruth.a2) <= 0.10, mine)
        try expect(Metrics.wer(theirs, GroundTruth.b1 + " " + GroundTruth.b2) <= 0.10, theirs)
        try expect(output.speakers[0].talkTime > 8 && output.speakers[1].talkTime > 6)
    }

    suite.test("(5) loudspeaker echo (−12 dB, 120 ms): the leak is removed by the gate or flagged, my own speech is kept") {
        try InstalledModels.requireAnyWhisper()
        // −12 dB (×0.25) of the remote side reaches the mic 120 ms later.
        let (meURL, themURL) = try echoCall(lag: 0.12, seed: 9, name: "echo-call")
        let output = try await transcribe(request(me: meURL, them: themURL, loudspeaker: true), label: "echo call")
        printTranscript(output)
        let lag = output.stats["echo.lagMs"] ?? -1
        print("      echo lag \(Int(lag)) ms, mic frames gated \(percent(output.stats["echo.gatedFraction"] ?? 0)), "
              + "muted \(String(format: "%.1f", output.stats["echo.mutedSeconds"] ?? 0)) s, flagged segments \(Int(output.stats["echo.flagged"] ?? 0))")
        try expectClose(lag, 120, tolerance: 11)
        let mine = output.segments.filter { $0.speakerID == "me" }
        let genuine = mine.filter { !$0.flags.contains(.echoSuspect) }
        for segment in genuine {
            let echoOf = max(EchoDedup.similarity(segment.text, GroundTruth.b1), EchoDedup.similarity(segment.text, GroundTruth.b2))
            try expect(echoOf < 0.5, "unflagged echo in the mic track: \(segment.text)")
        }
        try expect(Metrics.wer(genuine.map(\.text).joined(separator: " "), GroundTruth.a1 + " " + GroundTruth.a2) <= 0.15,
                   "my own speech must survive the gate")
        try expectEqual(runs(output.segments.filter { !$0.flags.contains(.echoSuspect) }.map(\.speakerID)), ["me", "s1", "me", "s1"])
    }

    suite.test("(5b) echo delayed beyond the gate's 400 ms search (AirPlay-like 700 ms) is flagged by text") {
        try InstalledModels.requireAnyWhisper()
        let (meURL, themURL) = try echoCall(lag: 0.7, seed: 10, name: "echo-700")
        let output = try await transcribe(request(me: meURL, them: themURL, loudspeaker: true), label: "echo 700 ms")
        printTranscript(output)
        let mine = output.segments.filter { $0.speakerID == "me" }
        let echoes = remoteWords(output)
        try expect(!echoes.isEmpty, "the leaked speech should have been transcribed on the mic track")
        try expect(echoes.allSatisfy { $0.flags.contains(.echoSuspect) }, "every echo segment must be flagged")
        let genuine = mine.filter { !$0.flags.contains(.echoSuspect) }
        try expect(Metrics.wer(genuine.map(\.text).joined(separator: " "), GroundTruth.a1 + " " + GroundTruth.a2) <= 0.15)
    }

    suite.test("(5c) echo handling off: the mic track is left alone even on a loudspeaker call") {
        try InstalledModels.requireAnyWhisper()
        let (meURL, themURL) = try echoCall(lag: 0.12, seed: 11, name: "echo-off")
        let output = try await transcribe(request(me: meURL, them: themURL, loudspeaker: true, echoSuppression: false),
                                          label: "echo handling off")
        printTranscript(output)
        try expect(output.stats["echo.lagMs"] == nil, "the echo gate must not run")
        try expect(!output.segments.contains { $0.flags.contains(.echoSuspect) }, "nothing may be flagged as echo")
        try expect(!remoteWords(output).isEmpty, "the leak stays in the mic track, as the setting asks")
    }

    suite.test("(6) repeating the other side's words right after them is not echo (headphones and speakers)") {
        try InstalledModels.requireAnyWhisper()
        let b1 = try TestAudio.load("b1.wav"), a2 = try TestAudio.load("a2.wav")
        let duration = 22.0
        // The remote side says b1; then I say it back (same words, separate tracks), then a2.
        var mic = TestAudio.timeline([(b1, 7.5, 1), (a2, 16.0, 1)], duration: duration)
        var rng = SeededGenerator(seed: 12)
        for i in mic.indices { mic[i] += Float.random(in: -0.002...0.002, using: &rng) }
        let scratch = scratchDirectory("repeat-call")
        let meURL = scratch.appendingPathComponent("repeat-me.wav"), themURL = scratch.appendingPathComponent("repeat-them.wav")
        try TestAudio.writeWAV(mic, to: meURL)
        try TestAudio.writeWAV(TestAudio.timeline([(b1, 0, 1)], duration: duration), to: themURL)
        for loudspeaker in [false, true] {
            let output = try await transcribe(request(me: meURL, them: themURL, loudspeaker: loudspeaker),
                                              label: loudspeaker ? "repeat (speakers)" : "repeat (headphones)")
            printTranscript(output)
            try expect(!output.segments.contains { $0.flags.contains(.echoSuspect) }, "my repeat was hidden as echo")
            try expect(!remoteWords(output).isEmpty, "my repeat must be in the transcript")
            try expect(output.speakers[0].talkTime > 8, "talk time \(output.speakers[0].talkTime)")
        }
    }

    suite.test("(7) a remote speaker's short Bangla reply after someone else's English turn stays Bangla") {
        try InstalledModels.requireAnyWhisper()
        guard SpeakerDiarizer.modelsInstalled(at: InstalledModels.store.fluidAudioDirectory) else {
            throw TestSkip("speaker models not installed")
        }
        let a1 = try TestAudio.load("a1.wav"), a2 = try TestAudio.load("a2.wav"), bn1 = try TestAudio.load("bn1.wav")
        let reply = afterLongestPause(try TestAudio.load("bn2.wav"))   // "তারপর মডেল ট্রেনিং।"
        let replyStart = 24.0
        let replyRange = TimeRange(replyStart, replyStart + Double(reply.count) / 16_000)
        try expect(replyRange.duration < LanguageRouting().minimumDuration, "the reply must be a short unit: \(replyRange)")
        // A (English) · Piya (Bangla, long) · A (English) · Piya's short reply, 0.6 s after A.
        let them = TestAudio.timeline([(a1, 0, 1), (bn1, 8.1, 1), (a2, 18.2, 1), (reply, replyStart, 1)],
                                      duration: replyRange.end + 1)
        let url = scratchDirectory("short-reply").appendingPathComponent("short-reply-them.wav")
        try TestAudio.writeWAV(them, to: url)
        let output = try await transcribe(request(them: url), label: "short Bangla reply")
        printTranscript(output)
        let answer = output.segments.filter { TimeRange($0.start, $0.end).overlap(with: replyRange) > 0.5 * replyRange.duration }
        try expect(!answer.isEmpty, "the reply must be transcribed")
        try expect(answer.allSatisfy { $0.language == "bn" }, "routed \(answer.map(\.language)): \(answer.map(\.text))")
        try expect(answer.allSatisfy { TextPostProcessor.containsBengali($0.text) }, "\(answer.map(\.text))")
        let english = output.segments.filter { $0.end <= 8 || (TimeRange($0.start, $0.end).overlap(with: TimeRange(18.2, 23.4)) > 0) }
        try expect(english.allSatisfy { $0.language == "en" }, "A's turns stay English")
    }

    suite.test("kan transcribe: exit codes and JSON output") {
        try InstalledModels.requireAnyWhisper()
        print("      --- kan transcribe --json --no-diarize a1.wav ---")
        try expectEqual(await TranscribeCommand.run(["transcribe", "--json", "--no-diarize", TestAudio.url("a1.wav").path]), 0)
        print("      --- kan transcribe --lang en b2.wav ---")
        try expectEqual(await TranscribeCommand.run(["--lang", "en", TestAudio.url("b2.wav").path]), 0)
        try expectEqual(await TranscribeCommand.run(["/no/such/file.wav"]), 1)
        try expectEqual(await TranscribeCommand.run(["--speakers"]), 2)
    }

    // Opt-in benchmark on your own recordings: KAN_BENCH_ME=/path/me.wav KAN_BENCH_THEM=/path/them.wav
    // (either one, any format AVFoundation reads) prints the transcript, stats and real-time factor.
    suite.test("benchmark on KAN_BENCH_ME / KAN_BENCH_THEM recordings") {
        let environment = ProcessInfo.processInfo.environment
        let me = environment["KAN_BENCH_ME"].map { URL(fileURLWithPath: $0) }
        let them = environment["KAN_BENCH_THEM"].map { URL(fileURLWithPath: $0) }
        guard me != nil || them != nil else { throw TestSkip("set KAN_BENCH_ME and/or KAN_BENCH_THEM") }
        let output = try await transcribe(request(me: me, them: them), label: "benchmark")
        printTranscript(output)
        for (key, value) in output.stats.sorted(by: { $0.key < $1.key }) { print("        \(key) = \(String(format: "%.3f", value))") }
    }

    suite.test("silence gives an empty transcript, not an error") {
        try InstalledModels.require(ModelCatalog.vadID)
        let url = scratchDirectory("silence").appendingPathComponent("silence.wav")
        try TestAudio.writeWAV([Float](repeating: 0, count: 16_000 * 3), to: url)
        let output = try await offlinePipeline().transcribe(request(me: url, them: url)) { _ in }
        try expect(output.segments.isEmpty)
        try expectEqual(output.speakers.map(\.id), ["me"])
        try expect(output.languages.isEmpty)
    }

    suite.test("progress is monotonic and finishes at 1") {
        try InstalledModels.requireAnyWhisper()
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var values: [PipelineProgress] = []
        }
        let collector = Collector()
        _ = try await offlinePipeline().transcribe(request(them: TestAudio.url("a1.wav"), mode: .english)) { progress in
            collector.lock.withLock { collector.values.append(progress) }
        }
        let values = collector.lock.withLock { collector.values }
        try expect(zip(values, values.dropFirst()).allSatisfy { $0.fraction <= $1.fraction + 1e-9 })
        try expectEqual(values.last?.fraction, 1)
        try expectEqual(values.last?.stage, .finishing)
    }

    suite.test("cancellation stops the job promptly") {
        try InstalledModels.requireAnyWhisper()
        let pipeline = offlinePipeline()
        let task = Task { try await pipeline.transcribe(request(them: TestAudio.url("mixed_bn_en.wav"), bangla: "large-v3")) { _ in } }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            print("      finished before the cancel arrived")
        } catch TranscriptionError.cancelled {
            let latency = Date().timeIntervalSince(cancelledAt)
            print("      cancelled after \(String(format: "%.2f", latency)) s")
            try expect(latency < 5)
        }
    }

    suite.test("missing tracks and unreadable files") {
        try InstalledModels.require(ModelCatalog.vadID)
        do {
            _ = try await offlinePipeline().transcribe(request()) { _ in }
            throw fail("expected noAudio")
        } catch TranscriptionError.noAudio {
        }
        let garbage = scratchDirectory("garbage").appendingPathComponent("garbage.wav")
        try Data("nope".utf8).write(to: garbage)
        do {
            _ = try await offlinePipeline().transcribe(request(them: garbage)) { _ in }
            throw fail("expected audioUnreadable")
        } catch TranscriptionError.audioUnreadable {
        }
    }
    return [suite]
}
