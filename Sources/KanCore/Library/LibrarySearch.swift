import Foundation

/// A call matching a search, with its hits (see `LibraryStore.searchCalls`).
public struct CallSearchResult: Sendable, Hashable, Identifiable {
    public var id: CallID { summary.id }
    public var summary: CallSummary
    /// The call's best hits, best first (at most the `hitsPerCall` asked for).
    public var hits: [SearchHit]
    /// All hits in the call, including those cut by `hitsPerCall`.
    public var totalHits: Int
    public var score: Double

    public init(summary: CallSummary, hits: [SearchHit], totalHits: Int, score: Double) {
        self.summary = summary
        self.hits = hits
        self.totalHits = totalHits
        self.score = score
    }
}

/// The search engine behind `LibraryStore.search` / `searchCalls`. Pure functions over index entries.
enum LibrarySearch {
    struct Filters {
        let folder: String?
        let tag: String?
        /// Matched like search text (substring, case-insensitive, no diacritic folding).
        let person: FoldedPattern?
        let app: String?
        let from: Date?
        let to: Date?
        let starredOnly: Bool

        init(_ query: SearchQuery) {
            folder = query.folder.map { (LibraryNaming.sanitizeFolder($0) ?? $0.nfc).lowercased() }
            tag = query.tag.flatMap { raw in
                var t = raw.nfc.singleLine
                while t.hasPrefix("#") { t.removeFirst() }
                return t.isEmpty ? nil : TextFolding.fold(t)
            }
            person = query.person.flatMap { FoldedPattern($0) }
            app = query.appName.flatMap { $0.nonEmptyTrimmed }.map { TextFolding.fold($0) }
            from = query.from
            to = query.to
            starredOnly = query.starredOnly
        }

        func accepts(_ entry: LibraryEntry) -> Bool {
            let s = entry.summary
            if starredOnly && !s.starred { return false }
            if let from, s.startedAt < from { return false }
            if let to, s.startedAt > to { return false }
            if let folder, !LibraryNaming.folder(entry.folder.lowercased(), isInside: folder) { return false }
            if let tag, !entry.tagKeys.contains(tag) { return false }
            if let app, !entry.appKeys.contains(app) { return false }
            if let person, !entry.personKeys.contains(where: { key in
                var name = key
                return name.withUTF8 { person.firstMatch(in: $0) } != nil
            }) { return false }
            return true
        }
    }

    // MARK: Scoring

    /// Field weights are 100 apart and the term bonus is at most 60, so the field decides first
    /// (title > tags > notes > bookmark > summary > transcript), then the share of terms matched.
    /// What the user wrote ranks above what OpenAI wrote, which ranks above a passing mention.
    static func baseScore(_ field: SearchField) -> Double {
        switch field {
        case .title: return 600
        case .tags: return 500
        case .notes: return 400
        case .bookmark: return 300
        case .summary: return 200
        case .transcript: return 100
        }
    }

    static func fieldOrder(_ field: SearchField) -> Int {
        switch field {
        case .title: return 0
        case .tags: return 1
        case .notes: return 2
        case .bookmark: return 3
        case .summary: return 4
        case .transcript: return 5
        }
    }

    static func score(_ field: SearchField, matched: Int, of total: Int) -> Double {
        baseScore(field) + 50 * Double(matched) / Double(max(1, total)) + Double(min(matched, 10))
    }

    // MARK: Matching

    /// A match before its snippet is built. Snippets are only made for the hits that are returned,
    /// so a query matching thousands of segments stays cheap.
    struct RawHit {
        let field: SearchField
        let mask: UInt64
        let matched: Int
        /// UTF-8 offset of the first match within the field's text.
        let offset: Int
        /// Index into `SearchDocument.segments` (transcript), `.bookmarks` (bookmark) or `.summary`.
        let index: Int?
        let time: Double?
        let score: Double
    }

    /// A raw hit with what global ordering needs.
    struct RankedHit {
        let raw: RawHit
        /// Index of the call in the candidate list.
        let call: Int
        let startedAt: Date
        let id: CallID
    }

