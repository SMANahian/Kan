import Foundation

/// Everything the transcriber needs for one call. Persisted in the processing queue.
public struct TranscriptionRequest: Codable, Sendable, Hashable {
    public var callID: CallID
    /// 16 kHz mono PCM16 WAVs (nil when that track wasn't recorded).
    public var meFile: URL?
    public var themFile: URL?
    /// Host-time anchors written by the recorder (optional; used to align the tracks).
    public var anchorsFile: URL?
    public var languageMode: LanguageMode
    /// Display name for the mic track.
    public var userName: String
    /// Names/jargon hint for the recognizer.
    public var vocabulary: String
    public var diarize: Bool
    public var maxRemoteSpeakers: Int?
    public var echoSuppression: Bool
    public var loudspeakerSuspected: Bool
    /// Model ids or "auto".
    public var generalModelID: String
    public var englishModelID: String
    public var banglaModelID: String

    public init(callID: CallID, meFile: URL?, themFile: URL?, anchorsFile: URL? = nil,
                languageMode: LanguageMode = .auto, userName: String = "Me", vocabulary: String = "",
                diarize: Bool = true, maxRemoteSpeakers: Int? = nil, echoSuppression: Bool = true,
                loudspeakerSuspected: Bool = false, generalModelID: String = "auto",
                englishModelID: String = "auto", banglaModelID: String = "auto") {
        self.callID = callID
        self.meFile = meFile
        self.themFile = themFile
        self.anchorsFile = anchorsFile
        self.languageMode = languageMode
        self.userName = userName
        self.vocabulary = vocabulary
        self.diarize = diarize
        self.maxRemoteSpeakers = maxRemoteSpeakers
        self.echoSuppression = echoSuppression
        self.loudspeakerSuspected = loudspeakerSuspected
        self.generalModelID = generalModelID
        self.englishModelID = englishModelID
        self.banglaModelID = banglaModelID
    }

    /// Build a request from settings for a finished recording.
    public init(recording: RecordingResult, settings: KanSettings, languageMode: LanguageMode? = nil) {
        self.init(callID: recording.callID, meFile: recording.meFile, themFile: recording.themFile,
                  anchorsFile: recording.anchorsFile, languageMode: languageMode ?? settings.languageMode,
                  userName: settings.effectiveUserName, vocabulary: settings.vocabulary,
                  diarize: settings.diarize, maxRemoteSpeakers: settings.maxRemoteSpeakers,
                  echoSuppression: settings.echoSuppression,
                  loudspeakerSuspected: recording.loudspeakerSuspected,
                  generalModelID: settings.generalModelID, englishModelID: settings.englishModelID,
                  banglaModelID: settings.banglaModelID)
    }
}

/// Result of transcribing one call.
public struct TranscriptionOutput: Sendable {
    /// Sorted by start time; ids are 0..<n.
    public var segments: [TranscriptSegment]
    /// "me" first, then "s1", "s2", … (default names "Speaker 1", …).
    public var speakers: [Speaker]
    public var languages: [String]
    /// L2-normalized 256-d WeSpeaker centroid per remote speaker id (for voiceprints).
    public var speakerEmbeddings: [String: [Float]]
    public var modelsUsed: [String]
    public var warnings: [String]
    /// Timing and quality counters, e.g. "seconds.total", "chunks.bn", "fallbacks".
    public var stats: [String: Double]

    public init(segments: [TranscriptSegment], speakers: [Speaker], languages: [String],
                speakerEmbeddings: [String: [Float]] = [:], modelsUsed: [String] = [],
                warnings: [String] = [], stats: [String: Double] = [:]) {
        self.segments = segments
        self.speakers = speakers
        self.languages = languages
        self.speakerEmbeddings = speakerEmbeddings
        self.modelsUsed = modelsUsed
        self.warnings = warnings
        self.stats = stats
    }
}

