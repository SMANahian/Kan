import Foundation
import KanCore

/// Why a running capture stream needs attention. Delivered on any queue.
public enum CaptureFault: String, Sendable, CustomStringConvertible {
    case formatChanged          // sample rate / channel count changed (AirPods A2DP ↔ HFP, device rate change)
    case deviceDied             // the device disappeared (unplugged, Bluetooth disconnected)
    case ioStoppedAbnormally    // the HAL stopped IO on its own
    case noCallbacks            // watchdog: the IOProc stopped firing
    case serviceRestarted       // coreaudiod restarted: every object id is invalid

    public var description: String { rawValue }
}

/// What a process tap captures.
public struct TapTarget: Sendable, Equatable, CustomStringConvertible {
    public enum Scope: Sendable, Equatable {
        /// Only the listed processes (mono mixdown).
        case processes
        /// Everything the Mac plays except the listed processes / bundle ids (mono global tap).
        case systemAudio
    }

    public var scope: Scope
    /// Core Audio process object ids (not PIDs) to include (`.processes`) or exclude (`.systemAudio`).
    public var processObjectIDs: [UInt32]
    /// macOS 26+: bundle ids to include / exclude as well; with process restore the tap re-attaches
    /// when one of those processes restarts with a new PID.
    public var bundleIDs: [String]

    public init(scope: Scope, processObjectIDs: [UInt32], bundleIDs: [String] = []) {
        self.scope = scope
        self.processObjectIDs = processObjectIDs
        self.bundleIDs = bundleIDs
    }

    /// Tap for a call app: all of its process objects, plus its own (non-shared) bundle ids.
    public static func app(_ activity: AppActivity) -> TapTarget {
        var ids: [String] = []
        for id in [activity.app.bundleID] + activity.processBundleIDs where isTapBundleID(id) && !ids.contains(id) {
            ids.append(id)
        }
        return TapTarget(scope: .processes, processObjectIDs: Array(Set(activity.processObjectIDs)).sorted(), bundleIDs: ids)
    }

    /// Everything except Kan itself.
    public static func systemAudio(excluding ownProcessObject: UInt32?) -> TapTarget {
        TapTarget(scope: .systemAudio, processObjectIDs: ownProcessObject.map { [$0] } ?? [],
                  bundleIDs: [KanPaths.bundleIdentifier])
    }

    /// Bundle ids shared by many apps' helper processes (WebKit's GPU / WebContent processes serve
    /// Safari, Mail, Raycast… alike) must not go into a bundle-id tap: it would record all of them.
    static func isTapBundleID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("com.apple.WebKit.") && !id.hasPrefix("pid:")
    }

    public var description: String {
        switch scope {
        case .processes: return "processes \(processObjectIDs) bundles \(bundleIDs)"
        case .systemAudio: return "system audio excluding \(processObjectIDs) \(bundleIDs)"
        }
    }
}

/// One capture stream (a microphone IOProc or a process-tap aggregate). Driven from one queue.
public protocol CaptureSource: AnyObject {
    /// "MacBook Pro Microphone", "tap: processes […]" — for logs and anchors.json.
    var name: String { get }
    /// Called on any queue when the stream breaks. Set before `start()`.
    var onFault: ((CaptureFault) -> Void)? { get set }
    /// Starts IO; audio then arrives in the returned ring (its sample rate is the stream's rate).
    func start() throws -> CaptureRing
    /// Stops IO and releases every HAL object. Idempotent.
    func stop()
    /// Taps only: change the tapped processes without interrupting IO.
    func retarget(_ target: TapTarget) throws
}

/// Default/topology changes the recorder reacts to.
public enum SystemAudioEvent: Sendable {
    case defaultInputChanged, defaultOutputChanged, devicesChanged, serviceRestarted
}

