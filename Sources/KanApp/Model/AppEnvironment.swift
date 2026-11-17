import AppKit
import Foundation
import KanCore

/// Opens the app's SwiftUI windows. Implemented by `WindowRouter`; absent in the headless self-test.
@MainActor
protocol AppUIBridge: AnyObject {
    func openLibrary()
    func openSettings()
    func openOnboarding()
}

/// A calendar event matched to a call.
struct CalendarMatch: Sendable, Equatable, Codable {
    var title: String
    var attendees: [String]
    var startDate: Date
    var endDate: Date
}

/// Calendar lookups: EventKit in the app (`CalendarProvider`), a stub in the self-test.
/// Thread-safe; `event(around:)` blocks briefly, so call it off the main thread.
protocol CalendarProviding: AnyObject, Sendable {
    func authorizationStatus() -> PermissionStatus
    /// Shows the system prompt (only ever called from an explicit user action).
    func requestAccess() async -> PermissionStatus
    /// The event the call most likely belongs to, or nil (also nil without access).
    func event(around start: Date) -> CalendarMatch?
}

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings › Login Items.
    case requiresApproval
    case unavailable(String)
}

/// Launch at login (`SMAppService.mainApp` in the app, a stub in the self-test).
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

enum GlobalHotkey: String, CaseIterable, Sendable {
    case addBookmark, openLibrary, toggleRecording

    /// "⌃⌥⌘B".
    var displayName: String {
        switch self {
        case .addBookmark: return "⌃⌥⌘B"
        case .openLibrary: return "⌃⌥⌘L"
        case .toggleRecording: return "⌃⌥⌘R"
        }
    }

    var actionDescription: String {
        switch self {
        case .addBookmark: return "Bookmark this moment"
        case .openLibrary: return "Open the library"
        case .toggleRecording: return "Start / stop recording all system audio + mic"
        }
    }
}

/// System-wide keyboard shortcuts (Carbon hot keys in the app; none in the self-test).
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// Registers every `GlobalHotkey` (enabled) or unregisters them. Returns the ones that failed.
    @discardableResult
    func setEnabled(_ enabled: Bool, handler: @escaping @MainActor (GlobalHotkey) -> Void) -> [GlobalHotkey]
}

/// Everything AppModel needs from the outside world besides the services: the clock, OS
/// integrations and side effects. `live()` for the app, `headless(now:)` for the self-test (no
/// windows, hot keys, login items, pasteboard or Finder).
struct AppEnvironment {
    var now: @Sendable () -> Date
    var isHeadless: Bool
    var calendar: CalendarProviding
    var loginItem: LoginItemControlling
    var hotkeys: HotkeyRegistering?
    var copyToPasteboard: @MainActor (String) -> Void
    var revealInFinder: @MainActor ([URL]) -> Void
    var openURL: @MainActor (URL) -> Void
    /// Quits and starts Kan again (System Audio Recording changes, library location).
    var relaunch: @MainActor () -> Void
    /// `ProcessInfo.beginActivity` / `endActivity`: App Nap coalesces the timers of an app with no
    /// window open and lowers its priority, so Kan holds an activity while it records or
    /// transcribes (`AppModel.updateActivities`). Recorded instead in the self-test.
    var beginActivity: @MainActor (_ options: ProcessInfo.ActivityOptions, _ reason: String) -> NSObjectProtocol
    var endActivity: @MainActor (NSObjectProtocol) -> Void
    /// Whether iCloud Drive syncs a folder (`KanPaths.isInICloudDrive`); may block briefly, so
    /// call it off the main thread. A stub in the self-test.
    var isInICloudDrive: @Sendable (URL) -> Bool
    /// The directory holding every call's working data (KanPaths.calls).
    var callsDirectory: URL
    /// How often the audio retention sweep runs.
    var retentionSweepInterval: TimeInterval = 6 * 60 * 60
    /// Start toasts hide after this long (hovering pauses the countdown).
    var startToastSeconds: TimeInterval = 8
    /// How often a waiting label panel checks whether the unrecorded call has ended.
    var labelWaitPollSeconds: TimeInterval = 2

    func callDataDirectory(for id: CallID) -> URL {
        Self.callDataDirectory(for: id, in: callsDirectory)
    }

    /// Placeholder for an id that isn't a canonical ULID: it never exists, and a hidden name keeps
    /// it out of every scan of the Calls directory.
    static let malformedCallDirectoryName = ".malformed-call-id"

