import Foundation

public enum PermissionKind: String, CaseIterable, Sendable {
    /// Record the user's voice.
    case microphone
    /// "System Audio Recording Only" — needed for Core Audio process taps (the other side of the call).
    case systemAudio
    /// Optional: read browser window titles (any browser) to name Meet/Teams/Zoom-web calls.
    case accessibility
    /// Optional: ask Chrome-family browsers / Safari for the meeting tab's URL (AppleScript).
    case automation
    /// Optional: suggest titles and attendees from the user's calendar.
    case calendar

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio Recording"
        case .accessibility: return "Accessibility"
        case .automation: return "Automation (browsers)"
        case .calendar: return "Calendar"
        }
    }

    public var isRequired: Bool { self == .microphone || self == .systemAudio }
}

public enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined, unknown
}

/// Implemented by `KanAudio.Permissions` (calendar is handled by the app with EventKit).
public protocol PermissionsProviding: AnyObject, Sendable {
    func status(_ kind: PermissionKind) -> PermissionStatus
    /// Shows the system prompt when possible. For `.systemAudio` the prompt appears when the first
    /// tap starts, and macOS may require relaunching Kan after a change in System Settings.
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(_ kind: PermissionKind)
    /// Granted, but the grant reaches Kan only after a relaunch (System Audio Recording turned on in
    /// System Settings while Kan runs). Optional; false by default.
    func needsRelaunch(_ kind: PermissionKind) -> Bool
}

extension PermissionsProviding {
    public func needsRelaunch(_ kind: PermissionKind) -> Bool { false }
}