    /// Every hit in the call, or nil when some term doesn't occur anywhere in it (terms are ANDed).
    static func match(_ entry: LibraryEntry, query: ParsedQuery) -> [RawHit]? {
        let patterns = query.patterns
        let doc = entry.document
        let all: UInt64 = patterns.count >= 64 ? ~0 : (UInt64(1) << UInt64(patterns.count)) - 1

        func scan(_ text: String) -> (mask: UInt64, first: Int) {
            var mask: UInt64 = 0
            var first = Int.max
            guard !text.isEmpty else { return (0, first) }
            var copy = text
            copy.withUTF8 { buffer in
                for (i, pattern) in patterns.enumerated() {
                    if let offset = pattern.firstMatch(in: buffer) {
                        mask |= UInt64(1) << UInt64(i)
                        first = min(first, offset)
                    }
                }
            }
            return (mask, first)
        }

        let title = scan(doc.title)
        let tags = scan(doc.tags)
        let notes = scan(doc.notes)
        let bookmarks = doc.bookmarks.map { scan($0.text) }
        let summary = doc.summary.map(scan)
        var found = title.mask | tags.mask | notes.mask
        for b in bookmarks { found |= b.mask }
        for s in summary { found |= s.mask }

        // Transcript: only the first match per segment and term is needed.
        let segments = doc.segments
        var segmentMasks = [UInt64](repeating: 0, count: segments.count)
        var segmentFirst = [Int](repeating: Int.max, count: segments.count)
        doc.transcript.withUnsafeBufferPointer { buffer in
            for (i, pattern) in patterns.enumerated() {
                let bit = UInt64(1) << UInt64(i)
                var position = 0
                var cursor = 0
                while let offset = pattern.firstMatch(in: buffer, from: position) {
                    while cursor < segments.count && Int(segments[cursor].upper) <= offset { cursor += 1 }
                    guard cursor < segments.count else { break }
                    segmentMasks[cursor] |= bit
                    segmentFirst[cursor] = min(segmentFirst[cursor], offset)
                    found |= bit
                    position = Int(segments[cursor].upper) + 1
                }
            }
        }
        guard found == all else { return nil }

        func raw(_ field: SearchField, _ mask: UInt64, _ offset: Int, index: Int? = nil, time: Double? = nil) -> RawHit {
            let matched = mask.nonzeroBitCount
            return RawHit(field: field, mask: mask, matched: matched, offset: offset, index: index, time: time,
                          score: score(field, matched: matched, of: patterns.count))
        }
        // One hit for a field made of several texts (hit ids are call + field + segment): the text
        // matching the most terms, earliest first, carries the snippet; the terms cover them all.
        func combined(_ matches: [(mask: UInt64, first: Int)]) -> (best: Int, mask: UInt64)? {
            var best: Int?
            var mask: UInt64 = 0
            for (i, match) in matches.enumerated() where match.mask != 0 {
                mask |= match.mask
                if best.map({ match.mask.nonzeroBitCount > matches[$0].mask.nonzeroBitCount }) ?? true { best = i }
            }
            return best.map { ($0, mask) }
        }
        var result: [RawHit] = []
        if title.mask != 0 { result.append(raw(.title, title.mask, title.first)) }
        if tags.mask != 0 { result.append(raw(.tags, tags.mask, tags.first)) }
        if notes.mask != 0 { result.append(raw(.notes, notes.mask, notes.first)) }
        if let hit = combined(bookmarks) {
            result.append(raw(.bookmark, hit.mask, bookmarks[hit.best].first, index: hit.best,
                              time: doc.bookmarks[hit.best].time))
        }
        if let hit = combined(summary) {
            result.append(raw(.summary, hit.mask, summary[hit.best].first, index: hit.best))
        }
        for (index, mask) in segmentMasks.enumerated() where mask != 0 {
            let segment = segments[index]
            result.append(raw(.transcript, mask, segmentFirst[index] - Int(segment.lower), index: index, time: segment.start))
        }
        return result
    }

    /// The full hit, with its snippet and matched terms.
    static func materialize(_ raw: RawHit, in entry: LibraryEntry, query: ParsedQuery) -> SearchHit {
        let doc = entry.document
        let s = entry.summary
        var terms: [String] = []
        for (i, pattern) in query.patterns.enumerated() where raw.mask & (UInt64(1) << UInt64(i)) != 0 {
            terms.append(pattern.display)
        }
        let text: String
        var segmentID: Int?
        var speaker: String?
        switch raw.field {
        case .title: text = doc.title
        case .tags: text = doc.tags
        case .notes: text = doc.notes
        case .bookmark: text = raw.index.map { doc.bookmarks[$0].text } ?? ""
        case .summary: text = raw.index.map { doc.summary[$0] } ?? ""
        case .transcript:
            if let index = raw.index {
                let segment = doc.segments[index]
                text = doc.text(of: segment)
                segmentID = segment.id
                speaker = doc.speakerName(of: segment)
            } else {
                text = ""
            }
        }
        return SearchHit(callID: s.id, title: s.title, startedAt: s.startedAt, field: raw.field, segmentID: segmentID,
                         time: raw.time, speakerName: speaker, snippet: Snippet.around(text, utf8Offset: raw.offset),
                         terms: terms, score: raw.score)
    }

    /// Best score first; ties: newer call first, then reading order inside the call.
    static func ordered(_ a: RankedHit, _ b: RankedHit) -> Bool {
        if a.raw.score != b.raw.score { return a.raw.score > b.raw.score }
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        if a.id != b.id { return a.id > b.id }
        return withinCall(a.raw, b.raw)
    }

    /// Order of hits inside one call: best first, then title, tags, notes, bookmarks, summary,
    /// transcript by time.
    static func withinCall(_ a: RawHit, _ b: RawHit) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let fa = fieldOrder(a.field), fb = fieldOrder(b.field)
        if fa != fb { return fa < fb }
        return (a.time ?? -1) < (b.time ?? -1)
    }

    /// The "list" hit used when the query has no text: one title hit per call.
    static func listingHit(for entry: LibraryEntry) -> SearchHit {
        let s = entry.summary
        return SearchHit(callID: s.id, title: s.title, startedAt: s.startedAt, field: .title,
                         snippet: s.preview.isEmpty ? s.title : s.preview, terms: [], score: 0)
    }

    /// Call-level score: its best hit, plus a little for every additional hit.
    static func callScore(_ hits: [RawHit]) -> Double {
        (hits.map(\.score).max() ?? 0) + min(Double(max(0, hits.count - 1)), 20) * 0.5
    }
}
