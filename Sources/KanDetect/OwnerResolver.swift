import AppKit
import Darwin
import Foundation
import KanCore

/// One Core Audio client process (an entry of kAudioHardwarePropertyProcessObjectList).
public struct AudioClient: Sendable, Hashable {
    /// Core Audio process object id — what a process tap needs (not the PID).
    public var processObjectID: UInt32
    public var pid: Int32
    /// kAudioProcessPropertyBundleID; empty for plain executables.
    public var bundleID: String
    /// Executable path (proc_pidpath).
    public var path: String?
    public var isRunning: Bool
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
    public var inputDeviceUIDs: [String]
    public var outputDeviceUIDs: [String]

    public init(processObjectID: UInt32, pid: Int32, bundleID: String, path: String? = nil, isRunning: Bool = false,
                isRunningInput: Bool = false, isRunningOutput: Bool = false,
                inputDeviceUIDs: [String] = [], outputDeviceUIDs: [String] = []) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.path = path
        self.isRunning = isRunning
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUIDs = outputDeviceUIDs
    }

    public var executableName: String? { path.map { ($0 as NSString).lastPathComponent } }
}

/// Why a client is not reported as app activity.
public enum ClientExclusion: String, Sendable {
    case ownProcess         // Kan itself (its mic IOProc and tap aggregate are clients too)
    case systemNoise        // AppCatalog.systemNoiseBundleIDs (Siri, dictation, …) or no bundle id
    case systemDaemon       // other Apple daemons outside any .app
}

/// A client with its owning app.
public struct ResolvedClient: Sendable, Hashable {
    public var client: AudioClient
    public var owner: AppIdentity
    public var category: AppCategory
    public var exclusion: ClientExclusion?
}

/// Maps a Core Audio client to the app that owns it — "Google Chrome Helper" → Google Chrome, Zen's
/// child processes → Zen, com.apple.WebKit.GPU → Safari (or whichever app hosts that WebKit),
/// avconferenced / callservicesd → FaceTime.
///
/// Order: the responsible process (`responsibility_get_pid_responsible_for_pid`, private libsystem
/// call found with dlsym), then the outermost `.app` on that process's executable path, then the
/// client's own path, then the client's Core Audio bundle id.
///
/// Pure given its `Environment`, which tests replace with synthetic lookups. Thread-safe.
public struct OwnerResolver: Sendable {
    public struct BundleInfo: Sendable, Equatable {
        public var bundleID: String
        public var name: String?
        public init(bundleID: String, name: String? = nil) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    public struct RunningApp: Sendable, Equatable {
        public var pid: Int32
        public var bundleID: String?
        public var name: String?
        public var bundlePath: String?
        public init(pid: Int32, bundleID: String?, name: String?, bundlePath: String?) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.bundlePath = bundlePath
        }
    }

    public struct Environment: Sendable {
        public var ownPID: Int32
        public var responsiblePID: @Sendable (Int32) -> Int32?
        public var executablePath: @Sendable (Int32) -> String?
        /// Info.plist of an `.app` at a path.
        public var bundleInfo: @Sendable (String) -> BundleInfo?
        public var runningApp: @Sendable (Int32) -> RunningApp?
        public var runningApps: @Sendable (String) -> [RunningApp]
        public var category: @Sendable (_ bundleID: String, _ appPath: String?) -> AppCategory

        public init(ownPID: Int32, responsiblePID: @escaping @Sendable (Int32) -> Int32?,
                    executablePath: @escaping @Sendable (Int32) -> String?,
                    bundleInfo: @escaping @Sendable (String) -> BundleInfo?,
                    runningApp: @escaping @Sendable (Int32) -> RunningApp?,
                    runningApps: @escaping @Sendable (String) -> [RunningApp],
                    category: @escaping @Sendable (String, String?) -> AppCategory = OwnerResolver.catalogCategory) {
            self.ownPID = ownPID
            self.responsiblePID = responsiblePID
            self.executablePath = executablePath
            self.bundleInfo = bundleInfo
            self.runningApp = runningApp
            self.runningApps = runningApps
            self.category = category
        }

        public static var live: Environment {
            Environment(ownPID: getpid(),
                        responsiblePID: { pid in LiveLookups.responsiblePID(pid) },
                        executablePath: { pid in LiveLookups.executablePath(pid) },
                        bundleInfo: { path in LiveLookups.bundleInfo(path) },
                        runningApp: { pid in LiveLookups.runningApp(pid) },
                        runningApps: { id in LiveLookups.runningApps(id) })
        }
    }

    public static let faceTimeBundleID = "com.apple.FaceTime"
    /// Core Audio bundle ids / executable names of the daemons that carry FaceTime and Continuity
    /// (iPhone) call audio.
    public static let callDaemonBundleIDs: Set<String> = ["com.apple.avconferenced", "com.apple.TelephonyUtilities"]
    public static let callDaemonExecutables: Set<String> = ["avconferenced", "callservicesd"]

    public let environment: Environment

    public init(environment: Environment = .live) {
        self.environment = environment
    }

    public static let catalogCategory: @Sendable (String, String?) -> AppCategory = { bundleID, path in
        AppCatalog.category(bundleID: bundleID, appURL: path.map { URL(fileURLWithPath: $0) })
    }