    /// `<calls>/<id>`, the call's working data. Kan generates only well-formed ids and refuses
    /// others when it decodes them; should one get here anyway ("", "..", "../x"), it resolves to a
    /// placeholder that never exists instead of the Calls directory itself or a path outside it.
    static func callDataDirectory(for id: CallID, in callsDirectory: URL) -> URL {
        guard id.isWellFormed else {
            KanLog.warning("Refused a malformed call id as a call data directory", category: "library")
            return callsDirectory.appendingPathComponent(malformedCallDirectoryName, isDirectory: true)
        }
        return callsDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    @MainActor
    static func live() -> AppEnvironment {
        AppEnvironment(
            now: { Date() },
            isHeadless: false,
            calendar: CalendarProvider(),
            loginItem: LoginItemController(),
            hotkeys: GlobalHotkeys(),
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            revealInFinder: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
            openURL: { url in NSWorkspace.shared.open(url) },
            relaunch: { AppRelauncher.relaunch() },
            beginActivity: { options, reason in ProcessInfo.processInfo.beginActivity(options: options, reason: reason) },
            endActivity: { ProcessInfo.processInfo.endActivity($0) },
            isInICloudDrive: { KanPaths.isInICloudDrive($0) },
            callsDirectory: KanPaths.calls)
    }

    /// For the self-test: side effects are recorded in `effects` instead of reaching the system.
    @MainActor
    static func headless(now: @escaping @Sendable () -> Date, effects: HeadlessEffects) -> AppEnvironment {
        var environment = AppEnvironment(
            now: now,
            isHeadless: true,
            calendar: StaticCalendar(),
            loginItem: effects,
            hotkeys: nil,
            copyToPasteboard: { effects.pasteboard = $0 },
            revealInFinder: { effects.revealed = $0 },
            openURL: { effects.openedURLs.append($0) },
            relaunch: { effects.relaunchRequests += 1 },
            beginActivity: { _, reason in effects.beginActivity(reason) },
            endActivity: { effects.endActivity($0) },
            isInICloudDrive: { [cloud = effects.cloudDrive] url in cloud.syncs(url) },
            callsDirectory: KanPaths.calls)
        environment.labelWaitPollSeconds = 0.02
        return environment
    }
}

/// Records what the headless environment would have done.
@MainActor
final class HeadlessEffects: LoginItemControlling {
    var pasteboard: String?
    var revealed: [URL] = []
    var openedURLs: [URL] = []
    var relaunchRequests = 0
    /// The folders the self-test pretends iCloud Drive syncs.
    nonisolated let cloudDrive = CloudDriveStub()
    /// The reasons of the power activities held now, and of every one begun.
    private(set) var activities: [String] = []
    private(set) var activityHistory: [String] = []
    private var loginItemEnabled = false

    var status: LoginItemStatus { loginItemEnabled ? .enabled : .disabled }
    func setEnabled(_ enabled: Bool) throws { loginItemEnabled = enabled }
    func openSystemSettings() {}

    private final class ActivityToken: NSObject {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    func beginActivity(_ reason: String) -> NSObjectProtocol {
        activities.append(reason)
        activityHistory.append(reason)
        return ActivityToken(reason)
    }

    func endActivity(_ token: NSObjectProtocol) {
        guard let token = token as? ActivityToken, let index = activities.firstIndex(of: token.reason) else { return }
        activities.remove(at: index)
    }
}

/// Folders "synced by iCloud Drive" in the self-test (and everything inside them). Thread-safe.
final class CloudDriveStub: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String] = []

    func setSynced(_ synced: [URL]) { lock.withLock { folders = synced.map(\.standardizedFileURL.path) } }

    func syncs(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return lock.withLock { folders.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }
}

/// A calendar without access (the self-test never asks for Calendar permission).
final class StaticCalendar: CalendarProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var match: CalendarMatch?

    init(match: CalendarMatch? = nil) { self.match = match }

    func set(_ match: CalendarMatch?) { lock.withLock { self.match = match } }
    func authorizationStatus() -> PermissionStatus { lock.withLock { match == nil ? .notDetermined : .granted } }
    func requestAccess() async -> PermissionStatus { authorizationStatus() }
    func event(around start: Date) -> CalendarMatch? { lock.withLock { match } }
}

/// Quits Kan and opens it again once this process is gone.
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            KanLog.warning("Relaunch requested, but Kan isn't running from an app bundle; quitting only")
            NSApp.terminate(nil)
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this process has exited (it may be finalizing a recording), then reopen it.
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; /usr/bin/open \"$0\"", bundle.path]
        do {
            try process.run()
            KanLog.info("Relaunching Kan")
        } catch {
            KanLog.error("Couldn't schedule the relaunch: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }
}
