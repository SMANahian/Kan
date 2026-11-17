import Foundation

/// What to record as the "them" track.
public enum CaptureTarget: Sendable {
    /// The call app's processes only (mono mixdown process tap).
    case app(AppActivity)
    /// All system audio except Kan.
    case systemAudio
    /// No remote track (in-person conversation recorded from the mic only).
    case micOnly
}

public struct RecordingRequest: Sendable {
    public var callID: CallID
    public var target: CaptureTarget
    /// Where me.wav / them.wav / anchors.json / session.json are written (KanPaths.callDataDirectory).
    public var directory: URL
    public var captureMic: Bool
    /// Input device to record the user from (the one the call app uses); nil = system default.
    public var preferredInputDeviceUID: String?
    /// Audio from before `start` was called that should be included, if the recorder buffers it
    /// (detection fires a few seconds after the app opens the mic). Informational.
    public var callStartedAt: Date

    public init(callID: CallID, target: CaptureTarget, directory: URL, captureMic: Bool = true,
                preferredInputDeviceUID: String? = nil, callStartedAt: Date = Date()) {
        self.callID = callID
        self.target = target
        self.directory = directory
        self.captureMic = captureMic
        self.preferredInputDeviceUID = preferredInputDeviceUID
        self.callStartedAt = callStartedAt
    }
}

/// RMS levels, 0…1, for the menu-bar meters.
public struct AudioLevels: Sendable, Equatable {
    public var me: Float
    public var them: Float

    public init(me: Float, them: Float) {
        self.me = me
        self.them = them
    }

    public static let zero = AudioLevels(me: 0, them: 0)
}

public enum RecordingIssue: String, Codable, Sendable {
    /// The tap delivers exact zeros while the app is playing: System Audio Recording permission is
    /// probably missing (macOS fails silently).
    case systemAudioSilent
    case micUnavailable
    case micPermissionDenied
    /// No tap starts at all (not even all system audio): only the microphone is being recorded
    /// for now; the recorder keeps retrying.
    case tapFailed
    /// The call app's own tap wouldn't start, so all system audio stands in for it (other apps'
    /// sounds may be included); the recorder keeps trying to switch back.
    case systemAudioFallback
    case tapRebuilt
    case deviceChanged
    case diskFull
    case writeError
}

/// Final state of a recording, also written as `session.json` in the call data directory.
public struct RecordingResult: Codable, Sendable {
    public var callID: CallID
    public var directory: URL
    public var meFile: URL?
    public var themFile: URL?
    public var anchorsFile: URL?
    public var startedAt: Date
    public var endedAt: Date
    public var meSeconds: Double
    public var themSeconds: Double
    /// The call app played through speakers (not headphones): expect mic bleed / echo.
    public var loudspeakerSuspected: Bool
    public var issues: [RecordingIssue]

    public init(callID: CallID, directory: URL, meFile: URL?, themFile: URL?, anchorsFile: URL?,
                startedAt: Date, endedAt: Date, meSeconds: Double, themSeconds: Double,
                loudspeakerSuspected: Bool, issues: [RecordingIssue]) {
        self.callID = callID
        self.directory = directory
        self.meFile = meFile
        self.themFile = themFile
        self.anchorsFile = anchorsFile
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.meSeconds = meSeconds
        self.themSeconds = themSeconds
        self.loudspeakerSuspected = loudspeakerSuspected
        self.issues = issues
    }

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// A live recording. All members are thread-safe.
public protocol RecordingHandle: AnyObject, Sendable {
    var callID: CallID { get }
    var startedAt: Date { get }
    var levels: AudioLevels { get }
    var isPaused: Bool { get }
    var issues: [RecordingIssue] { get }
    /// Seconds since either track last carried audible sound.
    var silenceSeconds: TimeInterval { get }
    /// Called (on any queue) when a new issue appears.
    var onIssue: (@Sendable (RecordingIssue) -> Void)? { get set }
    /// While paused, silence is written so both tracks stay on the same clock.
    func pause()
    func resume()
    /// The call app's process set or devices changed: update the tap without stopping, and move
    /// the microphone to the input the app now uses.
    func retarget(_ activity: AppActivity)
    /// Stop, finalize the WAV files and write session.json. Audio after `trimEndAt` is dropped.
    func stop(trimEndAt: Date?) async -> RecordingResult
    /// Stop and delete everything recorded.
    func discard() async
}

/// Starts recordings. Implemented by `KanAudio.CallRecorder`.
public protocol CallRecording: AnyObject, Sendable {
    func start(_ request: RecordingRequest) throws -> RecordingHandle
}

/// Compresses kept audio after transcription. Implemented by `KanAudio.AudioArchiver`.
public protocol AudioArchiving: Sendable {
    /// Encode me.wav / them.wav in `directory` to AAC .m4a, delete the WAVs, return the assets.
    func archive(directory: URL) async throws -> AudioAssets
    /// Delete raw and archived audio in `directory` (keeps embeddings.json etc.).
    func deleteAudio(in directory: URL) throws
}
