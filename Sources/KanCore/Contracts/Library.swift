import Foundation

// CONTRACT (implemented by the KanCore agent — keep these signatures; additions are fine).
//
// On-disk layout under the library root (default ~/Documents/Kan):
//   AGENTS.md                         how the library is organized, for AI agents (regenerated when outdated)
//   index.md                          table of every call, newest first (regenerated on change)
//   index.jsonl                       one CallSummary JSON object per line (regenerated on change)
//   Inbox/2026-11-16 1530 Zoom call.md        rendered transcript (YAML front matter + Markdown)
//   Inbox/2026-11-16 1530 Zoom call.json      the CallRecord (source of truth)
//   Research/Thesis/2026-11-14 1000 Advisor meeting.{md,json}
//
// Rules:
//  - folder "" is the Inbox and lives in the "Inbox" directory. Nested folders use "/".
//    Folder names are sanitized (no "..", no ":", no leading dots, trimmed, no empty components).
//  - The base file name is "<yyyy-MM-dd HHmm> <sanitized title>" in the call's own time zone,
//    truncated to ~90 characters; collisions get " (2)", " (3)"… Saving a record whose folder/title
//    changed moves/renames both files (never leaves stale copies).
//  - Writes are atomic (write temp + rename). The .json is written before the .md.
//  - The store identifies calls by `CallID` found inside the JSON ("kind": "kan.call"); files are
//    found by scanning the root (skip hidden dirs and anything that isn't a Kan call JSON). An id
//    that isn't a ULID makes the file unreadable as a call (it names the call's data directory).
//  - Two files holding one id (a Finder duplicate, a sync conflict, a copy in another folder): the
//    newer `updatedAt` is the call, then the file named and placed as Kan saved it. Deleting the
//    call removes every copy; saving it removes older copies Kan itself left next to it.
//  - A call whose files were moved or renamed outside Kan is found again (rescan) before an
//    update, read or delete reports it gone; a delete never removes a file holding another call.
//  - index.md / index.jsonl, like AGENTS.md, are only (re)written when missing or written by Kan:
//    a folder's own index.md (an Obsidian vault's home note) is never overwritten.
//  - All methods are thread-safe (internal lock); `onChange` fires after the lock is released.
//  - Unknown JSON keys must be preserved? No — the CallRecord is the full schema; just decode it.

public struct CallFiles: Sendable, Hashable {
    public var markdown: URL
    public var json: URL

    public init(markdown: URL, json: URL) {
        self.markdown = markdown
        self.json = json
    }
}

public struct FolderInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// "" = Inbox.
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct NamedCount: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum LibraryChange: Sendable, Equatable {
    case saved(CallID)
    case deleted(CallID)
    case reloaded
}

public struct SearchQuery: Sendable, Equatable {
    /// Free text. Whitespace-separated terms are ANDed; "quoted phrases" match exactly.
    /// Matching is case-insensitive on NFC text, WITHOUT diacritic folding (Bangla vowel signs are
    /// letters, not diacritics: "জনি" must not match "জন্য").
    public var text: String
    public var folder: String?
    public var tag: String?
    public var person: String?
    public var appName: String?
    public var from: Date?
    public var to: Date?
    public var starredOnly: Bool
    public var limit: Int

    public init(text: String = "", folder: String? = nil, tag: String? = nil, person: String? = nil,
                appName: String? = nil, from: Date? = nil, to: Date? = nil, starredOnly: Bool = false,
                limit: Int = 200) {
        self.text = text
        self.folder = folder
        self.tag = tag
        self.person = person
        self.appName = appName
        self.from = from
        self.to = to
        self.starredOnly = starredOnly
        self.limit = limit
    }
}

public enum SearchField: String, Sendable, Codable {
    case title, notes, tags, transcript, bookmark
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(callID.rawValue)#\(field.rawValue)#\(segmentID ?? -1)" }
    public var callID: CallID
    public var title: String
    public var startedAt: Date
    public var field: SearchField
    /// Transcript hits: the segment and its start time (seconds from call start).
    public var segmentID: Int?
    public var time: Double?
    public var speakerName: String?
    /// ~200 characters around the first match.
    public var snippet: String
    /// The matched terms (for highlighting in the UI).
    public var terms: [String]
    public var score: Double

    public init(callID: CallID, title: String, startedAt: Date, field: SearchField, segmentID: Int? = nil,
                time: Double? = nil, speakerName: String? = nil, snippet: String, terms: [String], score: Double) {
        self.callID = callID
        self.title = title
        self.startedAt = startedAt
        self.field = field
        self.segmentID = segmentID
        self.time = time
        self.speakerName = speakerName
        self.snippet = snippet
        self.terms = terms
        self.score = score
    }
}

public enum LibraryError: Error, LocalizedError, Sendable {
    case notFound(CallID)
    case invalidFolderName(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Call \(id) not found in the library."
        case .invalidFolderName(let n): return "Invalid folder name: \(n)"
        case .io(let m): return m
        }
    }
}

/// The transcript library on disk. Source of truth for the app, the CLI and the MCP server.
///
/// Thread-safety: every method may be called from any thread. State is guarded by one recursive
/// lock (so an `update` closure may read the store), file writes happen under it, and searches run
/// on a snapshot outside it. `onChange` fires on the caller's thread after the lock is released.
///
/// Memory: the index keeps one `CallSummary` and the searchable text of each call (about the size
/// of the transcript text); full records are read from disk on demand (a small cache keeps the
/// most recently used ones, validated against the file's modification time).
///
/// Read-only use (CLI, MCP server): `reload`, `summaries`, `record`, `search`… never write.
/// The first call to any method loads the library if `reload()` hasn't been called yet.
public final class LibraryStore: @unchecked Sendable {
    public let root: URL

    /// Called after every successful mutation (on the caller's thread, outside the lock).
    /// Folder operations (create, rename, delete) report `.reloaded`.
    public var onChange: (@Sendable (LibraryChange) -> Void)? {
        get { locked { changeHandler } }
        set { locked { changeHandler = newValue } }
    }

    // MARK: State (guarded by `lock`)