    public func resolve(_ client: AudioClient) -> ResolvedClient {
        let env = environment
        if client.pid == env.ownPID {
            return ResolvedClient(client: client, owner: kanIdentity(client.pid), category: .ignored, exclusion: .ownProcess)
        }
        if OwnerResolver.isCallDaemon(client) {
            let faceTime = env.runningApps(OwnerResolver.faceTimeBundleID).first
            let owner = AppIdentity(bundleID: OwnerResolver.faceTimeBundleID, name: faceTime?.name ?? "FaceTime",
                                    path: faceTime?.bundlePath, pid: faceTime?.pid ?? client.pid)
            return ResolvedClient(client: client, owner: owner, category: env.category(owner.bundleID, owner.path), exclusion: nil)
        }

        var ownerPID = client.pid
        if let r = env.responsiblePID(client.pid), r > 1 { ownerPID = r }
        if ownerPID == env.ownPID {
            return ResolvedClient(client: client, owner: kanIdentity(ownerPID), category: .ignored, exclusion: .ownProcess)
        }
        let path = ownerPID == client.pid ? client.path ?? env.executablePath(ownerPID) : env.executablePath(ownerPID)
        var owner = identity(pid: ownerPID, executablePath: path)
        if owner == nil, ownerPID != client.pid {
            owner = identity(pid: client.pid, executablePath: client.path ?? env.executablePath(client.pid))
        }
        let resolved = owner ?? AppIdentity(bundleID: client.bundleID,
                                            name: client.executableName ?? (client.bundleID.isEmpty ? "pid \(client.pid)" : client.bundleID),
                                            path: nil, pid: client.pid)

        let exclusion: ClientExclusion?
        if resolved.bundleID == KanPaths.bundleIdentifier || resolved.pid == env.ownPID {
            exclusion = .ownProcess
        } else if OwnerResolver.isNoise(resolved.bundleID, allowEmpty: false) || OwnerResolver.isNoise(client.bundleID, allowEmpty: true) {
            exclusion = .systemNoise
        } else if resolved.path == nil && resolved.bundleID.hasPrefix("com.apple.") {
            exclusion = .systemDaemon
        } else {
            exclusion = nil
        }
        return ResolvedClient(client: client, owner: resolved,
                              category: exclusion == nil ? env.category(resolved.bundleID, resolved.path) : .ignored,
                              exclusion: exclusion)
    }

    /// The outermost `.app` directory on a path ("/Applications/Zen.app/Contents/MacOS/plugin-container.app/…" →
    /// "/Applications/Zen.app").
    public static func outermostAppBundle(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        for (i, component) in components.enumerated() where component.lowercased().hasSuffix(".app") && component.count > 4 {
            return NSString.path(withComponents: Array(components[...i]))
        }
        return nil
    }

    static func isCallDaemon(_ client: AudioClient) -> Bool {
        callDaemonBundleIDs.contains(client.bundleID) || client.executableName.map(callDaemonExecutables.contains) == true
    }

    /// System noise: the catalog's list, also as a prefix ("com.apple.SpeechRecognitionCore.speechrecognitiond").
    /// An empty owner bundle id counts as noise (`allowEmpty: false`), an empty client bundle id doesn't.
    static func isNoise(_ bundleID: String, allowEmpty: Bool) -> Bool {
        if bundleID.isEmpty { return !allowEmpty }
        if AppCatalog.isSystemNoise(bundleID: bundleID) { return true }
        return AppCatalog.systemNoiseBundleIDs.contains { bundleID.hasPrefix($0 + ".") }
    }

    private func identity(pid: Int32, executablePath: String?) -> AppIdentity? {
        let env = environment
        if let exe = executablePath, let appPath = OwnerResolver.outermostAppBundle(in: exe),
           let info = env.bundleInfo(appPath), !info.bundleID.isEmpty {
            let running = env.runningApp(pid)
            let runningName = running?.bundleID == info.bundleID ? running?.name : nil
            let fileName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = OwnerResolver.catalogName(bundleID: info.bundleID) ?? runningName ?? info.name ?? fileName
            return AppIdentity(bundleID: info.bundleID, name: name, path: appPath, pid: pid)
        }
        if let running = env.runningApp(pid), let bundleID = running.bundleID, !bundleID.isEmpty {
            let name = OwnerResolver.catalogName(bundleID: bundleID) ?? running.name ?? bundleID
            return AppIdentity(bundleID: bundleID, name: name, path: running.bundlePath, pid: pid)
        }
        return nil
    }

    /// Kan's name for a cataloged app, which toasts, the menu and saved calls then use: Zoom calls
    /// itself "zoom.us" and the new Teams "Microsoft Teams (work or school)". Exact bundle ids only —
    /// a Chrome web app ("com.google.Chrome.app.…") keeps its own name.
    static func catalogName(bundleID: String) -> String? {
        guard let app = AppCatalog.lookup(bundleID: bundleID),
              app.bundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return nil }
        return app.name
    }

    private func kanIdentity(_ pid: Int32) -> AppIdentity {
        AppIdentity(bundleID: KanPaths.bundleIdentifier, name: "Kan", path: Bundle.main.bundlePath, pid: pid)
    }
}

/// Live process lookups. All are safe to call off the main thread.
enum LiveLookups {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsible: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static var hasResponsibilityAPI: Bool { responsible != nil }

    static func responsiblePID(_ pid: Int32) -> Int32? {
        guard let responsible else { return nil }
        let r = responsible(pid)
        return r > 0 ? r : nil
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    static func bundleInfo(_ appPath: String) -> OwnerResolver.BundleInfo? {
        guard let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        return OwnerResolver.BundleInfo(bundleID: id, name: name)
    }

    static func runningApp(_ pid: Int32) -> OwnerResolver.RunningApp? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return OwnerResolver.RunningApp(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName, bundlePath: app.bundleURL?.path)
    }

    static func runningApps(_ bundleID: String) -> [OwnerResolver.RunningApp] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
            OwnerResolver.RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName,
                                     bundlePath: $0.bundleURL?.path)
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
