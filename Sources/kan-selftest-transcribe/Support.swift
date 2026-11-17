import AVFoundation
import Foundation
import KanCore
import KanTestKit
import KanTranscribe

// MARK: - Scratch directories

/// Private root for this run's files. Deliberately not KanTestKit's shared "kan-tests" folder: other
/// modules' self-tests, which may run at the same time, delete that folder wholesale.
let scratchRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("kan-selftest-transcribe-\(getpid())", isDirectory: true)

/// A fresh, empty directory under `scratchRoot`.
func scratchDirectory(_ name: String) -> URL {
    let url = scratchRoot.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Ground truth (Tests/Audio/README.md)

enum GroundTruth {
    static let a1 = "Hi, thanks for joining the call. I wanted to talk about the research idea on speech recognition for low resource languages."
    static let b1 = "Sure. I think the key question is whether we can fine tune a multilingual model with only a few hours of Bangla data."
    static let a2 = "Right. We could also try data augmentation and pseudo labeling from unlabeled recordings."
    static let b2 = "That makes sense. Let's write down the plan and meet again next week."
    static let bn1 = "আমি আজকে একটা নতুন গবেষণার আইডিয়া নিয়ে কথা বলতে চাই। আমরা বাংলা ভাষার জন্য একটি স্পিচ রিকগনিশন মডেল তৈরি করব।"
    static let bn2 = "এই প্রজেক্টে আমাদের প্রথম কাজ হবে ডেটাসেট সংগ্রহ করা, তারপর মডেল ট্রেনিং।"
    static var bangla: String { bn1 + " " + bn2 }
    static var twoSpeakers: String { [a1, b1, a2, b2].joined(separator: " ") }
}

// MARK: - Metrics

enum Metrics {
    /// NFC, lowercase, punctuation → space, hyphens split ("fine-tune" = "fine tune").
    static func normalize(_ text: String) -> String {
        let lowered = text.nfc.lowercased().replacingOccurrences(of: "\u{FFFD}", with: "")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                ? " " : Character(scalar)
        }
        return String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character error rate over Unicode scalars with punctuation and spaces removed (Bangla vowel
    /// signs are separate scalars, as in the spike's cer.py).
    static func cer(_ hypothesis: String, _ reference: String) -> Double {
        let h = Array(normalize(hypothesis).replacingOccurrences(of: " ", with: "").unicodeScalars)
        let r = Array(normalize(reference).replacingOccurrences(of: " ", with: "").unicodeScalars)
        return Double(levenshtein(h, r)) / Double(max(1, r.count))
    }

    static func wer(_ hypothesis: String, _ reference: String) -> Double {
        let h = normalize(hypothesis).split(separator: " ").map(String.init)
        let r = normalize(reference).split(separator: " ").map(String.init)
        return Double(levenshtein(h, r)) / Double(max(1, r.count))
    }
}

func percent(_ value: Double) -> String { String(format: "%.1f %%", value * 100) }

// MARK: - Audio helpers

enum TestAudio {
    static func url(_ name: String) -> URL { testAudioDirectory.appendingPathComponent(name) }

    static func load(_ name: String) throws -> [Float] {
        let file = url(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw TestSkip("missing test audio \(name)") }
        return try AudioLoader.load(file)
    }

    /// Writes 16 kHz mono PCM16 (what the recorder produces).
    static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16(max(-32768, min(32767, (sample * 32767).rounded()))))
        }
        try data.write(to: url)
    }

    /// `clips` placed at their start times (seconds) on one silent timeline.
    static func timeline(_ clips: [(samples: [Float], at: Double, gain: Float)], duration: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(duration * 16_000))
        for clip in clips {
            let offset = Int(clip.at * 16_000)
            for (i, value) in clip.samples.enumerated() where offset + i < out.count && offset + i >= 0 {
                out[offset + i] += clip.gain * value
            }
        }
        return out
    }
}

// MARK: - Deterministic randomness

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
}

// MARK: - Models

enum InstalledModels {
    static let store = ModelStore()

    static func require(_ ids: String...) throws {
        for id in ids where !store.isInstalled(id) {
            throw TestSkip("model \(id) is not installed in \(store.directory.path)")
        }
    }

    static func requireAnyWhisper() throws {
        guard store.resolve("auto", role: .general).spec != nil else { throw TestSkip("no Whisper model installed") }
        try require(ModelCatalog.vadID)
    }
}

/// A pipeline that never downloads anything.
func offlinePipeline(codeSwitchPrompt: String?? = nil) -> TranscriptionPipeline {
    var configuration = TranscriptionPipeline.Configuration()
    configuration.diarization.allowDownload = false
    if let codeSwitchPrompt { configuration.codeSwitchPrompt = codeSwitchPrompt }
    return TranscriptionPipeline(models: InstalledModels.store, configuration: configuration)
}

/// Runs the pipeline and prints a short timing line.
func transcribe(_ request: TranscriptionRequest, with pipeline: TranscriptionPipeline = offlinePipeline(),
                label: String) async throws -> TranscriptionOutput {
    let output = try await pipeline.transcribe(request) { _ in }
    let audio = output.stats["seconds.audio"] ?? 0
    let total = output.stats["seconds.total"] ?? 0
    print(String(format: "      %@: %.1f s audio in %.2f s (RTF %.2f; load %.2f s, VAD %.2f s, diarize %.2f s, LID %.2f s, en %.2f s, bn %.2f s) models %@",
                 label, audio, total, total / max(audio, 1e-9), output.stats["seconds.load"] ?? 0,
                 output.stats["seconds.vad"] ?? 0, output.stats["seconds.diarization"] ?? 0,
                 output.stats["seconds.lid"] ?? 0, output.stats["seconds.english"] ?? 0,
                 output.stats["seconds.bangla"] ?? 0, output.modelsUsed.joined(separator: ",")))
    for warning in output.warnings { print("      warning: \(warning)") }
    return output
}

func printTranscript(_ output: TranscriptionOutput) {
    for line in TranscribeCommand.transcriptLines(output, showEcho: true) { print("        \(line)") }
}
