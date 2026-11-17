import Foundation

/// Finds every Kan call under the library root. Read-only: it never writes, moves or deletes.
struct LibraryScanner {
    struct Found {
        var record: CallRecord
        var directoryComponents: [String]
        var baseName: String
        var stamp: FileOps.Stamp?

        /// The file is named the way Kan names this record ("<date> <title>", maybe " (n)").
        var hasKanName: Bool {
            LibraryNaming.collisionNumber(of: baseName, base: LibraryNaming.baseName(for: record)) != nil
        }

        /// The file is in the folder its JSON names (Kan writes `folder` into every record), so it
        /// isn't a copy put into another folder.
        var isInRecordedFolder: Bool {
            let here = LibraryNaming.folder(forDirectoryComponents: directoryComponents)
            let recorded = LibraryNaming.sanitizeFolder(record.folder) ?? record.folder.nfc
            return here.caseInsensitiveCompare(recorded) == .orderedSame
        }

        /// Which of two files holding the same call is the call: the newer `updatedAt`, then the
        /// one where and as Kan saved it — a Finder duplicate "… copy", a sync conflict "… 2" or a
        /// copy in another folder loses to the original (although " copy" sorts first) — then the
        /// one found first.
        func isPreferred(over other: Found) -> Bool {
            if record.updatedAt != other.record.updatedAt { return record.updatedAt > other.record.updatedAt }
            return placement > other.placement
        }

        private var placement: Int { (hasKanName ? 1 : 0) + (isInRecordedFolder ? 1 : 0) }
    }

    struct Result {
        var calls: [Found] = []
        /// Every non-hidden directory, as folder names ("" excluded).
        var folders: Set<String> = []
        var skipped = 0
    }

    /// Call JSONs larger than this are skipped (a stray dataset in the library is not a call).
    static let maxFileSize = 64 * 1024 * 1024
    static let maxDepth = 24

    let root: URL

