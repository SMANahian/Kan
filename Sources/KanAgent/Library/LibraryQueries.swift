import Foundation
import KanCore

/// Filters shared by listing and searching (see `SearchQuery` for the matching rules).
public struct CallFilter: Sendable, Equatable {
    /// Folder including its subfolders; "" or "Inbox" = the Inbox only.
    public var folder: String?
    public var tag: String?
    /// Substring of a speaker name or attendee.
    public var person: String?
    /// App name ("Zoom", "Zen"), platform id ("googleMeet") or platform name ("Google Meet").
    public var app: String?
    /// Inclusive bounds on the call's start.
    public var since: Date?
    public var until: Date?
    public var starredOnly: Bool
    public var status: CallStatus?

    public init(folder: String? = nil, tag: String? = nil, person: String? = nil, app: String? = nil,
                since: Date? = nil, until: Date? = nil, starredOnly: Bool = false, status: CallStatus? = nil) {
        self.folder = folder
        self.tag = tag
        self.person = person
        self.app = app
        self.since = since
        self.until = until
        self.starredOnly = starredOnly
        self.status = status
    }

    func searchQuery(text: String) -> SearchQuery {
        SearchQuery(text: text, folder: folder, tag: tag, person: person, appName: app, from: since, to: until,
                    starredOnly: starredOnly, limit: 0)
    }
}

/// A page of calls, newest first.
public struct CallPage: Sendable {
    public var calls: [CallSummary]
    /// Calls matching the filters (all pages).
    public var total: Int
    public var offset: Int
    /// 0 = no limit.
    public var limit: Int
    /// Offset of the next page, nil on the last one.
    public var nextOffset: Int? {
        let end = offset + calls.count
        return end < total ? end : nil
    }
}

/// One search hit with the summary of its call (title, date, time zone).
public struct Passage: Sendable {
    public var summary: CallSummary
    public var hit: SearchHit
}

public struct PassageResults: Sendable {
    /// Best call first; inside a call: title, tags, notes, bookmarks, then transcript by time.
    public var passages: [Passage]
    public var matchedCalls: Int
    /// Every hit in the matching calls, including those not returned.
    public var totalHits: Int
    /// True when hits were left out because of the limits.
    public var truncated: Bool { passages.count < totalHits }
}

/// A slice of a call's transcript (visible segments: echo suspects hidden, empty ones skipped).
public struct TranscriptPage: Sendable {
    public var record: CallRecord
    public var segments: [TranscriptSegment]
    public var offset: Int
    public var limit: Int
    /// Segments in the requested time range (all pages).
    public var total: Int
    /// Visible segments in the whole call.
    public var callSegments: Int
    public var fromSeconds: Double?
    public var toSeconds: Double?

    public var nextOffset: Int? {
        let end = offset + segments.count
        return end < total ? end : nil
    }
}

/// A folder with its call counts ("" = Inbox).
public struct FolderRow: Sendable, Equatable {
    public var name: String
    /// Calls directly in the folder.
    public var count: Int
    /// Calls in the folder and its subfolders.
    public var total: Int

    public var displayName: String { name.isEmpty ? "Inbox" : name }
    /// Nesting level: 0 for the Inbox and top-level folders.
    public var depth: Int { name.isEmpty ? 0 : name.split(separator: "/").count - 1 }
    public var leafName: String { name.isEmpty ? "Inbox" : String(name.split(separator: "/").last ?? "") }
}

public struct LibraryStats: Sendable {
    public var calls: Int
    public var byStatus: [CallStatus: Int]
    public var starred: Int
    public var unlabeled: Int
    public var folders: Int
    public var tags: Int
    public var people: Int
    public var totalSeconds: Double
    public var first: CallSummary?
    public var last: CallSummary?
}

