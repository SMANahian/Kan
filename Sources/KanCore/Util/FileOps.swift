import Foundation

/// File-system helpers that are safe on case-insensitive, normalization-insensitive APFS volumes,
/// where "Zoom call.md" and "zoom Call.md" are the same file.
enum FileOps {
    /// Device + inode, the identity of a file regardless of how its name is spelled.
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
    }

    /// Modification time + size, used to validate cached decodes.
    struct Stamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
        let size: Int64

        /// True if this file was modified before `other` (sizes are ignored).
        func isOlder(than other: Stamp) -> Bool {
            (seconds, nanoseconds) < (other.seconds, other.nanoseconds)
        }
    }

    static func identity(_ url: URL) -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: UInt64(info.st_ino))
    }

    static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec),
                     size: Int64(info.st_size))
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The first `maxBytes` bytes of a file (all of a shorter one), or nil when it can't be read.
    static func head(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    /// True if both paths exist and name the same file.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ia = identity(a), let ib = identity(b) else { return false }
        return ia == ib
    }

    /// Writes via a temporary file + rename, so readers never see a partial file.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    /// Writes `data` to `url`, which replaces `previous` (the same document under its old name).
    /// The old file is removed only after the new one is safely written, and never when both names
    /// resolve to the same file (a case-only rename is applied with rename(2) instead).
    static func replace(_ previous: URL?, with data: Data, at url: URL) throws {
        if let previous, previous.path != url.path, isSameFile(previous, url) {
            // Only the spelling changed (case or Unicode normalization): rename in place first.
            if rename(previous.path, url.path) != 0 {
                let code = errno
                // Not the names: a call file's name is its title.
                KanLog.warning("Renaming a .\(url.pathExtension) file to its new spelling failed (errno \(code))", category: "library")
            }
        }
        try writeAtomically(data, to: url)
    }

    /// Removes `previous` unless it's the same file as `current` (or already gone).
    static func removeStale(_ previous: URL?, keeping current: URL) {
        guard let previous, previous.path != current.path, exists(previous) else { return }
        guard !isSameFile(previous, current) else { return }
        do {
            try FileManager.default.removeItem(at: previous)
        } catch {
            KanLog.error("Could not remove an old .\(previous.pathExtension) file: \(KanLog.describe(error))", category: "library")
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Owner-only permissions (voiceprints are biometric data about other people).
    static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves a corrupt file aside ("<name>.corrupt-<unix time>.<ext>") so it is kept for inspection.
    @discardableResult
    static func moveAside(_ url: URL) -> URL? {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = "\(stem).corrupt-\(Int(Date().timeIntervalSince1970))" + (ext.isEmpty ? "" : ".\(ext)")
        let aside = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            return nil
        }
    }
}
