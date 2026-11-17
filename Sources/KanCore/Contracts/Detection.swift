import Foundation

/// The app that owns one or more Core Audio client processes (helpers are folded into their
/// parent: "Google Chrome Helper" → Google Chrome, Zen's child processes → Zen, WebKit.GPU → Safari).
public struct AppIdentity: Codable, Sendable, Hashable {
    public var bundleID: String
    public var name: String
    /// Path of the owning .app bundle, when known.
    public var path: String?
    /// PID of the owning (main) process.
    public var pid: Int32

    public init(bundleID: String, name: String, path: String? = nil, pid: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.pid = pid
    }
}

public enum AppCategory: String, Codable, Sendable {
    case meeting        // native conferencing apps (Zoom, Teams, Webex, FaceTime, Slack, Discord…)
    case messaging      // chat apps with calls; their mic use may also be a voice note (Telegram, WhatsApp…)
    case browser        // any web browser (meetings run in tabs)
    case ignored        // dictation tools, recorders, system daemons — never a call
    case unknown
}

/// One owning app's current audio state, aggregated over all of its Core Audio client processes.
public struct AppActivity: Sendable, Hashable {
    public var app: AppIdentity
    public var category: AppCategory
    public var micActive: Bool
    public var outputActive: Bool
    /// Core Audio process OBJECT ids (not PIDs) of every process owned by this app — what a tap needs.
    public var processObjectIDs: [UInt32]
    public var processBundleIDs: [String]
    public var pids: [Int32]
    /// UIDs of the devices this app's processes use (input / output scope).
    public var inputDeviceUIDs: [String]
    public var outputDeviceUIDs: [String]

    public init(app: AppIdentity, category: AppCategory, micActive: Bool, outputActive: Bool,
                processObjectIDs: [UInt32] = [], processBundleIDs: [String] = [], pids: [Int32] = [],
                inputDeviceUIDs: [String] = [], outputDeviceUIDs: [String] = []) {
        self.app = app
        self.category = category
        self.micActive = micActive
        self.outputActive = outputActive
        self.processObjectIDs = processObjectIDs
        self.processBundleIDs = processBundleIDs
        self.pids = pids
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUIDs = outputDeviceUIDs
    }
}

/// What a browser tab / window says about the meeting.
public struct MeetingInfo: Codable, Sendable, Hashable {
    public var platform: CallPlatform
    public var title: String?
    public var url: String?

    public init(platform: CallPlatform, title: String? = nil, url: String? = nil) {
        self.platform = platform
        self.title = title
        self.url = url
    }
}

/// A detected (or manually started) call session.
public struct DetectedCall: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var app: AppIdentity
    public var category: AppCategory
    /// When the app acquired the microphone (recording should cover audio from here).
    public var startedAt: Date
    public var platform: CallPlatform
    public var meeting: MeetingInfo?
    /// Started by the user from the menu; never auto-ended (the stale-silence guard still applies).
    public var isManual: Bool

    public init(id: UUID = UUID(), app: AppIdentity, category: AppCategory, startedAt: Date,
                platform: CallPlatform, meeting: MeetingInfo? = nil, isManual: Bool = false) {
        self.id = id
        self.app = app
        self.category = category
        self.startedAt = startedAt
        self.platform = platform
        self.meeting = meeting
        self.isManual = isManual
    }
}

public enum DetectionEvent: Sendable {
    /// Policy `.auto`: start recording now.
    case started(DetectedCall)
    /// Policy `.ask`: start a tentative recording and ask the user.
    case ask(DetectedCall)
    /// Better platform/title information for an ongoing call (same id).
    case meetingInfo(DetectedCall)
    /// The call app's process set (helper restarted…) or its input/output devices changed:
    /// retarget the recording (the tap and the microphone follow the app).
    case activityChanged(DetectedCall, AppActivity)
    /// The app released the mic; the call ends at `deadline` unless it resumes.
    case ending(DetectedCall, deadline: Date)
    /// The app took the mic again before the deadline.
    case resumed(DetectedCall)
    /// The call is over. `endedAt` = when the mic was released (trim the recording there).
    case ended(DetectedCall, endedAt: Date)
    /// No audio on either track for a long time: ask "Still in a call?".
    case stale(DetectedCall)
}