/// Everything a recording session needs from the machine. `LiveRecordingEnvironment` talks to
/// Core Audio; tests substitute simulated sources and a simulated clock.
public protocol RecordingEnvironment: AnyObject, Sendable {
    /// Host time (`mach_absolute_time` in the live environment).
    func hostTime() -> UInt64
    func wallClock() -> Date
    func microphonePermission() -> PermissionStatus
    /// System Audio Recording as it applies to this process (`Permissions.systemAudioAccess()`).
    func systemAudioAccess() -> SystemAudioAccess
    func devices() -> [AudioDeviceInfo]
    func defaultInputUID() -> String?
    func defaultOutputUID() -> String?
    func makeMicrophoneSource(deviceUID: String) throws -> CaptureSource
    func makeTapSource(_ target: TapTarget) throws -> CaptureSource
    /// Kan's own Core Audio process object, if it is a client yet.
    func ownProcessObjectID() -> UInt32?
    /// Current process objects of the given PIDs / bundle ids (after coreaudiod restarted).
    func resolveProcessObjects(pids: [Int32], bundleIDs: [String]) -> [UInt32]
    /// Calls `handler` on `queue` for default-device, device-list and coreaudiod-restart changes
    /// until the returned token is released.
    func observeSystemAudio(queue: DispatchQueue, handler: @escaping (SystemAudioEvent) -> Void) -> AnyObject?
    func availableDiskBytes(at url: URL) -> Int64?
}

/// Recorder tuning. The defaults are what the app uses.
public struct RecordingOptions: Sendable {
    /// Output sample rate of both tracks.
    public var sampleRate: Double = 16_000
    /// How often captured audio is drained, converted and written; the pump also runs scheduled tap
    /// recovery (on the host clock). nil = only when `RecordingSession.processPendingAudio()` is
    /// called (tests drive a simulated clock).
    public var pumpInterval: TimeInterval? = 0.05
    /// WAV header rewrite interval (crash safety).
    public var headerUpdateInterval: TimeInterval = 2
    /// anchors.json is rewritten this often while recording (and on stop).
    public var anchorsWriteInterval: TimeInterval = 30
    /// Spacing of periodic anchors in a track.
    public var anchorIntervalSeconds: Double = 5
    /// Misalignment tolerated before padding / dropping.
    public var driftToleranceSeconds: Double = 0.1
    /// A source silent for this long is treated as gone: its track is padded in real time.
    public var idlePadSeconds: Double = 0.5
    /// Real-time padding stays this far behind "now" so late audio still fits.
    public var padHoldbackSeconds: Double = 0.2
    /// No IOProc callbacks for this long ⇒ `CaptureFault.noCallbacks`.
    public var watchdogSeconds: Double = 2
    /// Exact digital zeros from the tap for this long ⇒ `RecordingIssue.systemAudioSilent`, unless
    /// System Audio Recording is known to reach Kan (then it is real silence; checked again after
    /// every such stretch).
    public var systemAudioSilentSeconds: Double = 20
    /// A track "has sound" above this level (drives `silenceSeconds`).
    public var audibleThresholdDBFS: Double = -50
    /// Rebuild budget per source: a burst of this many, then one every 60 s / this (see
    /// `RebuildLimiter`). Every tap creation after the first counts; a used-up budget delays the next
    /// attempt.
    public var maxRebuildsPerMinute: Int = 5
    /// Coalesces bursts of HAL notifications into one rebuild.
    public var rebuildDebounceSeconds: Double = 0.25
    /// Delays between quick retries of a failed (re)start before the next fallback: the call app's
    /// tap → all system audio → no call audio for now.
    public var retryDelaysSeconds: [Double] = [0.5, 2]
    /// While no tap runs, or all system audio stands in for the call app's tap, try again this often.
    public var tapRecoverySeconds: Double = 10
    /// While the microphone is unavailable, retry this often.
    public var microphoneRetrySeconds: Double = 5
    /// `start` refuses to record with less free space than this.
    public var minimumFreeDiskBytes: Int64 = 50 * 1_024 * 1_024
    /// Capacity of each capture ring.
    public var ringSeconds: Double = 10

    public init() {}
}
