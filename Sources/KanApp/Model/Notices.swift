import Foundation
import KanCore

/// A floating toast or prompt (shown top-right by `ToastPresenter`). Notices are plain state on
/// `AppModel` so the flows can be exercised headlessly; buttons send `NoticeCommand`s back through
/// `AppModel.perform(_:on:)`.
struct AppNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// "Recording Zoom call" (auto-hides).
        case recordingStarted(CallID)
        /// "Record this call?" for a tentative recording.
        case ask(CallID)
        /// A tentative call ended before the user answered: keep or discard the audio.
        case keepUnconfirmed(CallID)
        /// "Call ended · saving in 12 s".
        case ending(CallID, deadline: Date)
        /// "Still in a call?".
        case stale(CallID)
        /// A recording issue or another failure the user should act on.
        case problem(String)
        /// Informational (recovered recordings, bookmarks, saved calls, downloads).
        case info(String)
    }

    enum Style: Equatable {
        case recording, question, warning, info
    }

    struct Button: Identifiable, Equatable {
        enum Role: Equatable { case primary, normal, destructive }
        var id: String { "\(title)#\(command)" }
        var title: String
        var command: NoticeCommand
        var role: Role = .normal
    }

    let id: UUID
    var kind: Kind
    var style: Style
    var title: String
    var message: String?
    var buttons: [Button]
    /// Seconds until it hides by itself; nil = stays until answered or closed.
    var autoHideAfter: TimeInterval?
    /// Whether the close (×) button is offered.
    var isDismissible: Bool
    var createdAt: Date

    init(kind: Kind, style: Style, title: String, message: String? = nil, buttons: [Button] = [],
         autoHideAfter: TimeInterval? = nil, isDismissible: Bool = true, createdAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.style = style
        self.title = title
        self.message = message
        self.buttons = buttons
        self.autoHideAfter = autoHideAfter
        self.isDismissible = isDismissible
        self.createdAt = createdAt
    }

    /// The call a notice is about, if any.
    var callID: CallID? {
        switch kind {
        case .recordingStarted(let id), .ask(let id), .keepUnconfirmed(let id), .ending(let id, _), .stale(let id):
            return id
        case .problem, .info:
            return nil
        }
    }

    /// Notices that describe the live recording (removed when it stops).
    var isAboutLiveCall: Bool {
        switch kind {
        case .recordingStarted, .ask, .ending, .stale: return true
        case .keepUnconfirmed, .problem, .info: return false
        }
    }
}

/// What a notice button does.
enum NoticeCommand: Equatable {
    case record                 // answer "Record this call?"
    case notNow
    case never                  // "Never for <App>" (ask) / "Never record <App>" (start toast)
    case keepRecording          // "Call ended?" / "Still in a call?"
    case stopAndSave
    case discardRecording       // "Don't record" on the start toast
    case pauseRecording
    case keepUnconfirmed(CallID)
    case discardUnconfirmed(CallID)
    case neverUnconfirmed(CallID)
    case openSystemSettings(PermissionKind)
    /// Privacy & Security › Files & Folders (the library folder's Documents access).
    case openFilesAndFoldersSettings
    case relaunch
    case label(CallID)
    case showInLibrary(CallID)
    case openLibrary
    case openSettings
    case dismiss
}