    func scan() throws -> Result {
        var result = Result()
        var info = stat()
        if stat(root.path, &info) != 0 {
            // Missing: an empty library (Kan creates it with the first call). Denied — an agent
            // host or a terminal without access to ~/Documents — must not look like "no calls".
            let code = errno
            guard code == EACCES || code == EPERM else { return result }
            throw LibraryError.io(Self.accessDenied(root, errno: code))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.io("The library location \(root.path) is not a folder.")
        }
        var candidates: [Candidate] = []
        try visit(root, components: [], depth: 0, into: &result, candidates: &candidates)

        // Decoding dominates a reload (≈ 25 MB/s per core), so decode files in parallel.
        var loaded = [Loaded](repeating: .notACall, count: candidates.count)
        loaded.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                slots[i] = load(candidates[i].url, components: candidates[i].components)
            }
        }
        for item in loaded {
            switch item {
            case .call(let found): result.calls.append(found)
            case .notACall: break
            case .problem: result.skipped += 1
            }
        }
        return result
    }

    private struct Candidate {
        let url: URL
        let components: [String]
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                 .isPackageKey, .fileSizeKey]

    private func visit(_ directory: URL, components: [String], depth: Int, into result: inout Result,
                       candidates: inout [Candidate]) throws {
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Self.keys,
                                                                options: [.skipsHiddenFiles])
        } catch {
            if components.isEmpty {
                if let code = Self.posixCode(of: error), code == EACCES || code == EPERM {
                    throw LibraryError.io(Self.accessDenied(root, errno: code))
                }
                throw LibraryError.io("Can't read the library folder: \(error.localizedDescription)")
            }
            // How deep, not its name (the user's folder names outlive the folders in the log).
            KanLog.warning("Skipping an unreadable folder \(components.count) level(s) down: \(KanLog.describe(error))",
                           category: "library")
            return
        }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let values = try? item.resourceValues(forKeys: Set(Self.keys)) else { continue }
            if values.isSymbolicLink == true { continue }       // never follow links out of the library
            if values.isDirectory == true {
                if values.isPackage == true { continue }
                guard depth + 1 < Self.maxDepth else { continue }
                let sub = components + [name]
                let folder = LibraryNaming.folder(forDirectoryComponents: sub)
                if !folder.isEmpty { result.folders.insert(folder) }
                try visit(item, components: sub, depth: depth + 1, into: &result, candidates: &candidates)
                continue
            }
            guard values.isRegularFile == true,
                  item.pathExtension.lowercased() == LibraryNaming.jsonExtension,
                  !LibraryNaming.isReservedRootFile(name) else { continue }
            if let size = values.fileSize, size > Self.maxFileSize {
                KanLog.warning("Skipping a .json file \(position(components)): \(size) bytes is too large for a call record",
                               category: "library")
                result.skipped += 1
                continue
            }
            candidates.append(Candidate(url: item, components: components))
        }
    }

    private enum Loaded {
        case call(Found)
        case notACall
        case problem
    }

    private func load(_ url: URL, components: [String]) -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            KanLog.warning("Skipping an unreadable .json file \(position(components)): \(KanLog.describe(error))",
                           category: "library")
            return .problem
        }
        do {
            let record = try JSONDecoder.kan.decode(CallRecord.self, from: data)
            guard record.kind == "kan.call" else { return .notACall }
            if record.schema > CallRecord.currentSchema {
                KanLog.info("Call \(record.id) uses newer schema \(record.schema)", category: "library")
            }
            return .call(Found(record: record, directoryComponents: components,
                               baseName: url.deletingPathExtension().lastPathComponent, stamp: FileOps.stamp(url)))
        } catch {
            // Only complain about files that claim to be Kan calls; other JSON is none of our business.
            if let probe = try? JSONDecoder().decode(KindProbe.self, from: data), probe.kind == "kan.call" {
                // A decoding error names keys and types, not values.
                let id = probe.id.flatMap { CallID(parsing: $0) }.map { " (call \($0))" } ?? ""
                KanLog.error("Skipping a corrupt call record\(id) \(position(components)): \(error)", category: "library")
                return .problem
            }
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                KanLog.warning("Skipping a .json file \(position(components)): not valid JSON", category: "library")
                return .problem
            }
            return .notACall
        }
    }

    private struct KindProbe: Decodable {
        let kind: String?
        /// For the log only; an id of the wrong type mustn't hide that the record is corrupt.
        let id: String?

        private enum CodingKeys: String, CodingKey { case kind, id }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
        }
    }

    /// The library root can't be read because macOS (privacy protection of Documents, Desktop and
    /// Downloads) or the file permissions refuse it.
    static func accessDenied(_ root: URL, errno code: Int32) -> String {
        "Access to the library folder \(root.path) was denied (\(String(cString: strerror(code)))). If it is in "
            + "Documents, Desktop or Downloads, allow the app reading it — Kan, or the terminal or AI app that runs "
            + "kan — under System Settings › Privacy & Security › Files & Folders, or move the library."
    }

    /// True when the folder can't be looked at or into because macOS or the file permissions
    /// refuse it (EACCES / EPERM), as opposed to it not existing.
    static func isAccessDenied(at url: URL) -> Bool {
        var info = stat()
        if stat(url.path, &info) != 0 {
            let code = errno
            return code == EACCES || code == EPERM
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard let directory = opendir(url.path) else {
            let code = errno
            return code == EACCES || code == EPERM
        }
        closedir(directory)
        return false
    }

    /// The POSIX error code behind a Foundation file error.
    private static func posixCode(of error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }

    /// Where a file is, for the log. Not its path: file names are call titles and folder names are
    /// the user's, and the log outlives both.
    private func position(_ components: [String]) -> String {
        if components.isEmpty { return "at the top of the library" }
        if components == [LibraryNaming.inboxDirectory] { return "in the Inbox" }
        return "in a folder \(components.count) level(s) down"
    }
}