    private let lock = NSRecursiveLock()
    private let callDataDirectoryResolver: @Sendable (CallID) -> URL
    private var changeHandler: (@Sendable (LibraryChange) -> Void)?
    private var loaded = false
    private var entries: [CallID: LibraryEntry] = [:]
    private var sortedIDs: [CallID]?
    /// Every folder that exists as a directory (or holds a call); "" (Inbox) is implicit.
    private var folderSet: Set<String> = []
    private var recordCache: [CallID: CachedRecord] = [:]
    private var recordCacheOrder: [CallID] = []
    private var lastIndexMarkdown: Data?
    private var lastIndexJSONL: Data?
    private var batchDepth = 0
    private var indexWritePending = false
    /// The JSON stamp each call's .md was last rendered from (or found up to date with) by this
    /// store. Kept apart from `LibraryEntry.stamp`, which reading a record refreshes.
    private var renderedStamps: [CallID: FileOps.Stamp] = [:]
    /// Other files holding an indexed call's id (see `LibraryTwin`).
    private var twins: [CallID: [LibraryTwin]] = [:]
    /// Nesting of `locked`, so a public call rescans for moved files at most once.
    private var lockDepth = 0
    private var relocationScanned = false
    /// Index files at the root that Kan didn't write and leaves alone (logged once each).
    private var foreignIndexFiles: Set<String> = []

    private struct CachedRecord {
        var record: CallRecord
        var stamp: FileOps.Stamp
    }

    private static let recordCacheCapacity = 16

    /// - Parameter callDataDirectory: where a call's audio and working files live (deleted with
    ///   `delete(_:deleteAudio: true)`); injectable for tests.
    public init(root: URL,
                callDataDirectory: @escaping @Sendable (CallID) -> URL = { KanPaths.callDataDirectory(for: $0) }) {
        self.root = root.standardizedFileURL
        self.callDataDirectoryResolver = callDataDirectory
    }

    // MARK: Loading

    /// Full rescan of the root; rebuilds the in-memory index. Returns summaries, newest first.
    @discardableResult
    public func reload() throws -> [CallSummary] {
        let summaries: [CallSummary] = try locked {
            try reloadLocked()
            return sortedSummariesLocked()
        }
        notify(.reloaded)
        return summaries
    }

    /// For the app (it writes; the CLI and MCP server use `reload()`): rescans like `reload()`, then
    /// re-renders the Markdown of every call whose JSON changed outside Kan (an agent or editor
    /// edited it, also while Kan wasn't running) or whose `.md` is missing, and refreshes the index
    /// files. Files are never moved or renamed here. Returns the calls whose Markdown was rewritten.
    /// Call it when the library window opens or after file-system events.
    ///
    /// A `.md` is stale when its JSON changed since this store rendered it, or — for calls it hasn't
    /// rendered yet (e.g. at launch) — when it is older than its JSON: Kan writes the JSON first.
    @discardableResult
    public func reconcile() throws -> [CallID] {
        let rewritten: [CallID] = try locked {
            try reloadLocked()
            var ids: [CallID] = []
            for id in Array(entries.keys) {
                guard let entry = entries[id] else { continue }
                if let markdownStamp = FileOps.stamp(entry.files.markdown) {
                    guard let jsonStamp = entry.stamp else { continue }
                    if let rendered = renderedStamps[id] {
                        if rendered == jsonStamp { continue }
                    } else if !markdownStamp.isOlder(than: jsonStamp) {
                        renderedStamps[id] = jsonStamp
                        continue
                    }
                }
                do {
                    let record = try recordLocked(id)
                    let files = entries[id]?.files ?? entry.files
                    let markdown = Data(TranscriptRenderer.markdown(record).utf8)
                    if FileManager.default.contents(atPath: files.markdown.path) != markdown {
                        try FileOps.writeAtomically(markdown, to: files.markdown)
                        ids.append(id)
                    }
                    renderedStamps[id] = entries[id]?.stamp
                } catch {
                    KanLog.error("Couldn't re-render the Markdown of \(id): \(KanLog.describe(error))", category: "library")
                }
            }
            writeIndexesLoggingLocked()
            if !ids.isEmpty { KanLog.info("Re-rendered \(ids.count) transcript(s) edited outside Kan", category: "library") }
            return ids
        }
        notify(.reloaded)
        return rewritten
    }

    /// Cached summaries, newest first (call `reload()` once at startup).
    public func summaries() -> [CallSummary] {
        locked {
            ensureLoadedLocked()
            return sortedSummariesLocked()
        }
    }

    /// The summary of one call, if it's in the library.
    public func summary(_ id: CallID) -> CallSummary? {
        locked {
            ensureLoadedLocked()
            return entries[id]?.summary
        }
    }

    /// The full record, read from its JSON file. Its `folder` reflects where the files are (moving
    /// files in Finder moves the call).
    public func record(_ id: CallID) throws -> CallRecord {
        try locked {
            ensureLoadedLocked()
            return try recordLocked(id)
        }
    }

    public func contains(_ id: CallID) -> Bool {
        locked {
            ensureLoadedLocked()
            return entries[id] != nil
        }
    }

    public func files(for id: CallID) -> CallFiles? {
        locked {
            ensureLoadedLocked()
            return entries[id]?.files
        }
    }

    /// Where the call's audio, embeddings and working files live.
    public func callDataDirectory(for id: CallID) -> URL {
        callDataDirectoryResolver(id)
    }

    /// True when macOS (the privacy protection of Documents, Desktop and Downloads) or the file
    /// permissions keep this process from looking into the library folder — as opposed to the
    /// folder not existing yet. `reload()` then throws instead of finding no calls.
    public var isRootAccessDenied: Bool {
        LibraryScanner.isAccessDenied(at: root)
    }

    // MARK: Saving

    /// Insert or replace. Sets `updatedAt`, (re)renders the Markdown, moves files when the folder or
    /// title changed, regenerates index.md / index.jsonl.
    ///
    /// This replaces the whole record: to edit an existing call use `update(_:_:)`, which can't
    /// lose changes made concurrently (e.g. a transcript arriving from the processing queue).
    ///
    /// Text is stored NFC; tags are trimmed, de-duplicated and lose a leading "#"; an empty title
    /// becomes the suggested title. Throws `LibraryError.invalidFolderName` for folders like "..".
    @discardableResult
    public func save(_ record: CallRecord) throws -> CallFiles {
        let files: CallFiles = try locked {
            ensureLoadedLocked()
            return try saveLocked(record).entry.files
        }
        notify(.saved(record.id))
        return files
    }

