import Foundation
import os

/// Logging to the unified log (subsystem com.nahian.Kan) and to ~/Library/Logs/Kan/kan.log.
/// Thread-safe; cheap enough to call from worker queues (never from a real-time audio thread).
///
/// The log outlives deleted calls, so never interpolate call content — transcript text, titles,
/// folder names, people's names, meeting URLs, search queries. Log ids, counts and app names.
/// Debug lines reach the file only in debug builds, with KAN_DEBUG=1, or with the KanDebugLogging
/// default (`defaults write com.nahian.Kan KanDebugLogging -bool true`).
public enum KanLog {
    public enum Level: String, Sendable { case debug, info, warning, error }

    private static let subsystem = KanPaths.bundleIdentifier
    private static let fileQueue = DispatchQueue(label: "com.nahian.Kan.log")
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var fileName = "kan.log"
    private static let maxBytes: UInt64 = 5 * 1024 * 1024
    private static let debugToFile: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["KAN_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "KanDebugLogging")
        #endif
    }()

    /// Call once at startup to pick the log file name ("kan.log" for the app, "kan-cli.log" for the CLI).
    public static func configure(fileName: String) {
        fileQueue.sync {
            self.fileName = fileName
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    public static func debug(_ message: @autoclosure () -> String, category: String = "app") {
        write(.debug, message(), category)
    }

    public static func info(_ message: @autoclosure () -> String, category: String = "app") {
        write(.info, message(), category)
    }

    public static func warning(_ message: @autoclosure () -> String, category: String = "app") {
        write(.warning, message(), category)
    }

    public static func error(_ message: @autoclosure () -> String, category: String = "app") {
        write(.error, message(), category)
    }

    /// An error as the log may describe it. Library errors and Cocoa file errors quote call titles,
    /// folder names and file names (which embed titles), so only their kind and code are logged;
    /// other errors (devices, downloads, models, voices) are described in full.
    public static func describe(_ error: Error) -> String {
        if let error = error as? LibraryError {
            switch error {
            case .notFound(let id): return "call \(id) not found"
            case .invalidFolderName: return "invalid folder name"
            case .io: return "library file error"
            }
        }
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    private static func write(_ level: Level, _ message: String, _ category: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        guard level != .debug || debugToFile else { return }
        let line = "\(timestamp()) [\(level.rawValue.uppercased())] [\(category)] \(message)\n"
        fileQueue.async { append(line) }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func append(_ line: String) {
        let dir = KanPaths.logs
        let url = dir.appendingPathComponent(fileName)
        if fileHandle == nil {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
        guard let handle = fileHandle, let data = line.data(using: .utf8) else { return }
        handle.write(data)
        if let size = try? handle.offset(), size > maxBytes {
            try? handle.close()
            fileHandle = nil
            let old = dir.appendingPathComponent(fileName + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }
}
