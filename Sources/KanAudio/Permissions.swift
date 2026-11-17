import AVFoundation
import AppKit
import ApplicationServices
import CoreServices
import Foundation
import KanCore
import os

/// Browsers whose tabs can be read with AppleScript (Automation permission). Firefox, Zen and
/// other Gecko browsers have no tab scripting; Kan reads their window titles via Accessibility.
public enum ScriptableBrowsers {
    public enum Family: Sendable, Equatable { case chromium, safari }

    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "org.chromium.Chromium",
    ]
    public static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    public static func family(bundleID: String) -> Family? {
        if chromiumBundleIDs.contains(bundleID) { return .chromium }
        if safariBundleIDs.contains(bundleID) { return .safari }
        return nil
    }
}

/// System Audio Recording as it applies to the running process, which TCC alone can't tell: macOS
/// applies a grant made in System Settings only after the app is relaunched (System Settings says
/// so: "… may not be able to record the audio from running applications until it is quit"); until
/// then the tap delivers exact zeros although TCC already reports the permission granted. The
/// answer to a prompt applies at once.
public enum SystemAudioAccess: String, Sendable, Equatable {
    /// Granted, and the grant reaches this process.
    case granted
    /// Granted after this process saw the permission denied (at launch or since): the grant came
    /// from System Settings (macOS never prompts again after a denial) and applies after a relaunch.
    case grantedPendingRelaunch
    /// Denied, not asked yet, or unknown.
    case notGranted

    /// - Parameters:
    ///   - status: TCC's answer now.
    ///   - deniedSinceLaunch: this process saw the permission denied at some point.
    public init(status: PermissionStatus, deniedSinceLaunch: Bool) {
        guard status == .granted else {
            self = .notGranted
            return
        }
        self = deniedSinceLaunch ? .grantedPendingRelaunch : .granted
    }
}

/// Permission checks and prompts. Implements `PermissionsProviding`.
///
/// * Microphone: AVCaptureDevice.
/// * System Audio Recording: there is no public API. The private TCC calls (`TCCAccessPreflight` /
///   `TCCAccessRequest` for kTCCServiceAudioCapture, as AudioCap does) are loaded with dlopen; if they
///   are missing the status is `.unknown`, and `request` starts a one-second throw-away tap instead,
///   because the prompt appears on the first AudioDeviceStart of an aggregate containing a tap.
///   A change made in System Settings applies only after Kan is relaunched: `systemAudioAccess()`
///   tells whether the current grant reaches this process.
/// * Accessibility: AXIsProcessTrusted (prompting only in `request`).
/// * Automation: AEDeterminePermissionToAutomateTarget for each running scriptable browser
///   (never prompts in `status`; never launches a browser).
/// * Calendar: `.unknown` — the app checks EventKit itself.
///
/// Thread-safe. `status` may be called on the main thread (the Apple-event check is moved off it).
public final class Permissions: PermissionsProviding, @unchecked Sendable {
    public init() {
        Permissions.noteLaunchStatus()
    }