    /// Atomic read-modify-write under the store lock (use this from the processing queue and the UI
    /// so concurrent edits never overwrite each other). The closure must not change `id`.
    @discardableResult
    public func update(_ id: CallID, _ mutate: (inout CallRecord) throws -> Void) throws -> CallRecord {
        let saved: CallRecord = try locked {
            ensureLoadedLocked()
            var record = try recordLocked(id)
            try mutate(&record)
            guard record.id == id else { throw LibraryError.io("A call's id can't be changed (\(id)).") }
            return try saveLocked(record).record
        }
        notify(.saved(id))
        return saved
    }

    /// Deletes the .md and .json, and any other copy of the call in the library (a Finder
    /// duplicate, a sync conflict) so it can't come back. Audio in the call data directory is
    /// deleted when `deleteAudio`.
    public func delete(_ id: CallID, deleteAudio: Bool) throws {
        var audioError: Error?
        try locked {
            ensureLoadedLocked()
            guard let indexed = entries[id] else { throw LibraryError.notFound(id) }
            // The files must still hold this call: moved in Finder, they are found again; a file
            // that now holds another call is never deleted.
            var location: LibraryEntry?
            do {
                _ = try recordLocked(id)
                location = entries[id]
            } catch LibraryError.notFound(_) {
                location = nil                                  // already gone from the library folder
            } catch {
                location = entries[id]                          // damaged, but still this call's file
            }
            if let entry = location {
                if FileOps.exists(entry.files.json) {
                    do {
                        try FileManager.default.removeItem(at: entry.files.json)
                    } catch {
                        throw LibraryError.io("Couldn't delete “\(entry.summary.title)”: \(error.localizedDescription)")
                    }
                }
                if FileOps.exists(entry.files.markdown) {
                    do {
                        try FileManager.default.removeItem(at: entry.files.markdown)
                    } catch {
                        KanLog.error("Couldn't delete the Markdown of \(id): \(KanLog.describe(error))", category: "library")
                    }
                }
            }
            if indexed.files.markdown.path != location?.files.markdown.path,
               Self.markdownHoldsCall(indexed.files.markdown, id) {
                // Only the .json was moved: its old .md stayed behind.
                try? FileManager.default.removeItem(at: indexed.files.markdown)
            }
            for twin in twins[id] ?? [] { removeTwinLocked(twin, of: id) }
            if deleteAudio {
                let directory = callDataDirectoryResolver(id)
                if !id.isWellFormed || directory.lastPathComponent != id.rawValue {
                    // Never resolve an odd id to a directory to delete ("" or ".." would be Calls/ itself or its parent).
                    KanLog.error("Not deleting \(directory.path): \(id.rawValue.debugDescription) isn't a valid call id", category: "library")
                    audioError = LibraryError.io("The call was deleted, but its audio wasn't: its id isn't a valid call id.")
                } else if FileOps.exists(directory) {
                    do {
                        try FileManager.default.removeItem(at: directory)
                    } catch {
                        KanLog.error("Couldn't delete the audio of \(id): \(KanLog.describe(error))", category: "library")
                        audioError = LibraryError.io("The call was deleted, but its audio couldn't be removed: \(error.localizedDescription)")
                    }
                }
            }
            entries[id] = nil
            twins[id] = nil
            renderedStamps[id] = nil
            sortedIDs = nil
            forgetCachedRecordLocked(id)
            writeIndexesLoggingLocked()
            KanLog.info("Deleted call \(id)\(deleteAudio ? " and its audio" : "")", category: "library")
        }
        notify(.deleted(id))
        if let audioError { throw audioError }
    }

    // MARK: Folders

    /// Folders with counts, including empty directories the user created. Inbox ("") first.
    /// Counts are calls directly in the folder (not in its subfolders). Sorted as a tree.
    public func folders() -> [FolderInfo] {
        locked {
            ensureLoadedLocked()
            var counts: [String: Int] = [:]
            for entry in entries.values { counts[entry.folder, default: 0] += 1 }
            var names = folderSet
            for name in counts.keys where !name.isEmpty { names.formUnion(Self.ancestors(of: name)) }
            let sorted = names.filter { !$0.isEmpty }.sorted(by: Self.folderOrder)
            return [FolderInfo(name: "", count: counts[""] ?? 0)]
                + sorted.map { FolderInfo(name: $0, count: counts[$0] ?? 0) }
        }
    }

    public func createFolder(_ name: String) throws {
        guard let folder = Self.sanitizeFolder(name) else { throw LibraryError.invalidFolderName(name) }
        try locked {
            ensureLoadedLocked()
            let canonical = canonicalFolderLocked(folder)
            try createDirectory(directoryURL(components: LibraryNaming.directoryComponents(forFolder: canonical)))
            insertFolderLocked(canonical)
        }
        notify(.reloaded)
    }