public enum UserCallResponse: Sendable {
    case record             // answer to `.ask`: keep the tentative recording
    case notNow             // answer to `.ask`: discard, ignore this session
    case never              // answer to `.ask`: discard and never record this app (caller updates settings)
    case keepRecording      // during `.ending` / `.stale`: the call is still going
    case endNow             // stop immediately
}

/// Detection tuning derived from `KanSettings`.
public struct DetectionConfig: Sendable, Equatable {
    public var enabled: Bool
    public var pausedUntil: Date?
    public var startConfirmSeconds: Double
    public var endGraceNativeSeconds: Double
    public var endGraceBrowserSeconds: Double
    public var staleSilenceSeconds: Double
    /// Apps whose mic use may be a recorded message (messaging apps; Slack, Teams and Element clips,
    /// see `KnownApp.requiresOutput`) must also be playing audio to count as a call.
    public var messagingRequiresOutput: Bool
    public var appPolicies: [String: AppPolicy]
    public var browserPolicy: AppPolicy
    public var unknownAppPolicy: AppPolicy

    public init(enabled: Bool = true, pausedUntil: Date? = nil, startConfirmSeconds: Double = 3,
                endGraceNativeSeconds: Double = 15, endGraceBrowserSeconds: Double = 30,
                staleSilenceSeconds: Double = 900, messagingRequiresOutput: Bool = true,
                appPolicies: [String: AppPolicy] = [:], browserPolicy: AppPolicy = .auto,
                unknownAppPolicy: AppPolicy = .ask) {
        self.enabled = enabled
        self.pausedUntil = pausedUntil
        self.startConfirmSeconds = startConfirmSeconds
        self.endGraceNativeSeconds = endGraceNativeSeconds
        self.endGraceBrowserSeconds = endGraceBrowserSeconds
        self.staleSilenceSeconds = staleSilenceSeconds
        self.messagingRequiresOutput = messagingRequiresOutput
        self.appPolicies = appPolicies
        self.browserPolicy = browserPolicy
        self.unknownAppPolicy = unknownAppPolicy
    }

    public init(settings: KanSettings, pausedUntil: Date? = nil) {
        self.init(enabled: settings.autoDetect, pausedUntil: pausedUntil,
                  startConfirmSeconds: settings.startConfirmSeconds,
                  endGraceNativeSeconds: settings.endGraceNativeSeconds,
                  endGraceBrowserSeconds: settings.endGraceBrowserSeconds,
                  staleSilenceSeconds: settings.staleSilenceMinutes * 60,
                  appPolicies: settings.appPolicies, browserPolicy: settings.browserPolicy,
                  unknownAppPolicy: settings.unknownAppPolicy)
    }

    /// Effective policy for an app: explicit override, then category defaults.
    public func policy(for app: AppIdentity, category: AppCategory) -> AppPolicy {
        if let p = appPolicies[app.bundleID] { return p }
        switch category {
        case .meeting, .messaging: return .auto
        case .browser: return browserPolicy
        case .ignored: return .never
        case .unknown: return unknownAppPolicy
        }
    }
}

/// Watches which apps use the microphone and turns that into call start/end events.
/// Implemented by `KanDetect.CallDetector`. Events are delivered on the main queue.
public protocol CallDetecting: AnyObject {
    var onEvent: (@MainActor (DetectionEvent) -> Void)? { get set }
    func start()
    func stop()
    func update(config: DetectionConfig)
    /// Forward the user's answer to an `.ask`, `.ending` or `.stale` prompt.
    func respond(_ response: UserCallResponse, to callID: UUID)
    /// Seconds since either recorded track last had audible sound (drives the stale guard).
    func reportSilence(seconds: TimeInterval, for callID: UUID)
    /// Register a call the user started from the menu so detection doesn't start another one.
    func beginManualSession(_ call: DetectedCall)
    /// The manual session was stopped by the user.
    func endManualSession(_ callID: UUID)
    /// Apps currently using audio (for "Record <app>" in the menu), excluding Kan itself.
    func currentActivities() -> [AppActivity]
}
