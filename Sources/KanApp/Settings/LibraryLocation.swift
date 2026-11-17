import Foundation
import KanCore

/// Choosing the library folder (Settings › General). Kan fills its library folder with its own
/// tree — Inbox, the call folders, and index.md, index.jsonl and AGENTS.md at the top — so a folder
/// that already holds other files (an Obsidian vault, ~/Documents) is never adopted as it is: Kan
/// offers a "Kan" folder inside it instead.
enum LibraryLocation {
    enum Contents: Equatable {
        /// Missing, or holding nothing but Finder's bookkeeping (.DS_Store, .localized).
        case empty
        /// A Kan library already: Kan wrote its AGENTS.md, index.md or index.jsonl.
        case kanLibrary
        /// Anything else: notes, a vault's .obsidian folder, a file, an unreadable folder.
        case other
    }

    private static let finderFiles: Set<String> = [".DS_Store", ".localized"]

    static func contents(of folder: URL) -> Contents {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .empty }
        guard isDirectory.boolValue, let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return .other }
        if isKanLibrary(folder) { return .kanLibrary }
        return names.allSatisfy(finderFiles.contains) ? .empty : .other
    }

    /// The folder Kan offers inside `folder`: "Kan", else "Kan 2", "Kan 3"… — the first that is
    /// missing, empty or a Kan library already.
    static func suggestedSubfolder(in folder: URL) -> URL {
        for n in 1...50 {
            let candidate = folder.appendingPathComponent(n == 1 ? "Kan" : "Kan \(n)", isDirectory: true)
            if contents(of: candidate) != .other { return candidate }
        }
        return folder.appendingPathComponent("Kan \(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// The marks Kan leaves at the top of its library: AGENTS.md with Kan's version marker,
    /// index.md starting with Kan's marker (older versions: its "# Kan call library" heading), or
    /// index.jsonl whose first line is a call summary — what KanCore checks (`LibraryIndexFiles`)
    /// before it rewrites those files.
    static func isKanLibrary(_ folder: URL) -> Bool {
        if let agents = head(of: folder.appendingPathComponent("AGENTS.md")),
           AgentsGuide.embeddedVersion(in: agents) != nil {
            return true
        }
        if let index = head(of: folder.appendingPathComponent("index.md")),
           index.hasPrefix("<!-- kan-index") || index.hasPrefix("# Kan call library\n") {
            return true
        }
        if let jsonl = head(of: folder.appendingPathComponent("index.jsonl")) {
            let firstLine = jsonl.prefix { $0 != "\n" }
            if firstLine.hasPrefix("{"),
               ["\"id\":\"", "\"jsonPath\":\"", "\"markdownPath\":\""].allSatisfy({ firstLine.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// The first 64 KB of a file as text, or nil when it can't be read.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