    /// Renames a folder (and every call in it, including nested folders).
    public func renameFolder(_ name: String, to newName: String) throws {
        guard let from = Self.sanitizeFolder(name), !from.isEmpty else { throw LibraryError.invalidFolderName(name) }
        guard let to = Self.sanitizeFolder(newName), !to.isEmpty else { throw LibraryError.invalidFolderName(newName) }
        var changed = false
        var movedCalls = 0
        try locked {
            ensureLoadedLocked()
            let source = canonicalFolderLocked(from)
            let caseOnly = source.lowercased() == to.lowercased()
            guard source != to else { return }
            if !caseOnly && LibraryNaming.folder(to.lowercased(), isInside: source.lowercased()) {
                throw LibraryError.invalidFolderName("\(newName) (a folder can't move into itself)")
            }
            let target = caseOnly ? to : canonicalFolderLocked(to)
            let sourceURL = directoryURL(components: LibraryNaming.directoryComponents(forFolder: source))
            let targetURL = directoryURL(components: LibraryNaming.directoryComponents(forFolder: target))
            guard FileOps.exists(sourceURL) else { throw LibraryError.io("The folder “\(source)” doesn't exist.") }
            if !caseOnly && FileOps.exists(targetURL) {
                throw LibraryError.io("A folder named “\(target)” already exists.")
            }
            do {
                try FileOps.ensureDirectory(targetURL.deletingLastPathComponent())
                if caseOnly {
                    // Via a temporary name: case-insensitive volumes treat both spellings as one path.
                    let temporary = sourceURL.deletingLastPathComponent()
                        .appendingPathComponent(".kan-rename-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.moveItem(at: sourceURL, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: targetURL)
                } else {
                    try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                }
            } catch {
                throw LibraryError.io("Couldn't rename “\(source)”: \(error.localizedDescription)")
            }
            changed = true

            // Other copies of calls inside the folder moved with it.
            let sourcePrefix = sourceURL.path.hasSuffix("/") ? sourceURL.path : sourceURL.path + "/"
            func relocated(_ url: URL) -> URL {
                guard url.path.hasPrefix(sourcePrefix) else { return url }
                return targetURL.appendingPathComponent(String(url.path.dropFirst(sourcePrefix.count)))
            }
            twins = twins.mapValues { list in
                list.map { twin in
                    var moved = twin
                    moved.files = CallFiles(markdown: relocated(twin.files.markdown), json: relocated(twin.files.json))
                    return moved
                }
            }

            // Known folders first, so saving below spells the folder the new way…
            folderSet = Set(folderSet.map { name in
                LibraryNaming.folder(name.lowercased(), isInside: source.lowercased())
                    ? target + name.dropFirst(source.count) : name
            })
            insertFolderLocked(target)

            // …then the files, which moved with the directory: point the index at them and rewrite
            // each record so its `folder` field and front matter agree with the new location.
            batch {
                let affected = entries.values.filter { LibraryNaming.folder($0.folder.lowercased(), isInside: source.lowercased()) }
                movedCalls = affected.count
                for entry in affected {
                    let newFolder = target + entry.folder.dropFirst(source.count)
                    var moved = entry
                    moved.folder = newFolder
                    moved.directoryComponents = LibraryNaming.directoryComponents(forFolder: newFolder)
                    let directory = directoryURL(components: moved.directoryComponents)
                    moved.files = CallFiles(
                        markdown: directory.appendingPathComponent(entry.files.markdown.lastPathComponent),
                        json: directory.appendingPathComponent(entry.files.json.lastPathComponent))
                    entries[entry.id] = moved
                    forgetCachedRecordLocked(entry.id)
                    do {
                        var record = try recordLocked(entry.id)
                        record.folder = newFolder
                        _ = try saveLocked(record)
                    } catch {
                        KanLog.error("Folder rename: couldn't update \(entry.id): \(KanLog.describe(error))", category: "library")
                    }
                }
                sortedIDs = nil
                indexWritePending = true
            }
            KanLog.info("Renamed a folder (\(movedCalls) call(s) in it)", category: "library")     // folder names are the user's
        }
        if changed { notify(.reloaded) }
    }

    /// Deletes a folder: its calls (including those in nested folders) move to the Inbox, then its
    /// directories are removed when nothing else is left in them. Other files are never deleted.
    public func deleteFolder(_ name: String) throws {
        guard let folder = Self.sanitizeFolder(name), !folder.isEmpty else { throw LibraryError.invalidFolderName(name) }
        try locked {
            ensureLoadedLocked()
            let source = canonicalFolderLocked(folder)
            let affected = entries.values.filter { LibraryNaming.folder($0.folder.lowercased(), isInside: source.lowercased()) }
            let directory = directoryURL(components: LibraryNaming.directoryComponents(forFolder: source))
            guard !affected.isEmpty || FileOps.exists(directory) else {
                throw LibraryError.io("The folder “\(source)” doesn't exist.")
            }
            batch {
                for entry in affected {
                    do {
                        var record = try recordLocked(entry.id)
                        record.folder = ""
                        _ = try saveLocked(record)
                    } catch {
                        KanLog.error("Folder delete: couldn't move \(entry.id) to the Inbox: \(KanLog.describe(error))",
                                     category: "library")
                    }
                }
                Self.removeEmptyDirectories(directory)
                folderSet = folderSet.filter { name in
                    guard LibraryNaming.folder(name.lowercased(), isInside: source.lowercased()) else { return true }
                    return FileOps.exists(directoryURL(components: LibraryNaming.directoryComponents(forFolder: name)))
                }
                indexWritePending = true
            }
            KanLog.info("Deleted a folder (\(affected.count) call(s) moved to the Inbox)", category: "library")
        }
        notify(.reloaded)
    }

    /// The directory of a folder ("" = Inbox), or nil for an invalid name.
    public func directoryURL(forFolder folder: String) -> URL? {
        guard let sanitized = Self.sanitizeFolder(folder) else { return nil }
        return locked {
            directoryURL(components: LibraryNaming.directoryComponents(forFolder: canonicalFolderLocked(sanitized)))
        }
    }

    // MARK: Tags & people

    /// Tags with the number of calls using them, most used first (case-insensitive; the most
    /// common spelling is shown).
    public func tags() -> [NamedCount] {
        locked {
            ensureLoadedLocked()
            return Self.namedCounts(entries.values.map(\.summary.tags))
        }
    }

    /// Speaker names across calls (excluding default "Speaker N" names), most frequent first.
    /// The user's own speaker ("me") is excluded too.
    public func people() -> [NamedCount] {
        locked {
            ensureLoadedLocked()
            return Self.namedCounts(entries.values.map(\.people))
        }
    }

    /// The apps calls were recorded from: bundle id → the app name of the newest call from it.
    /// From the index, so no call is read (Settings › Detection lists the apps outside the catalog
    /// with it). Calls without a bundle id (hand-written records) are left out.
    public func recordedApps() -> [String: String] {
        locked {
            ensureLoadedLocked()
            var newest: [String: (name: String, startedAt: Date)] = [:]
            for entry in entries.values {
                guard let bundleID = entry.bundleID else { continue }
                if let known = newest[bundleID], known.startedAt >= entry.summary.startedAt { continue }
                newest[bundleID] = (entry.summary.appName, entry.summary.startedAt)
            }
            return newest.mapValues(\.name)
        }
    }

    // MARK: Search

    /// Searches titles, tags, notes, bookmarks and transcripts. See `SearchQuery` for the syntax.
    /// Returns one hit per matching field (one per matching transcript segment), best first:
    /// title > tags > notes > bookmark > transcript, then more matched terms, then newer calls.
    /// Without text, lists the calls passing the filters (newest first) as title hits whose snippet
    /// is the call's preview. `limit` ≤ 0 means no limit.
    public func search(_ query: SearchQuery) -> [SearchHit] {
        let (candidates, parsed) = searchCandidates(query)
        let limit = query.limit > 0 ? query.limit : Int.max
        if parsed.isEmpty {
            return candidates.sorted(by: Self.newestFirst).prefix(limit).map(LibrarySearch.listingHit(for:))
        }
        var ranked: [LibrarySearch.RankedHit] = []
        for (index, entry) in candidates.enumerated() {
            guard let raws = LibrarySearch.match(entry, query: parsed) else { continue }
            for raw in raws {
                ranked.append(LibrarySearch.RankedHit(raw: raw, call: index, startedAt: entry.summary.startedAt, id: entry.id))
            }
        }
        ranked.sort(by: LibrarySearch.ordered)
        return ranked.prefix(limit).map { LibrarySearch.materialize($0.raw, in: candidates[$0.call], query: parsed) }
    }

    /// The same search grouped by call: matching calls, best first (`limit` applies to calls), each
    /// with its best `hitsPerCall` hits.
    public func searchCalls(_ query: SearchQuery, hitsPerCall: Int = 5) -> [CallSearchResult] {
        let (candidates, parsed) = searchCandidates(query)
        let limit = query.limit > 0 ? query.limit : Int.max
        if parsed.isEmpty {
            return candidates.sorted(by: Self.newestFirst).prefix(limit).map {
                CallSearchResult(summary: $0.summary, hits: [LibrarySearch.listingHit(for: $0)], totalHits: 1, score: 0)
            }
        }
        var results: [CallSearchResult] = []
        for entry in candidates {
            guard var raws = LibrarySearch.match(entry, query: parsed) else { continue }
            raws.sort(by: LibrarySearch.withinCall)
            let hits = raws.prefix(max(1, hitsPerCall)).map { LibrarySearch.materialize($0, in: entry, query: parsed) }
            results.append(CallSearchResult(summary: entry.summary, hits: hits, totalHits: raws.count,
                                            score: LibrarySearch.callScore(raws)))
        }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.summary.startedAt != b.summary.startedAt { return a.summary.startedAt > b.summary.startedAt }
            return a.summary.id > b.summary.id
        }
        return Array(results.prefix(limit))
    }

