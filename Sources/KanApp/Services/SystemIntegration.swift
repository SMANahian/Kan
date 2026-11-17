import AppKit
import Carbon.HIToolbox
import CoreServices
import Foundation
import KanCore
import ServiceManagement

// MARK: - Launch at login

/// `SMAppService.mainApp`. Registration is only ever changed from an explicit user action.
@MainActor
final class LoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return .unavailable("Kan isn't running from an app bundle.")
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if case .unavailable(let reason) = status { throw LoginItemError(message: reason) }
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct LoginItemError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - Global hot keys

/// ⌃⌥⌘B / ⌃⌥⌘L / ⌃⌥⌘R with Carbon `RegisterEventHotKey` (no Accessibility permission needed).
/// Main-thread only (Carbon delivers hot-key events on the main event loop).
@MainActor
final class GlobalHotkeys: HotkeyRegistering {
    private var registered: [GlobalHotkey: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var callback: (@MainActor (GlobalHotkey) -> Void)?
    private static let signature: OSType = "KanH".utf8.reduce(0) { $0 << 8 | OSType($1) }

    @discardableResult
    func setEnabled(_ enabled: Bool, handler: @escaping @MainActor (GlobalHotkey) -> Void) -> [GlobalHotkey] {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        guard enabled else {
            callback = nil
            return []
        }
        callback = handler
        guard installHandler() else { return GlobalHotkey.allCases }
        var failed: [GlobalHotkey] = []
        for (index, key) in GlobalHotkey.allCases.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(Self.keyCode(key), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[key] = ref
            } else {
                failed.append(key)
            }
        }
        KanLog.info("Global hot keys registered: \(registered.keys.map(\.displayName).sorted().joined(separator: " "))",
                    category: "hotkeys")
        return failed
    }

    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private static func keyCode(_ key: GlobalHotkey) -> UInt32 {
        switch key {
        case .addBookmark: return UInt32(kVK_ANSI_B)
        case .openLibrary: return UInt32(kVK_ANSI_L)
        case .toggleRecording: return UInt32(kVK_ANSI_R)
        }
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let owner = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { owner.fire(hotKeyID) }
            return noErr
        }, 1, &spec, context, &handlerRef)
        if status != noErr {
            KanLog.error("InstallEventHandler failed (\(status))", category: "hotkeys")
            return false
        }
        return true
    }

    private func fire(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        let index = Int(id.id) - 1
        guard GlobalHotkey.allCases.indices.contains(index) else { return }
        callback?(GlobalHotkey.allCases[index])
    }
}

// MARK: - The kan command

enum CommandLineInstallResult: Equatable {
    /// `onPath`: whether the user's shell finds commands in the link's directory (nil = unknown).
    case installed(link: URL, onPath: Bool?)
    case failed(String)
}

/// Links ~/.local/bin/kan to the CLI inside Kan.app. Never replaces a file that isn't a link.
enum CommandLineInstaller {
    static var linkDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var linkURL: URL { linkDirectory.appendingPathComponent("kan") }

    static func install(source: URL) -> CommandLineInstallResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: source.path) else {
            return .failed("This copy of Kan has no kan command (\(source.path)). Build it with “make app”.")
        }
        do {
            try fm.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        } catch {
            return .failed("Couldn't create \(linkDirectory.path): \(error.localizedDescription)")
        }
        let link = linkURL
        if let attributes = try? fm.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                return .failed("\(link.path) already exists and isn't a link to Kan. Remove it first.")
            }
            do {
                try fm.removeItem(at: link)
            } catch {
                return .failed("Couldn't replace \(link.path): \(error.localizedDescription)")
            }
        }
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            return .failed("Couldn't create \(link.path): \(error.localizedDescription)")
        }
        return .installed(link: link, onPath: isOnUserPATH(linkDirectory))
    }

    /// Apps don't inherit the shell's PATH: ask the login shell, then look at the shell rc files.
    static func isOnUserPATH(_ directory: URL) -> Bool? {
        let target = directory.standardizedFileURL.path
        if let path = loginShellPATH() {
            let entries = path.split(separator: ":").map { (String($0) as NSString).expandingTildeInPath }
            if entries.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == target }) { return true }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rc in [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish"] {
            if let text = try? String(contentsOf: home.appendingPathComponent(rc), encoding: .utf8), text.contains(".local/bin") {
                return true
            }
        }
        return loginShellPATH() == nil ? nil : false
    }

    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

// MARK: - Library watcher

/// Notices files changed in the library by other programs (an editor, an AI agent) and asks for a
/// reconcile, debounced. Kan's own writes are ignored (kFSEventStreamCreateFlagIgnoreSelf).
/// Main-thread only (the stream delivers on the main queue).
@MainActor
final class LibraryWatcher {
    private let root: URL
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    static let debounceSeconds: Double = 2

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    /// Creates the library folder if it's missing, then watches it. Returns why the folder couldn't
    /// be created (macOS denied access to Documents, …); calling it again retries.
    @discardableResult
    func start() -> Error? {
        guard stream == nil else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            KanLog.warning("Not watching the library (\(KanLog.describe(error)))", category: "library")
            return error
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handle(Array(list.prefix(count))) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            KanLog.warning("Couldn't watch the library folder", category: "library")
            return nil
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
        return nil
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.contains { path in
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return (ext == "json" || ext == "md") && name != "index.md" && name != "AGENTS.md"
        }
        guard relevant else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            KanLog.info("Library files changed outside Kan; reconciling", category: "library")
            self.onChange()
        }
    }
}