    /// Reads System Audio Recording once, so a denial at launch is known (both `Permissions` and
    /// `LiveRecordingEnvironment` call it when they are created, at app start). Idempotent.
    public static func noteLaunchStatus() {
        _ = SystemAudioGrant.launchStatus
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: return Permissions.microphoneStatus()
        case .systemAudio: return Permissions.systemAudioPreflight()
        case .accessibility: return Permissions.accessibilityStatus()
        case .automation: return Permissions.offMain(timeout: 2, fallback: .unknown) { Permissions.automationStatus(askUserIfNeeded: false) }
        case .calendar: return .unknown
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            if Permissions.microphoneStatus() == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            return Permissions.microphoneStatus()
        case .systemAudio:
            return await requestSystemAudio()
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([Permissions.axPromptKey: true] as CFDictionary)
            return Permissions.accessibilityStatus()
        case .automation:
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Permissions.automationStatus(askUserIfNeeded: true))
                }
            }
        case .calendar:
            return .unknown
        }
    }

    public func openSystemSettings(_ kind: PermissionKind) {
        guard let url = Permissions.settingsURL(for: kind) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    public func needsRelaunch(_ kind: PermissionKind) -> Bool {
        kind == .systemAudio && Permissions.systemAudioAccess() == .grantedPendingRelaunch
    }

    /// Privacy & Security deep links (the AudioCapture anchor exists from macOS 26; before that the
    /// list lives under Screen & System Audio Recording).
    public static func settingsURL(for kind: PermissionKind, macOS26: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))) -> URL? {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .systemAudio: anchor = macOS26 ? "Privacy_AudioCapture" : "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        case .calendar: anchor = "Privacy_Calendars"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    // MARK: Individual checks (never prompt)

    public static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// TCCAccessPreflight(kTCCServiceAudioCapture): 0 granted, 1 denied, 2 not determined.
    public static func systemAudioPreflight() -> PermissionStatus {
        guard let preflight = TCC.preflight else { return .unknown }
        let status = TCC.status(preflight(TCC.audioCaptureService, nil))
        SystemAudioGrant.observe(status)
        return status
    }

    /// Whether System Audio Recording reaches this process now (see `SystemAudioAccess`).
    public static func systemAudioAccess() -> SystemAudioAccess {
        noteLaunchStatus()
        let status = systemAudioPreflight()
        return SystemAudioAccess(status: status, deniedSinceLaunch: SystemAudioGrant.deniedSinceLaunch)
    }

    public static func accessibilityStatus() -> PermissionStatus {
        // Accessibility has no "denied" state of its own: an untrusted app can still be enabled.
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    /// Aggregated over running scriptable browsers: `.notDetermined` if any would prompt, else
    /// `.denied` if any refused, else `.granted`; `.unknown` when none is running. Blocks: call off
    /// the main thread.
    public static func automationStatus(askUserIfNeeded: Bool) -> PermissionStatus {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map { ScriptableBrowsers.family(bundleID: $0) != nil } ?? false
        }
        var statuses: [PermissionStatus] = []
        for app in running {
            let s = automationStatus(pid: app.processIdentifier, askUserIfNeeded: askUserIfNeeded)
            if s != .unknown { statuses.append(s) }
        }
        if statuses.contains(.notDetermined) { return .notDetermined }
        if statuses.contains(.denied) { return .denied }
        if statuses.contains(.granted) { return .granted }
        return .unknown
    }

    /// Automation permission for one running process. Never launches anything.
    public static func automationStatus(pid: pid_t, askUserIfNeeded: Bool) -> PermissionStatus {
        var target = AEAddressDesc()
        var p = pid
        let created = AECreateDesc(DescType(typeKernelProcessID), &p, MemoryLayout<pid_t>.size, &target)
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), askUserIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied                       // -1743
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined     // -1744
        default: return .unknown                                                   // e.g. -600 not running
        }
    }

    // MARK: System Audio request

    private func requestSystemAudio() async -> PermissionStatus {
        let before = Permissions.systemAudioPreflight()
        if before == .granted { return .granted }
        if let request = TCC.request, before == .notDetermined {
            let granted: Bool = await withCheckedContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                request(TCC.audioCaptureService, nil) { granted in
                    let first = once.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(returning: granted) }
                }
            }
            let after = Permissions.systemAudioPreflight()
            if after != .notDetermined { return after == .unknown ? (granted ? .granted : .denied) : after }
        }
        if before == .denied { return .denied }   // macOS won't prompt again; the user must use Settings
        await Permissions.triggerPromptWithThrowawayTap()
        return Permissions.systemAudioPreflight()
    }

    /// Starts a private global tap + aggregate for one second (the prompt appears on AudioDeviceStart).
    static func triggerPromptWithThrowawayTap() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let tap = ProcessTapSource(target: .systemAudio(excluding: HAL.processObject(forPID: getpid())), ringSeconds: 1)
                do {
                    _ = try tap.start()
                    Thread.sleep(forTimeInterval: 1)
                } catch {
                    KanLog.warning("system audio prompt tap failed: \(error)", category: "permissions")
                }
                tap.stop()
                continuation.resume()
            }
        }
    }

    // MARK: Helpers

    private static let axPromptKey = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt

    /// Runs `body` off the main thread (blocking the caller up to `timeout`).
    static func offMain<T: Sendable>(timeout: TimeInterval, fallback: T, _ body: @escaping @Sendable () -> T) -> T {
        guard Thread.isMainThread else { return body() }
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value = body()
            result.withLock { $0 = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return fallback }
        return result.withLock { $0 } ?? fallback
    }
}

/// What this process has seen of its System Audio Recording permission. Every preflight goes
/// through `Permissions.systemAudioPreflight()`, which reports here (the app reads it at launch, on
/// every menu opening and whenever Kan becomes active).
enum SystemAudioGrant {
    /// The status when Kan launched (read when `Permissions` / `LiveRecordingEnvironment` are created).
    static let launchStatus: PermissionStatus = Permissions.systemAudioPreflight()

    private static let denied = OSAllocatedUnfairLock(initialState: false)

    static func observe(_ status: PermissionStatus) {
        if status == .denied { denied.withLock { $0 = true } }
    }

    /// Once denied, a later grant can only have come from System Settings, which applies it after a
    /// relaunch.
    static var deniedSinceLaunch: Bool { denied.withLock { $0 } }
}

/// Private TCC entry points (as used by AudioCap). Loaded lazily; absent on future systems → nil.
enum TCC {
    typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static let preflight: PreflightFn? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFn.self) }

    static let request: RequestFn? = handle.flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFn.self) }

    static func status(_ raw: Int32) -> PermissionStatus {
        switch raw {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }
}