    private func searchCandidates(_ query: SearchQuery) -> ([LibraryEntry], ParsedQuery) {
        let snapshot: [LibraryEntry] = locked {
            ensureLoadedLocked()
            return Array(entries.values)
        }
        let filters = LibrarySearch.Filters(query)
        return (snapshot.filter(filters.accepts), ParsedQuery(query.text))
    }

    // MARK: Index files

    /// Rewrite index.md, index.jsonl and AGENTS.md (AGENTS.md only when missing or outdated).
    public func writeIndexes() throws {
        try locked {
            ensureLoadedLocked()
            try writeIndexesLocked(force: true)
        }
    }

    public var indexMarkdownURL: URL { root.appendingPathComponent(LibraryNaming.indexMarkdownName) }
    public var indexJSONLURL: URL { root.appendingPathComponent(LibraryNaming.indexJSONLName) }
    public var agentsGuideURL: URL { root.appendingPathComponent(LibraryNaming.agentsFileName) }

    // MARK: Naming

    /// Sanitized folder name, or nil if it can't be made valid.
    ///
    /// Components are split on "/", trimmed and single-spaced; empty components are dropped;
    /// ":", "\" and "|" become "-", `* ? < >` are removed, leading dots are stripped; "." / ".."
    /// components, names reserved at the root (AGENTS.md, index.*) and more than 12 levels are
    /// rejected. "" and "Inbox" mean the Inbox (""). Text is NFC.
    public static func sanitizeFolder(_ name: String) -> String? {
        LibraryNaming.sanitizeFolder(name)
    }

    /// The base file name a record gets: "<yyyy-MM-dd HHmm> <title>" in its own time zone
    /// (without a collision suffix or extension). Handy for export file names.
    public static func fileBaseName(for record: CallRecord) -> String {
        LibraryNaming.baseName(for: record)
    }