public enum PipelineStage: String, Codable, Sendable {
    case preparing, detectingSpeech, separatingSpeakers, identifyingLanguage
    case transcribingEnglish, transcribingBangla, assembling, finishing

    public var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .detectingSpeech: return "Finding speech"
        case .separatingSpeakers: return "Separating speakers"
        case .identifyingLanguage: return "Detecting language"
        case .transcribingEnglish: return "Transcribing English"
        case .transcribingBangla: return "Transcribing Bangla"
        case .assembling: return "Assembling transcript"
        case .finishing: return "Finishing"
        }
    }
}

public struct PipelineProgress: Sendable, Equatable {
    public var stage: PipelineStage
    /// Overall progress 0…1.
    public var fraction: Double
    public var message: String?

    public init(stage: PipelineStage, fraction: Double, message: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.message = message
    }
}

public enum TranscriptionError: Error, LocalizedError, Sendable {
    case noAudio
    case modelMissing(String)
    case audioUnreadable(String)
    case engineFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAudio: return "The recording contains no audio."
        case .modelMissing(let m): return "Model not installed: \(m)"
        case .audioUnreadable(let m): return "Could not read audio: \(m)"
        case .engineFailed(let m): return "Transcription failed: \(m)"
        case .cancelled: return "Transcription was cancelled."
        }
    }
}

/// Turns a recording into a transcript. Implemented by `KanTranscribe.TranscriptionPipeline`.
/// Must honour Task cancellation (throw `TranscriptionError.cancelled` / CancellationError).
public protocol Transcribing: AnyObject, Sendable {
    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> TranscriptionOutput

    /// Load and free the models a transcription with these settings would use, once, so one-time
    /// compilation (Metal kernels, CoreML specialization) happens off the critical path. Optional.
    func warmUp(settings: KanSettings) async
}

extension Transcribing {
    public func warmUp(settings: KanSettings) async {}
}

// MARK: - Models

public enum ModelRole: String, Codable, Sendable, CaseIterable {
    case general        // language ID + English + Bangla fallback (Whisper large-v3 family)
    case english        // fast English decoding (Whisper large-v3-turbo)
    case bangla         // Bangla-optimized decoding (Bengali.AI Whisper-medium fine-tune)
    case vad            // Silero VAD
    case diarization    // FluidAudio speaker models
}

public struct ModelInfo: Sendable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var detail: String
    public var role: ModelRole
    public var sizeBytes: Int64
    public var installed: Bool
    public var recommended: Bool
    public var downloadable: Bool

    public init(id: String, displayName: String, detail: String, role: ModelRole, sizeBytes: Int64,
                installed: Bool, recommended: Bool, downloadable: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.role = role
        self.sizeBytes = sizeBytes
        self.installed = installed
        self.recommended = recommended
        self.downloadable = downloadable
    }
}

public struct ModelReadiness: Sendable, Equatable {
    /// Enough is installed to produce a transcript.
    public var canTranscribe: Bool
    /// Human-readable problems ("No Whisper model installed").
    public var missing: [String]
    /// Suggestions ("Download the Bangla model for much better Bangla").
    public var recommendations: [String]
    /// Model id resolved for each role ("auto" resolved), nil when unavailable.
    public var resolved: [ModelRole: String]

    public init(canTranscribe: Bool, missing: [String] = [], recommendations: [String] = [],
                resolved: [ModelRole: String] = [:]) {
        self.canTranscribe = canTranscribe
        self.missing = missing
        self.recommendations = recommendations
        self.resolved = resolved
    }
}

/// Model catalog, downloads and resolution. Implemented by `KanTranscribe.ModelStore`.
public protocol ModelManaging: AnyObject, Sendable {
    func availableModels() -> [ModelInfo]
    /// Resumable download into `KanPaths.models`; progress 0…1 on any queue.
    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ id: String) throws
    func readiness(for settings: KanSettings) -> ModelReadiness
}
