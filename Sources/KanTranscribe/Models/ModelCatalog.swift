import Foundation
import KanCore

/// A model Kan can download and use.
public struct ModelSpec: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// whisper.cpp ggml model (one file).
        case whisper
        /// Silero VAD for whisper.cpp (one file).
        case vad
        /// FluidAudio CoreML diarization models (a directory, downloaded through FluidAudio).
        case fluidAudio
    }

    public var id: String
    public var displayName: String
    public var detail: String
    public var role: ModelRole
    public var kind: Kind
    /// File (or directory, for `.fluidAudio`) name inside the models directory.
    public var fileName: String
    public var url: URL?
    public var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the file, when published.
    public var sha256: String?
    /// Bengali-optimized tokenizer (Bengali.AI fine-tunes): ~3× fewer tokens for Bangla, so Bangla
    /// chunks may be up to 15 s; English is degraded, so it decodes Bangla only.
    public var banglaTokenizer: Bool
    /// large-v3-turbo family: mislabels Bangla as Hindi/Gujarati, so language ID compares the mass
    /// of Bangla + other Indic languages against English.
    public var weakBanglaLanguageID: Bool
    /// Trained with timestamp tokens. The Bengali.AI fine-tunes were not: with timestamps on they
    /// cut segments inside characters and loop, so they decode with `no_timestamps` (one segment per
    /// chunk, word times spread over the chunk).
    public var timestamps: Bool

    public init(id: String, displayName: String, detail: String, role: ModelRole, kind: Kind, fileName: String,
                url: URL?, sizeBytes: Int64, sha256: String? = nil, banglaTokenizer: Bool = false,
                weakBanglaLanguageID: Bool = false, timestamps: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.role = role
        self.kind = kind
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.banglaTokenizer = banglaTokenizer
        self.weakBanglaLanguageID = weakBanglaLanguageID
        self.timestamps = timestamps ?? !banglaTokenizer
    }

    /// Stock multilingual Whisper (can do language ID and English).
    public var isStockWhisper: Bool { kind == .whisper && !banglaTokenizer }
}

/// Kan's model catalog (sizes and SHA-256 from the Hugging Face LFS metadata, checked 2026-11-16).
public enum ModelCatalog {
    public static let vadID = "silero-v6.2.0"
    public static let diarizationID = "fluidaudio-diarization"

    public static let all: [ModelSpec] = [
        ModelSpec(id: "large-v3-q5_0", displayName: "Whisper large-v3 (q5_0)",
                  detail: "Best all-round model: language detection, English and fallback Bangla. 1.1 GB, about 2.1 GB of memory.",
                  role: .general, kind: .whisper, fileName: "ggml-large-v3-q5_0.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3-q5_0.bin"), sizeBytes: 1_081_140_203,
                  sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
        ModelSpec(id: "large-v3", displayName: "Whisper large-v3",
                  detail: "Full-precision large-v3: same quality as q5_0 with twice the memory. 3.1 GB, about 4.3 GB of memory.",
                  role: .general, kind: .whisper, fileName: "ggml-large-v3.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3.bin"), sizeBytes: 3_095_033_483,
                  sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
        ModelSpec(id: "large-v3-turbo", displayName: "Whisper large-v3-turbo",
                  detail: "Fast English (2–3× faster than large-v3, same accuracy). Poor at Bangla. 1.6 GB.",
                  role: .english, kind: .whisper, fileName: "ggml-large-v3-turbo.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3-turbo.bin"), sizeBytes: 1_624_555_275,
                  sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
                  weakBanglaLanguageID: true),
        ModelSpec(id: "large-v3-turbo-q8_0", displayName: "Whisper large-v3-turbo (q8_0)",
                  detail: "Quantized turbo for English with less disk and memory. 874 MB.",
                  role: .english, kind: .whisper, fileName: "ggml-large-v3-turbo-q8_0.bin",
                  url: hf("ggerganov/whisper.cpp", "ggml-large-v3-turbo-q8_0.bin"), sizeBytes: 874_188_075,
                  sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
                  weakBanglaLanguageID: true),
        ModelSpec(id: "bengali-medium-q8_0", displayName: "Bangla Whisper-medium (q8_0)",
                  detail: "Bengali.AI Whisper-medium fine-tune (tugstugi, Kaggle 1st place) with a Bangla tokenizer: much better Bangla spelling, longer chunks. Bangla only. 823 MB.",
                  role: .bangla, kind: .whisper, fileName: "ggml-bengali-whisper-medium-q8_0.bin",
                  url: hf("SayedShaun/bengali-whisper-medium-ggml", "ggml-model-q8_0.bin"), sizeBytes: 823_414_983,
                  sha256: "a6827a244c5041a5c97a9d04e5b0a8076f0aad38faef5dbec8943d833dfe04eb",
                  banglaTokenizer: true),
        ModelSpec(id: "bengali-medium-q5_0", displayName: "Bangla Whisper-medium (q5_0)",
                  detail: "Smaller quantization of the Bengali.AI fine-tune. Bangla only. 539 MB.",
                  role: .bangla, kind: .whisper, fileName: "ggml-bengali-whisper-medium-q5_0.bin",
                  url: hf("winshades/bengaliai-whisper-medium-ggml", "ggml-bengaliai-whisper-medium-q5_0.bin"),
                  sizeBytes: 539_257_671,
                  sha256: "2c64c7f1e2c8f2417ed1fe5b78c7238933c00a2cdc2ef33e7087a95475256605",
                  banglaTokenizer: true),
        ModelSpec(id: vadID, displayName: "Silero VAD v6.2.0",
                  detail: "Finds speech in each track before transcription. 0.9 MB.",
                  role: .vad, kind: .vad, fileName: "ggml-silero-v6.2.0.bin",
                  url: hf("ggml-org/whisper-vad", "ggml-silero-v6.2.0.bin"), sizeBytes: 885_098,
                  sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"),
        ModelSpec(id: diarizationID, displayName: "Speaker models (FluidAudio)",
                  detail: "Sortformer + WeSpeaker CoreML models that tell remote speakers apart. About 130 MB.",
                  role: .diarization, kind: .fluidAudio, fileName: "FluidAudio", url: nil, sizeBytes: 130_000_000),
    ]

    /// "auto" preference per role, best first.
    public static let autoPreference: [ModelRole: [String]] = [
        .general: ["large-v3-q5_0", "large-v3", "large-v3-turbo", "large-v3-turbo-q8_0"],
        .english: ["large-v3-turbo", "large-v3-turbo-q8_0"],
        .bangla: ["bengali-medium-q8_0", "bengali-medium-q5_0"],
        .vad: [vadID],
        .diarization: [diarizationID],
    ]

    public static func spec(_ id: String) -> ModelSpec? { all.first { $0.id == id } }

    private static func hf(_ repo: String, _ file: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")
    }
}