    // MARK: - Internals (lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        lockDepth += 1
        if lockDepth == 1 { relocationScanned = false }
        defer {
            lockDepth -= 1
            lock.unlock()
        }
        return try body()
    }

    private func notify(_ change: LibraryChange) {
        let handler = locked { changeHandler }
        handler?(change)
    }

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        do {
            try reloadLocked()
        } catch {
            KanLog.error("Library load failed: \(error.localizedDescription)", category: "library")
            loaded = true
        }
    }

    private func reloadLocked() throws {
        let started = Date()
        let result = try LibraryScanner(root: root).scan()
        // Building entries (summary, search text, index rows) is independent per call: parallel too.
        let found = result.calls
        let root = self.root
        var built = [LibraryEntry?](repeating: nil, count: found.count)
        built.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: found.count) { i in
                var record = found[i].record
                record.folder = LibraryNaming.folder(forDirectoryComponents: found[i].directoryComponents)
                var entry = LibraryEntry(record: record, directoryComponents: found[i].directoryComponents,
                                         baseName: found[i].baseName, root: root)
                entry.stamp = found[i].stamp
                slots[i] = entry
            }
        }
        var fresh: [CallID: LibraryEntry] = [:]
        var chosen: [CallID: Int] = [:]
        var freshTwins: [CallID: [LibraryTwin]] = [:]
        for (i, item) in built.enumerated() {
            guard let entry = item else { continue }
            let id = found[i].record.id
            guard let current = chosen[id], let currentEntry = fresh[id] else {
                chosen[id] = i
                fresh[id] = entry
                continue
            }
            let replaces = found[i].isPreferred(over: found[current])
            let (other, otherIndex) = replaces ? (currentEntry, current) : (entry, i)
            // Not the paths: file names are titles, folders are the user's.
            KanLog.warning("Two files hold call \(id) (a copy or a sync conflict); the other one is left alone "
                           + "until the call is deleted", category: "library")
            freshTwins[id, default: []].append(LibraryTwin(files: other.files, updatedAt: other.updatedAt,
                                                           hasKanName: found[otherIndex].hasKanName))
            if replaces {
                chosen[id] = i
                fresh[id] = entry
            }
        }
        entries = fresh
        twins = freshTwins
        renderedStamps = renderedStamps.filter { fresh[$0.key] != nil }
        folderSet = result.folders
        sortedIDs = nil
        recordCache.removeAll()
        recordCacheOrder.removeAll()
        loaded = true
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        KanLog.info("Loaded \(fresh.count) calls from \(root.path) in \(elapsed) ms"
                    + (result.skipped > 0 ? " (\(result.skipped) unreadable files skipped)" : ""), category: "library")
    }

    private func sortedSummariesLocked() -> [CallSummary] {
        sortedIDsLocked().compactMap { entries[$0]?.summary }
    }

    private func sortedIDsLocked() -> [CallID] {
        if let ids = sortedIDs { return ids }
        let ids = entries.values.sorted(by: Self.newestFirst).map(\.id)
        sortedIDs = ids
        return ids
    }

    private static func newestFirst(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        if a.summary.startedAt != b.summary.startedAt { return a.summary.startedAt > b.summary.startedAt }
        return a.id > b.id
    }

    /// The record of an indexed call, read from its JSON file. When the file is no longer where it
    /// was indexed (moved or renamed in Finder, or replaced by another call), the library is
    /// rescanned once to find it before the call is reported gone: a transcript arriving from the
    /// queue must not be dropped because the user just filed the call.
    private func recordLocked(_ id: CallID) throws -> CallRecord {
        guard entries[id] != nil else { throw LibraryError.notFound(id) }
        if let record = try indexedRecordLocked(id) { return record }
        if !relocationScanned {
            relocationScanned = true
            KanLog.info("Call \(id) isn't at its indexed path any more; rescanning the library", category: "library")
            try reloadLocked()
            if entries[id] != nil, let record = try indexedRecordLocked(id) { return record }
        }
        // Deleted outside Kan.
        entries[id] = nil
        twins[id] = nil
        sortedIDs = nil
        forgetCachedRecordLocked(id)
        throw LibraryError.notFound(id)
    }

    /// The record at the indexed path, or nil when that file is gone or now holds another call.
    private func indexedRecordLocked(_ id: CallID) throws -> CallRecord? {
        guard let entry = entries[id] else { return nil }
        let url = entry.files.json
        guard let stamp = FileOps.stamp(url) else { return nil }
        if let cached = recordCache[id], cached.stamp == stamp {
            var record = cached.record
            record.folder = entry.folder
            return record
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LibraryError.io("Couldn't read \(entry.summary.jsonPath): \(error.localizedDescription)")
        }
        var record: CallRecord
        do {
            record = try JSONDecoder.kan.decode(CallRecord.self, from: data)
        } catch {
            throw LibraryError.io("The call record \(entry.summary.jsonPath) is damaged: \(error)")
        }
        guard record.id == id, record.kind == "kan.call" else { return nil }      // another call lives here now
        record.folder = entry.folder
        if entry.stamp != stamp {
            // Edited outside Kan since it was indexed: refresh the summary and search text.
            var refreshed = LibraryEntry(record: record, directoryComponents: entry.directoryComponents,
                                         baseName: entry.baseName, root: root)
            refreshed.stamp = stamp
            entries[id] = refreshed
            sortedIDs = nil
        }
        cacheRecordLocked(record, stamp: stamp)
        return record
    }

    private func cacheRecordLocked(_ record: CallRecord, stamp: FileOps.Stamp?) {
        forgetCachedRecordLocked(record.id)
        guard let stamp else { return }
        recordCache[record.id] = CachedRecord(record: record, stamp: stamp)
        recordCacheOrder.append(record.id)
        while recordCacheOrder.count > Self.recordCacheCapacity {
            recordCache[recordCacheOrder.removeFirst()] = nil
        }
    }

    private func forgetCachedRecordLocked(_ id: CallID) {
        recordCache[id] = nil
        recordCacheOrder.removeAll { $0 == id }
    }

    private func saveLocked(_ input: CallRecord) throws -> (entry: LibraryEntry, record: CallRecord) {
        // The id names the call's data directory: only a ULID is a safe path component.
        guard input.id.isWellFormed else {
            throw LibraryError.io("“\(input.title)” has an invalid call id \(input.id.rawValue.debugDescription) (a call id is a 26-character ULID).")
        }
        // JSON keeps milliseconds, so a copy read back from disk may look up to 1 ms older.
        if let current = entries[input.id], input.updatedAt.timeIntervalSince(current.updatedAt) < -0.001 {
            // Someone saved this call after this copy was read; it now replaces their changes.
            KanLog.warning("save() replaced a newer version of \(input.id) — use update() for edits", category: "library")
        }
        var record = Self.normalized(input)
        guard let folder = Self.sanitizeFolder(record.folder) else { throw LibraryError.invalidFolderName(input.folder) }
        record.folder = canonicalFolderLocked(folder)
        record.updatedAt = Date()

        let components = LibraryNaming.directoryComponents(forFolder: record.folder)
        let directory = directoryURL(components: components)
        let previous = entries[record.id]
        try createDirectory(directory)
        // Before choosing the name, so a leftover copy doesn't push the call to "<name> (2)".
        removeLeftoverTwinsLocked(of: record, near: [directory] + [previous?.files.json.deletingLastPathComponent()].compactMap { $0 })
        let name = chooseNameLocked(base: LibraryNaming.baseName(for: record), directory: directory, previous: previous,
                                    id: record.id)
        let jsonURL = directory.appendingPathComponent(name + "." + LibraryNaming.jsonExtension)
        let markdownURL = directory.appendingPathComponent(name + "." + LibraryNaming.markdownExtension)

        let json: Data
        do {
            json = try TranscriptRenderer.json(record)
            try FileOps.replace(previous?.files.json, with: json, at: jsonURL)
        } catch {
            throw LibraryError.io("Couldn't save “\(record.title)”: \(error.localizedDescription)")
        }
        let stamp = FileOps.stamp(jsonURL)
        do {
            try FileOps.replace(previous?.files.markdown, with: Data(TranscriptRenderer.markdown(record).utf8), at: markdownURL)
            renderedStamps[record.id] = stamp
        } catch {
            // The JSON (source of truth) is saved; the Markdown is regenerated on the next save
            // or reconcile.
            renderedStamps[record.id] = nil
            KanLog.error("Couldn't write the Markdown of \(record.id): \(KanLog.describe(error))", category: "library")
        }
        if let previous {
            FileOps.removeStale(previous.files.json, keeping: jsonURL)
            FileOps.removeStale(previous.files.markdown, keeping: markdownURL)
            if previous.files.json.path != jsonURL.path {
                // By id: the paths name the call's title and folder.
                let renamedOnly = previous.files.json.deletingLastPathComponent().path == directory.path
                KanLog.info("Moved call \(record.id)" + (renamedOnly ? " (new title)" : " to another folder"),
                            category: "library")
            }
        }

        var entry = LibraryEntry(record: record, directoryComponents: components, baseName: name, root: root)
        entry.stamp = stamp
        entries[record.id] = entry
        sortedIDs = nil
        insertFolderLocked(record.folder)
        cacheRecordLocked(record, stamp: stamp)
        writeIndexesLoggingLocked()
        return (entry, record)
    }

    /// When a call is saved: removes older copies of it that Kan itself left next to it (a rename
    /// interrupted between writing the new name and removing the old one), in the folder it is
    /// saved to or the one it was in. Copies the user made ("… copy", or in another folder) are
    /// left alone until the call is deleted.
    private func removeLeftoverTwinsLocked(of record: CallRecord, near directories: [URL]) {
        guard let others = twins[record.id] else { return }
        let remaining = others.filter { twin in
            let twinDirectory = twin.files.json.deletingLastPathComponent()
            let nearby = directories.contains { $0.path == twinDirectory.path || FileOps.isSameFile($0, twinDirectory) }
            guard twin.hasKanName, nearby, twin.updatedAt < record.updatedAt else { return true }
            removeTwinLocked(twin, of: record.id)
            return false
        }
        twins[record.id] = remaining.isEmpty ? nil : remaining
    }

    /// Deletes a twin's files, after checking they still hold this call.
    private func removeTwinLocked(_ twin: LibraryTwin, of id: CallID) {
        guard Self.jsonHoldsCall(twin.files.json, id) else { return }
        do {
            try FileManager.default.removeItem(at: twin.files.json)
            if Self.markdownHoldsCall(twin.files.markdown, id) {
                try FileManager.default.removeItem(at: twin.files.markdown)
            }
            KanLog.info("Removed another copy of call \(id)", category: "library")
        } catch {
            KanLog.error("Couldn't remove another copy of call \(id): \(KanLog.describe(error))", category: "library")
        }
    }

    private struct CallIdentityProbe: Decodable {
        let kind: String?
        let id: CallID?
    }

    /// True if the JSON file is a Kan call record with this id.
    private static func jsonHoldsCall(_ url: URL, _ id: CallID) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              let probe = try? JSONDecoder().decode(CallIdentityProbe.self, from: data) else { return false }
        return probe.kind == "kan.call" && probe.id == id
    }

    /// True if the Markdown file's front matter names this call (`kan_id: <id>`).
    private static func markdownHoldsCall(_ url: URL, _ id: CallID) -> Bool {
        guard let head = FileOps.head(url, maxBytes: 1024) else { return false }
        return String(decoding: head, as: UTF8.self).contains("\nkan_id: \(id.rawValue)\n")
    }

    /// Keeps the current name when the call stays put with the same base name ("a record keeps its
    /// own name", including its " (n)" suffix); otherwise the first free "<base>", "<base> (2)", ….
    private func chooseNameLocked(base: String, directory: URL, previous: LibraryEntry?, id: CallID) -> String {
        if let previous {
            let previousDirectory = previous.files.json.deletingLastPathComponent()
            let sameDirectory = previousDirectory.path == directory.path || FileOps.isSameFile(previousDirectory, directory)
            if sameDirectory, LibraryNaming.collisionNumber(of: previous.baseName, base: base) != nil {
                return previous.baseName
            }
        }
        var n = 1
        while true {
            let candidate = n == 1 ? base : "\(base) (\(n))"
            if !isTakenLocked(candidate, in: directory, by: id, previous: previous) { return candidate }
            n += 1
        }
    }

    private func isTakenLocked(_ name: String, in directory: URL, by id: CallID, previous: LibraryEntry?) -> Bool {
        let json = directory.appendingPathComponent(name + "." + LibraryNaming.jsonExtension)
        let markdown = directory.appendingPathComponent(name + "." + LibraryNaming.markdownExtension)
        if FileOps.exists(json) && !(previous.map { FileOps.isSameFile(json, $0.files.json) } ?? false) { return true }
        if FileOps.exists(markdown) && !(previous.map { FileOps.isSameFile(markdown, $0.files.markdown) } ?? false) { return true }
        let key = name.nfc.lowercased()
        for entry in entries.values where entry.id != id && entry.baseName.nfc.lowercased() == key {
            let other = entry.files.json.deletingLastPathComponent()
            if other.path == directory.path || FileOps.isSameFile(other, directory) { return true }
        }
        return false
    }

    /// Stored text is NFC, single-line where it's a label; tags lose "#" and duplicates.
    static func normalized(_ input: CallRecord) -> CallRecord {
        var r = input
        r.title = r.title.nfc.singleLine
        if r.title.isEmpty { r.title = TranscriptRenderer.suggestedTitle(for: r) }
        r.tags = r.tags.compactMap { tag in
            var t = tag.nfc.singleLine
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }.uniquedCaseInsensitive()
        r.notes = r.notes.nfc
        r.attendees = r.attendees.compactMap { $0.nfc.singleLine.nonEmptyTrimmed }.uniquedCaseInsensitive()
        r.calendarEventTitle = r.calendarEventTitle.flatMap { $0.nfc.singleLine.nonEmptyTrimmed }
        r.source.meetingTitle = r.source.meetingTitle.flatMap { $0.nfc.singleLine.nonEmptyTrimmed }
        for i in r.speakers.indices {
            r.speakers[i].name = r.speakers[i].name.nfc.singleLine
            r.speakers[i].suggestedName = r.speakers[i].suggestedName.flatMap { $0.nfc.singleLine.nonEmptyTrimmed }
        }
        for i in r.segments.indices { r.segments[i].text = r.segments[i].text.nfc }
        for i in r.bookmarks.indices { r.bookmarks[i].note = r.bookmarks[i].note.nfc }
        return r
    }

    private func writeIndexesLoggingLocked() {
        do {
            try writeIndexesLocked(force: false)
        } catch {
            KanLog.error("Couldn't update the library index files: \(KanLog.describe(error))", category: "library")
        }
    }

    private func writeIndexesLocked(force: Bool) throws {
        if batchDepth > 0 {
            indexWritePending = true
            return
        }
        try createDirectory(root)
        let ordered = sortedIDsLocked().compactMap { entries[$0] }
        let markdown = Data(LibraryIndexFiles.markdown(rows: ordered.map(\.indexRow)).utf8)
        let jsonl = Data(LibraryIndexFiles.jsonl(lines: ordered.map(\.jsonLine)).utf8)
        if force || markdown != lastIndexMarkdown || !FileOps.exists(indexMarkdownURL),
           mayWriteIndexLocked(indexMarkdownURL, isKan: LibraryIndexFiles.isKanMarkdown) {
            try FileOps.writeAtomically(markdown, to: indexMarkdownURL)
            lastIndexMarkdown = markdown
        }
        if force || jsonl != lastIndexJSONL || !FileOps.exists(indexJSONLURL),
           mayWriteIndexLocked(indexJSONLURL, isKan: LibraryIndexFiles.isKanJSONL) {
            try FileOps.writeAtomically(jsonl, to: indexJSONLURL)
            lastIndexJSONL = jsonl
        }
        try AgentsGuide.writeIfNeeded(root: root)
    }

    /// True if Kan may (re)write this index file: it is missing or Kan wrote it. A file of the same
    /// name that the user already had in the folder (a vault's index.md) is never overwritten.
    private func mayWriteIndexLocked(_ url: URL, isKan: (Data) -> Bool) -> Bool {
        guard FileOps.exists(url) else { return true }
        if let head = FileOps.head(url, maxBytes: LibraryIndexFiles.recognitionBytes), isKan(head) {
            foreignIndexFiles.remove(url.lastPathComponent)
            return true
        }
        if foreignIndexFiles.insert(url.lastPathComponent).inserted {
            KanLog.warning("Not writing \(url.lastPathComponent): \(url.path) wasn't written by Kan, so it is left alone",
                           category: "library")
        }
        return false
    }

    /// Runs `body` with index writes deferred to one write at the end (folder operations).
    private func batch<T>(_ body: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 && indexWritePending {
                indexWritePending = false
                writeIndexesLoggingLocked()
            }
        }
        return try body()
    }

    private func directoryURL(components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try FileOps.ensureDirectory(url)
        } catch {
            throw LibraryError.io("Couldn't create the folder \(url.path): \(error.localizedDescription)")
        }
    }

    /// Reuses the on-disk spelling of existing folders ("research" → "Research").
    private func canonicalFolderLocked(_ folder: String) -> String {
        guard !folder.isEmpty else { return "" }
        var result: [String] = []
        for part in folder.split(separator: "/").map(String.init) {
            let prefix = (result + [part]).joined(separator: "/")
            if let known = folderSet.first(where: { $0.caseInsensitiveCompare(prefix) == .orderedSame }) {
                result = known.split(separator: "/").map(String.init)
            } else {
                result.append(part)
            }
        }
        return result.joined(separator: "/")
    }

    private func insertFolderLocked(_ folder: String) {
        guard !folder.isEmpty else { return }
        folderSet.formUnion(Self.ancestors(of: folder))
    }

    /// "A/B/C" → ["A", "A/B", "A/B/C"].
    private static func ancestors(of folder: String) -> [String] {
        var out: [String] = []
        var current = ""
        for part in folder.split(separator: "/") {
            current = current.isEmpty ? String(part) : current + "/" + part
            out.append(current)
        }
        return out
    }

    /// Tree order: component by component, Finder-like comparison.
    private static func folderOrder(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "/"), pb = b.split(separator: "/")
        for (x, y) in zip(pa, pb) {
            let order = String(x).localizedStandardCompare(String(y))
            if order != .orderedSame { return order == .orderedAscending }
        }
        return pa.count < pb.count
    }

    private static func namedCounts(_ lists: [[String]]) -> [NamedCount] {
        var groups: [String: [String: Int]] = [:]     // folded name → spelling → count
        for list in lists {
            for name in list.uniquedCaseInsensitive() {
                groups[TextFolding.fold(name.nfc), default: [:]][name, default: 0] += 1
            }
        }
        let counts = groups.values.compactMap { spellings -> NamedCount? in
            let total = spellings.values.reduce(0, +)
            let display = spellings.max { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            }?.key
            return display.map { NamedCount(name: $0, count: total) }
        }
        return counts.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Removes empty directories bottom-up (a stray .DS_Store counts as empty). Returns true if
    /// `directory` itself was removed.
    @discardableResult
    private static func removeEmptyDirectories(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: []) else { return false }
        var remaining = 0
        for item in items {
            if item.lastPathComponent == ".DS_Store" { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory && removeEmptyDirectories(item) { continue }
            remaining += 1
        }
        guard remaining == 0 else { return false }
        do {
            try fm.removeItem(at: directory)
            return true
        } catch {
            KanLog.warning("Couldn't remove an empty folder: \(KanLog.describe(error))", category: "library")
            return false
        }
    }
}
