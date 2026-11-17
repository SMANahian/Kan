import Foundation
import KanCore

/// The canned conversation the mocks "record" and "transcribe": the repo's TTS clips
/// (Tests/Audio), alternating between the mic track and two remote speakers, in English and Bangla.
/// The recorder and the transcriber lay it out identically, so the mock transcript matches the
/// mock audio (useful for playback and seeking in the library window).
enum MockScript {
    struct Line: Sendable {
        var speakerID: String
        var clip: String
        var text: String
        var language: String
        /// Used when the clip isn't available (then the track is silent).
        var nominalSeconds: Double

        var channel: AudioChannel { speakerID == Speaker.meID ? .me : .them }
    }

    struct Placement: Sendable {
        var line: Line
        var start: Double
        var end: Double
    }

    static let lines: [Line] = [
        Line(speakerID: Speaker.meID, clip: "a1",
             text: "Hi, thanks for joining the call. I wanted to talk about the research idea on speech recognition for low resource languages.",
             language: "en", nominalSeconds: 7.3),
        Line(speakerID: "s1", clip: "b1",
             text: "Sure. I think the key question is whether we can fine tune a multilingual model with only a few hours of Bangla data.",
             language: "en", nominalSeconds: 6.6),
        Line(speakerID: "s2", clip: "bn1",
             text: "আমি আজকে একটা নতুন গবেষণার আইডিয়া নিয়ে কথা বলতে চাই। আমরা বাংলা ভাষার জন্য একটি স্পিচ রিকগনিশন মডেল তৈরি করব।",
             language: "bn", nominalSeconds: 9.3),
        Line(speakerID: Speaker.meID, clip: "a2",
             text: "Right. We could also try data augmentation and pseudo labeling from unlabeled recordings.",
             language: "en", nominalSeconds: 5.1),
        Line(speakerID: "s2", clip: "bn2",
             text: "এই প্রজেক্টে আমাদের প্রথম কাজ হবে ডেটাসেট সংগ্রহ করা, তারপর মডেল ট্রেনিং।",
             language: "bn", nominalSeconds: 5.6),
        Line(speakerID: "s1", clip: "b2",
             text: "That makes sense. Let's write down the plan and meet again next week.",
             language: "en", nominalSeconds: 4.2),
    ]

    static let leadIn = 1.0
    static let gap = 0.8

    /// Lines placed back to back (with short gaps), repeating the script until `duration`; the
    /// last line is cut at the end.
    static func layout(duration: Double, clipSeconds: (String) -> Double?) -> [Placement] {
        guard duration > leadIn else { return [] }
        var placements: [Placement] = []
        var t = leadIn
        var index = 0
        while t < duration - 0.5 {
            let line = lines[index % lines.count]
            let length = clipSeconds(line.clip) ?? line.nominalSeconds
            placements.append(Placement(line: line, start: t, end: min(duration, t + length)))
            t += length + gap
            index += 1
        }
        return placements
    }
}

/// Loads the TTS clips once. Thread-safe.
final class MockAudioLibrary: @unchecked Sendable {
    struct Clip {
        var samples: [Int16]
        /// RMS (0…1) per 100 ms, for the level meters.
        var envelope: [Float]
        var seconds: Double { Double(samples.count) / Double(WAV.sampleRate) }
    }

    static let shared = MockAudioLibrary()

    private let lock = NSLock()
    private var loaded = false
    private var clips: [String: Clip] = [:]
    private var directoryUsed: URL?

    /// Where the clips were found (nil: the mocks record silence).
    var directory: URL? {
        lock.withLock {
            loadLocked()
            return directoryUsed
        }
    }

    func clip(_ name: String) -> Clip? {
        lock.withLock {
            loadLocked()
            return clips[name]
        }
    }

    func seconds(_ name: String) -> Double? { clip(name)?.seconds }

    /// KAN_TEST_AUDIO, else a Tests/Audio folder above the executable, else next to this source file.
    static func findAudioDirectory() -> URL? {
        let fm = FileManager.default
        func valid(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("a1.wav").path) }
        if let path = ProcessInfo.processInfo.environment["KAN_TEST_AUDIO"], !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if valid(url) { return url }
        }
        var directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Audio", isDirectory: true)
            if valid(candidate) { return candidate }
            directory.deleteLastPathComponent()
        }
        // A development build: <repo>/Sources/KanApp/Services/MockAudio.swift → <repo>/Tests/Audio.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fromSource = repo.appendingPathComponent("Tests/Audio", isDirectory: true)
        return valid(fromSource) ? fromSource : nil
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let directory = Self.findAudioDirectory() else {
            KanLog.info("Mock audio: Tests/Audio not found; mock recordings are silent", category: "mock")
            return
        }
        directoryUsed = directory
        for name in Set(MockScript.lines.map(\.clip)) {
            guard let samples = WAV.readSamples(directory.appendingPathComponent(name + ".wav")) else { continue }
            clips[name] = Clip(samples: samples, envelope: Self.envelope(samples))
        }
        KanLog.info("Mock audio: \(clips.count) clips from \(directory.path)", category: "mock")
    }

    private static func envelope(_ samples: [Int16]) -> [Float] {
        let window = WAV.sampleRate / 10
        return stride(from: 0, to: samples.count, by: window).map { start in
            let slice = samples[start..<min(samples.count, start + window)]
            let sum = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
            return Float((sum / Double(max(1, slice.count))).squareRoot() / 32768)
        }
    }
}
