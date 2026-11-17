import Foundation
import KanCore

/// Where the library location came from (highest precedence first).
public enum LibraryLocationSource: String, Sendable, Codable {
    /// `--library <path>`
    case argument
    /// The `KAN_LIBRARY` environment variable.
    case environment
    /// `libraryPath` in Kan's settings.json.
    case settings
    /// `KanPaths.defaultLibrary` (~/Documents/Kan).
    case defaultLocation = "default"

    public var displayName: String {
        switch self {
        case .argument: return "--library"
        case .environment: return "KAN_LIBRARY"
        case .settings: return "Kan settings"
        case .defaultLocation: return "default location"
        }
    }
}

public struct LibraryLocation: Sendable, Equatable {
    public var url: URL
    public var source: LibraryLocationSource

    public init(url: URL, source: LibraryLocationSource) {
        self.url = url
        self.source = source
    }

    /// `--library` beats `KAN_LIBRARY`, which beats the app's setting, which beats the default.
    /// `~` is expanded and relative paths are resolved against `currentDirectory`.
    public static func resolve(argument: String?, environment: [String: String], settings: KanSettings,
                               currentDirectory: URL) -> LibraryLocation {
        if let path = argument?.nonEmptyPath {
            return LibraryLocation(url: absoluteURL(path, relativeTo: currentDirectory), source: .argument)
        }
        if let path = environment["KAN_LIBRARY"]?.nonEmptyPath {
            return LibraryLocation(url: absoluteURL(path, relativeTo: currentDirectory), source: .environment)
        }
        if settings.libraryPath.nonEmptyPath != nil {
            return LibraryLocation(url: settings.libraryURL.standardizedFileURL, source: .settings)
        }
        return LibraryLocation(url: KanPaths.defaultLibrary.standardizedFileURL, source: .defaultLocation)
    }

    static func absoluteURL(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL }
        return directory.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }
}

/// Reads Kan's settings without side effects.
///
/// `SettingsStore.load()` moves an unreadable settings.json aside; the CLI and the MCP server are
/// read-only, so they fall back to the defaults and leave the file for the app to deal with.
public enum AgentSettings {
    public struct Loaded: Sendable {
        public var settings: KanSettings
        /// Why the defaults are used although a file exists (unreadable or invalid JSON).
        public var problem: String?
        public var fileExists: Bool
    }

    public static func load(from url: URL = KanPaths.settingsFile) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(settings: KanSettings(), problem: nil, fileExists: false)
        }
        do {
            let data = try Data(contentsOf: url)
            return Loaded(settings: try JSONDecoder.kan.decode(KanSettings.self, from: data), problem: nil, fileExists: true)
        } catch {
            let problem = "Kan's settings (\(url.path)) couldn't be read (\(error.localizedDescription)); using defaults."
            KanLog.warning(problem, category: "agent")
            return Loaded(settings: KanSettings(), problem: problem, fileExists: true)
        }
    }
}

/// The library as the CLI and the MCP server see it: a read-only `LibraryStore` plus where it
/// came from. It never writes to the library.
///
/// Thread-safety: all members may be used from any thread (one lock guards the reload state;
/// `LibraryStore` is thread-safe itself).
public final class AgentLibrary: @unchecked Sendable {
    public let location: LibraryLocation
    public let settings: KanSettings
    /// A problem reading settings.json (the defaults are used).
    public let settingsProblem: String?
    public let settingsFile: URL
    public let store: LibraryStore

    public var root: URL { store.root }

    /// The error of the last (re)load, nil when it succeeded. While set, the store keeps the index
    /// of the last successful load (empty if there was none).
    public var loadError: String? { locked { lastLoadError } }

    /// True when the root folder exists (a missing root is an empty library).
    public var rootExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private let lock = NSLock()
    private var lastLoadError: String?
    private var fingerprint: LibraryFingerprint?
    private var lastCheck: Date?

    public init(location: LibraryLocation, settings: KanSettings, settingsProblem: String? = nil,
                settingsFile: URL = KanPaths.settingsFile) {
        self.location = location
        self.settings = settings
        self.settingsProblem = settingsProblem
        self.settingsFile = settingsFile
        self.store = LibraryStore(root: location.url)
    }

    /// Resolves the location (see `LibraryLocation.resolve`), reading settings.json read-only.
    public static func open(libraryArgument: String?, environment: [String: String], currentDirectory: URL,
                            settingsFile: URL = KanPaths.settingsFile) -> AgentLibrary {
        let loaded = AgentSettings.load(from: settingsFile)
        let location = LibraryLocation.resolve(argument: libraryArgument, environment: environment,
                                               settings: loaded.settings, currentDirectory: currentDirectory)
        let library = AgentLibrary(location: location, settings: loaded.settings, settingsProblem: loaded.problem,
                                   settingsFile: settingsFile)
        library.reload()
        return library
    }

    /// Full rescan. Errors are kept in `loadError` (and logged) instead of thrown: a broken library
    /// still lets the MCP server start and explain the problem.
    public func reload() {
        // Fingerprint first: a change that lands during the scan is noticed by the next check.
        let current = LibraryFingerprint(root: root)
        do {
            try store.reload()
            locked {
                lastLoadError = nil
                fingerprint = current
                lastCheck = Date()
            }
        } catch {
            let message = error.localizedDescription
            KanLog.error("Couldn't load the library at \(root.path): \(message)", category: "agent")
            locked {
                lastLoadError = message
                fingerprint = current
                lastCheck = Date()
            }
        }
    }

    /// Reloads when the library changed on disk, checking at most once per `minimumInterval`.
    /// The check walks the folders and compares names, sizes and modification times of the call
    /// files — no file is read. Returns true if it reloaded.
    @discardableResult
    public func reloadIfChanged(minimumInterval: TimeInterval, now: Date = Date()) -> Bool {
        let due: Bool = locked {
            if let lastCheck, now.timeIntervalSince(lastCheck) < minimumInterval { return false }
            lastCheck = now
            return true
        }
        guard due else { return false }
        let current = LibraryFingerprint(root: root)
        guard locked({ current != fingerprint }) else { return false }
        KanLog.info("Library changed on disk; reloading", category: "agent")
        reload()
        return true
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A cheap summary of the library on disk: every visible folder, plus the name, size and
/// modification time of every `.json` file (what `LibraryStore` scans). Atomic saves (temp file +
/// rename), Finder moves, deletions and in-place edits all change it.
struct LibraryFingerprint: Equatable {
    private let value: Int
    private let fileCount: Int

    static let maxDepth = 24

    init(root: URL) {
        var hasher = Hasher()
        var count = 0
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
            Self.visit(root, relative: "", depth: 0, into: &hasher, count: &count)
        } else {
            hasher.combine("missing")
        }
        value = hasher.finalize()
        fileCount = count
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                 .isPackageKey, .fileSizeKey, .contentModificationDateKey]

    private static func visit(_ directory: URL, relative: String, depth: Int, into hasher: inout Hasher, count: inout Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else {
            hasher.combine("unreadable:" + relative)
            return
        }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            if values.isDirectory == true {
                guard values.isPackage != true, depth + 1 < maxDepth else { continue }
                hasher.combine("dir:" + path)
                visit(item, relative: path, depth: depth + 1, into: &hasher, count: &count)
            } else if values.isRegularFile == true, item.pathExtension.lowercased() == "json" {
                hasher.combine("file:" + path)
                hasher.combine(values.fileSize ?? -1)
                hasher.combine(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
                count += 1
            }
        }
    }
}

extension String {
    /// Trimmed, or nil when empty.
    var nonEmptyPath: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
