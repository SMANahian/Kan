import Foundation

/// Searchable text of one call, kept in memory by `LibraryStore` (about the size of the
/// transcript text itself: segment texts share one UTF-8 buffer instead of one String each).
struct SearchDocument: Sendable {
    struct Segment: Sendable {
        let id: Int
        let start: Double
        let speaker: Int32          // index into `speakerNames`
        let lower: Int32            // byte range in `transcript`
        let upper: Int32
    }

    struct BookmarkText: Sendable {
        let time: Double
        let text: String
    }

    let title: String
    /// Tags joined with ", ".
    let tags: String
    let notes: String
    let bookmarks: [BookmarkText]
    let speakerNames: [String]
    /// Every visible segment's single-line NFC text, each followed by "\n" (so terms, which never
    /// contain a newline, can't match across segments).
    let transcript: [UInt8]
    let segments: [Segment]

    init(record: CallRecord) {
        title = record.title.nfc.singleLine
        tags = record.tags.map { $0.nfc.singleLine }.joined(separator: ", ")
        notes = record.notes.nfc.singleLine
        bookmarks = record.bookmarks
            .sorted { $0.time < $1.time }
            .compactMap { b in
                let text = b.note.nfc.singleLine
                return text.isEmpty ? nil : BookmarkText(time: b.time, text: text)
            }

        var names: [String] = []
        var nameIndex: [String: Int32] = [:]
        var buffer: [UInt8] = []
        var table: [Segment] = []
        for segment in record.visibleSegments(hidingEchoSuspects: true) {
            let text = segment.text.nfc.singleLine
            guard !text.isEmpty else { continue }
            let speaker: Int32
            if let existing = nameIndex[segment.speakerID] {
                speaker = existing
            } else {
                speaker = Int32(names.count)
                nameIndex[segment.speakerID] = speaker
                names.append(record.speakerName(segment.speakerID))
            }
            let lower = Int32(buffer.count)
            buffer.append(contentsOf: text.utf8)
            table.append(Segment(id: segment.id, start: segment.start, speaker: speaker,
                                 lower: lower, upper: Int32(buffer.count)))
            buffer.append(0x0A)
        }
        speakerNames = names
        transcript = buffer
        segments = table
    }

    func text(of segment: Segment) -> String {
        String(decoding: transcript[Int(segment.lower)..<Int(segment.upper)], as: UTF8.self)
    }

    func speakerName(of segment: Segment) -> String {
        let i = Int(segment.speaker)
        return i < speakerNames.count ? speakerNames[i] : "Unknown speaker"
    }
}

/// A file that holds the same call id as the indexed one: a Finder duplicate ("… copy"), a sync
/// conflict ("… 2"), a copy in another folder, or what an interrupted rename left behind. It isn't
/// indexed, and it is removed when the call is deleted (so the call can't come back).
struct LibraryTwin: Sendable {
    var files: CallFiles
    var updatedAt: Date
    /// The file carries the name Kan gives its own record ("<date> <title>", maybe " (n)"),
    /// unlike a Finder duplicate or a sync conflict.
    var hasKanName: Bool
}

/// One call in the store's in-memory index.
struct LibraryEntry: Sendable {
    var summary: CallSummary
    var files: CallFiles
    /// Directory of the call files relative to the root (as found on disk).
    var directoryComponents: [String]
    /// File name without extension.
    var baseName: String
    /// The folder, derived from where the files are (the location wins over the JSON field).
    var folder: String
    /// Named people other than the user (for `people()` and index.md).
    var people: [String]
    /// Speaker names + attendees (single-line NFC), for the person filter.
    var personKeys: [String]
    /// Folded app name, platform id and platform display name, for the app filter.
    var appKeys: Set<String>
    /// The recorded app's bundle id (`CallSource.bundleID`), for `LibraryStore.recordedApps()`.
    var bundleID: String?
    var tagKeys: Set<String>
    var document: SearchDocument
    /// Pre-rendered index.md row and index.jsonl line.
    var indexRow: String
    var jsonLine: String
    /// The JSON file's modification stamp when it was indexed (detects edits made outside Kan).
    var stamp: FileOps.Stamp?
    /// `updatedAt` of the indexed version (detects saves of stale copies).
    var updatedAt: Date

    var id: CallID { summary.id }

    init(record: CallRecord, directoryComponents: [String], baseName: String, root: URL) {
        let directory = directoryComponents.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        let relativeDirectory = directoryComponents.map { $0 + "/" }.joined()
        files = CallFiles(
            markdown: directory.appendingPathComponent(baseName + "." + LibraryNaming.markdownExtension),
            json: directory.appendingPathComponent(baseName + "." + LibraryNaming.jsonExtension))
        self.directoryComponents = directoryComponents
        self.baseName = baseName
        folder = record.folder
        updatedAt = record.updatedAt
        summary = CallSummary(record: record,
                              markdownPath: relativeDirectory + baseName + "." + LibraryNaming.markdownExtension,
                              jsonPath: relativeDirectory + baseName + "." + LibraryNaming.jsonExtension)
        people = record.otherPeople
        personKeys = (record.speakers.map(\.name) + record.attendees).compactMap { $0.nonEmptyTrimmed?.singleLine }
        appKeys = Set([record.source.appName, record.source.platform.rawValue, record.source.platform.displayName]
            .compactMap { $0.nonEmptyTrimmed }
            .map { TextFolding.fold($0) })
        bundleID = record.source.bundleID?.nonEmptyTrimmed
        tagKeys = Set(record.tags.map { TextFolding.fold($0.nfc.singleLine) })
        document = SearchDocument(record: record)
        indexRow = LibraryIndexFiles.row(summary: summary, people: people)
        jsonLine = (try? JSONEncoder.kanCompact.encode(summary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