/// Read-only queries over a `LibraryStore`, shared by the CLI and the MCP server. Thread-safe
/// (the store is).
public enum LibraryQueries {
    /// Calls passing the filters (and containing every term of `text`, when given), newest first.
    /// `limit` 0 = all.
    public static func list(_ store: LibraryStore, filter: CallFilter, text: String? = nil,
                            offset: Int = 0, limit: Int = 0) -> CallPage {
        var calls: [CallSummary]
        if let text = text?.nonEmptyPath {
            calls = store.searchCalls(filter.searchQuery(text: text), hitsPerCall: 1).map(\.summary)
            calls.sort(by: newestFirst)
        } else {
            let byID = Dictionary(store.summaries().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            calls = store.search(filter.searchQuery(text: "")).compactMap { byID[$0.callID] }
        }
        if let status = filter.status { calls = calls.filter { $0.status == status } }
        let total = calls.count
        let (start, end) = pageBounds(count: total, offset: offset, limit: limit)
        return CallPage(calls: Array(calls[start..<end]), total: total, offset: start, limit: max(0, limit))
    }

    /// Matching passages: at most `perCall` per call (its best hits), `limit` in all (0 = no limit).
    public static func search(_ store: LibraryStore, text: String, filter: CallFilter, limit: Int,
                              perCall: Int) -> PassageResults {
        var results = store.searchCalls(filter.searchQuery(text: text), hitsPerCall: max(1, perCall))
        if let status = filter.status { results = results.filter { $0.summary.status == status } }
        var passages: [Passage] = []
        let cap = limit > 0 ? limit : Int.max
        for result in results {
            let room = cap - passages.count
            guard room > 0 else { break }
            let best = result.hits.prefix(min(max(1, perCall), room))
            for hit in best.sorted(by: readingOrder) {
                passages.append(Passage(summary: result.summary, hit: hit))
            }
        }
        return PassageResults(passages: passages, matchedCalls: results.count,
                              totalHits: results.reduce(0) { $0 + $1.totalHits })
    }

    /// The visible transcript of a call, in reading order: echo suspects hidden, empty segments
    /// skipped, stable by start time.
    public static func visibleSegments(_ record: CallRecord) -> [TranscriptSegment] {
        record.segments.enumerated()
            .filter { !$0.element.flags.contains(.echoSuspect) && !$0.element.text.singleLineText.isEmpty }
            .sorted { a, b in a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset }
            .map(\.element)
    }

    /// A page of the visible transcript. Segments overlapping [from, to) are in range; `offset` and
    /// `limit` then count segments within the range.
    public static func transcript(_ record: CallRecord, from: Double?, to: Double?, offset: Int, limit: Int) -> TranscriptPage {
        let visible = visibleSegments(record)
        let lower = from ?? 0
        let upper = to ?? .infinity
        let inRange = visible.filter { segment in
            segment.start < upper && (segment.end > lower || segment.start >= lower)
        }
        let (start, end) = pageBounds(count: inRange.count, offset: offset, limit: limit)
        return TranscriptPage(record: record, segments: Array(inRange[start..<end]), offset: start, limit: limit,
                              total: inRange.count, callSegments: visible.count, fromSeconds: from, toSeconds: to)
    }

    /// Folders in tree order with direct and nested counts.
    public static func folderRows(_ store: LibraryStore) -> [FolderRow] {
        let folders = store.folders()
        return folders.map { folder in
            guard !folder.name.isEmpty else { return FolderRow(name: "", count: folder.count, total: folder.count) }
            let prefix = folder.name.lowercased() + "/"
            let nested = folders.filter { $0.name.lowercased().hasPrefix(prefix) }.reduce(0) { $0 + $1.count }
            return FolderRow(name: folder.name, count: folder.count, total: folder.count + nested)
        }
    }

    public static func stats(_ store: LibraryStore) -> LibraryStats {
        let summaries = store.summaries()
        var byStatus: [CallStatus: Int] = [:]
        for s in summaries { byStatus[s.status, default: 0] += 1 }
        return LibraryStats(
            calls: summaries.count, byStatus: byStatus,
            starred: summaries.filter(\.starred).count,
            unlabeled: summaries.filter { !$0.labeled }.count,
            folders: store.folders().filter { !$0.name.isEmpty }.count,
            tags: store.tags().count, people: store.people().count,
            totalSeconds: summaries.reduce(0) { $0 + $1.duration },
            first: summaries.last, last: summaries.first)
    }

    /// Named speakers of a call (placeholders such as "Speaker 2" left out); the user's own
    /// speaker is normally first.
    public static func people(_ summary: CallSummary) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in summary.speakerNames {
            let clean = name.singleLineText
            guard !clean.isEmpty, !Speaker.isDefaultName(clean), seen.insert(clean.lowercased()).inserted else { continue }
            names.append(clean)
        }
        return names
    }

    /// Speaker turns for reading: consecutive segments of one speaker less than `mergeGap` apart
    /// become one paragraph while it stays under `maxTurnSeconds` (the rule the .md files use).
    public static func turns(_ segments: [TranscriptSegment]) -> [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            let text = segment.text.nfc.singleLineText
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speakerID == segment.speakerID, segment.start - last.end < mergeGap,
               segment.end - last.start <= maxTurnSeconds {
                last.end = max(last.end, segment.end)
                last.texts.append(text)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speakerID: segment.speakerID, start: segment.start, end: segment.end, texts: [text]))
            }
        }
        return turns
    }

    public struct Turn: Sendable, Equatable {
        public var speakerID: String
        public var start: Double
        public var end: Double
        public var texts: [String]
        public var text: String { texts.joined(separator: " ") }
    }

    static let mergeGap: Double = 2
    static let maxTurnSeconds: Double = 90

    /// A note about the transcript's state for calls that aren't simply ready, nil otherwise.
    public static func statusNote(_ record: CallRecord) -> String? {
        let hasTranscript = !visibleSegments(record).isEmpty
        switch record.status {
        case .recording:
            return hasTranscript ? nil : "Recording in progress — the transcript will appear after the call."
        case .queued, .processing:
            return hasTranscript ? "A new transcript is being generated; this is the previous one."
                                 : "The transcript is being generated; try again in a few minutes."
        case .failed:
            let error = record.processing?.error?.singleLineText ?? ""
            let reason = error.isEmpty ? "unknown error" : error
            return hasTranscript ? "The last transcription attempt failed (\(reason)); this is the previous transcript."
                                 : "Transcription failed: \(reason)."
        case .ready:
            return hasTranscript ? nil : "No speech was detected in this call."
        }
    }

    /// The slice `offset..<offset + limit` clamped to `0..<count` (limit ≤ 0 = to the end), without
    /// overflowing for huge values.
    static func pageBounds(count: Int, offset: Int, limit: Int) -> (start: Int, end: Int) {
        let start = min(max(0, offset), count)
        let end = limit > 0 ? start + min(limit, count - start) : count
        return (start, end)
    }

    // MARK: Ordering

    static func newestFirst(_ a: CallSummary, _ b: CallSummary) -> Bool {
        a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id > b.id
    }

    /// Title, tags, notes, bookmark, then transcript passages by time.
    static func readingOrder(_ a: SearchHit, _ b: SearchHit) -> Bool {
        let fa = fieldRank(a.field), fb = fieldRank(b.field)
        if fa != fb { return fa < fb }
        return (a.time ?? -1) < (b.time ?? -1)
    }

    private static func fieldRank(_ field: SearchField) -> Int {
        switch field {
        case .title: return 0
        case .tags: return 1
        case .notes: return 2
        case .bookmark: return 3
        case .transcript: return 4
        }
    }
}
