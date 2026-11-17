import Foundation
import KanCore

/// What the sidebar has selected; it filters the call list (and the search).
enum LibrarySidebarItem: Hashable, Sendable {
    /// Calls the user hasn't labeled yet (wherever they are stored).
    case inbox
    case all
    case starred
    /// Recording, waiting for or undergoing transcription.
    case processing
    /// A library folder and its subfolders; "" is the calls without a folder (the Inbox directory).
    case folder(String)
    case tag(String)
    case person(String)
    /// An app or platform name ("Zoom", "Google Meet", "Zen").
    case app(String)

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .all: return "All Calls"
        case .starred: return "Starred"
        case .processing: return "Processing"
        case .folder(let path): return path.isEmpty ? LibraryFilter.unfiledTitle : LibraryFolderTree.name(of: path)
        case .tag(let tag): return "#" + tag
        case .person(let name): return name
        case .app(let name): return name
        }
    }

    /// A string form for preferences ("inbox", "folder:Research/Thesis", …).
    var storageKey: String {
        switch self {
        case .inbox: return "inbox"
        case .all: return "all"
        case .starred: return "starred"
        case .processing: return "processing"
        case .folder(let path): return "folder:" + path
        case .tag(let tag): return "tag:" + tag
        case .person(let name): return "person:" + name
        case .app(let name): return "app:" + name
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "inbox": self = .inbox
        case "all": self = .all
        case "starred": self = .starred
        case "processing": self = .processing
        default:
            guard let colon = storageKey.firstIndex(of: ":") else { return nil }
            let value = String(storageKey[storageKey.index(after: colon)...])
            switch storageKey[..<colon] {
            case "folder": self = .folder(value)
            case "tag" where !value.isEmpty: self = .tag(value)
            case "person" where !value.isEmpty: self = .person(value)
            case "app" where !value.isEmpty: self = .app(value)
            default: return nil
            }
        }
    }
}

/// The list's filters. They mirror `LibraryStore.search`'s filters so browsing and searching show the
/// same calls: folders include subfolders, tags/apps compare case-insensitively. People compare whole
/// names (the sidebar's people come from `LibraryStore.people()`). Pure and thread-safe.
enum LibraryFilter {
    static let unfiledTitle = "Unfiled"
    /// Tags per call, as in the post-call label panel (more stops being useful).
    static let maxTags = 7

    /// The call is being recorded, waits for or undergoes transcription.
    static func isActive(_ status: CallStatus) -> Bool {
        switch status {
        case .recording, .queued, .processing: return true
        case .ready, .failed: return false
        }
    }

    static func matches(_ summary: CallSummary, _ item: LibrarySidebarItem) -> Bool {
        switch item {
        case .all: return true
        case .inbox: return !summary.labeled
        case .starred: return summary.starred
        case .processing: return isActive(summary.status)
        case .folder(let path):
            return path.isEmpty ? summary.folder.isEmpty : LibraryFolderTree.folder(summary.folder, isInside: path)
        case .tag(let tag):
            let key = tagKey(tag)
            return !key.isEmpty && summary.tags.contains { tagKey($0) == key }
        case .person(let name):
            let key = nameKey(name)
            return !key.isEmpty && summary.speakerNames.contains { nameKey($0) == key }
        case .app(let name):
            return LibraryAppGrouping.matches(summary, app: name)
        }
    }

    /// The library query for a search inside `item`. Results still go through `matches` (the store
    /// has no "unlabeled"/"processing" filter and matches people by substring).
    static func searchQuery(text: String, item: LibrarySidebarItem, limit: Int) -> SearchQuery {
        var query = SearchQuery(text: text, limit: limit)
        switch item {
        case .all, .inbox, .processing: break
        case .starred: query.starredOnly = true
        case .folder(let path): query.folder = path
        case .tag(let tag): query.tag = tag
        case .person(let name): query.person = name
        case .app(let name): query.appName = name
        }
        return query
    }

    /// Whether `searchQuery` alone may return calls that `matches` rejects.
    static func needsPostFiltering(_ item: LibrarySidebarItem) -> Bool {
        switch item {
        case .inbox, .processing, .person: return true
        default: return false
        }
    }

    /// A tag without "#", single-spaced and folded: the identity the library uses for tags.
    static func tagKey(_ tag: String) -> String {
        var t = LibraryTextMatch.singleLine(tag.precomposedStringWithCanonicalMapping)
        while t.hasPrefix("#") { t.removeFirst() }
        return LibraryTextMatch.folded(t.trimmingCharacters(in: .whitespaces))
    }

    /// A person or app name, single-spaced and folded.
    static func nameKey(_ name: String) -> String {
        LibraryTextMatch.folded(LibraryTextMatch.singleLine(name))
    }

    /// Tags as typed into the tag field: split on commas, "#" and spaces trimmed, empty ones dropped,
    /// duplicates (ignoring case) of each other and of `existing` dropped, and no more than
    /// `maxTags` in all.
    static func parseTags(_ input: String, existing: [String] = []) -> [String] {
        var seen = Set(existing.map(tagKey))
        var out: [String] = []
        for part in input.split(separator: ",") where existing.count + out.count < maxTags {
            var tag = LibraryTextMatch.singleLine(String(part).precomposedStringWithCanonicalMapping)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tagKey(tag)).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    /// Other people on a call, for list rows: named speakers except the user and placeholders.
    static func otherPeople(in summary: CallSummary, userName: String) -> [String] {
        let me = nameKey(userName)
        var seen = Set<String>()
        var out: [String] = []
        for name in summary.speakerNames {
            let key = nameKey(name)
            guard !key.isEmpty, !Speaker.isDefaultName(name), key != "me", key != me,
                  seen.insert(key).inserted else { continue }
            out.append(LibraryTextMatch.singleLine(name))
        }
        return out
    }
}

/// An entry of the sidebar's "Apps" section.
struct LibraryAppEntry: Identifiable, Hashable {
    var id: String { LibraryFilter.nameKey(name) }
    /// What the filter matches: an app name ("Zen") or a platform's display name ("Google Meet").
    let name: String
    let count: Int
    /// The platform of the calls behind this entry (for an icon), when they agree.
    let platform: CallPlatform?
    /// True when `name` is an app (not only a platform name).
    let isApp: Bool
}

/// The "Apps" section, built from summaries. A call is listed under its app ("Zen") and, for known
/// meeting platforms, under the platform too ("Google Meet"), exactly as the library's app filter
/// matches (app name, platform id or platform display name). Pure and thread-safe.
enum LibraryAppGrouping {
    static func entries(_ summaries: [CallSummary]) -> [LibraryAppEntry] {
        struct Tally {
            var name: String
            var count = 0
            var platforms = Set<CallPlatform>()
            var isApp = false
        }
        var tallies: [String: Tally] = [:]
        for summary in summaries {
            var keysForCall = Set<String>()
            for (label, isApp) in labels(for: summary) {
                let key = LibraryFilter.nameKey(label)
                guard !key.isEmpty, keysForCall.insert(key).inserted else { continue }
                var tally = tallies[key] ?? Tally(name: label)
                tally.count += 1
                tally.platforms.insert(summary.platform)
                tally.isApp = tally.isApp || isApp
                tallies[key] = tally
            }
        }
        return tallies.values
            .map { LibraryAppEntry(name: $0.name, count: $0.count, platform: $0.platforms.count == 1 ? $0.platforms.first : nil,
                            isApp: $0.isApp) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// The library's app filter: `app` equals the call's app name, platform id or platform name.
    static func matches(_ summary: CallSummary, app: String) -> Bool {
        let key = LibraryFilter.nameKey(app)
        guard !key.isEmpty else { return false }
        return [summary.appName, summary.platform.rawValue, summary.platform.displayName]
            .contains { LibraryFilter.nameKey($0) == key }
    }

    /// The app name, then the platform's name for real meeting platforms (not "Browser call"/"Call").
    private static func labels(for summary: CallSummary) -> [(String, Bool)] {
        var labels: [(String, Bool)] = []
        let app = LibraryTextMatch.singleLine(summary.appName)
        if !app.isEmpty { labels.append((app, true)) }
        switch summary.platform {
        case .browser, .other: break
        default: labels.append((summary.platform.displayName, false))
        }
        return labels
    }
}

/// Badge counts of the sidebar's "Library" section.
struct LibraryCounts: Equatable {
    var all = 0
    var inbox = 0
    var starred = 0
    var processing = 0

    init(_ summaries: [CallSummary]) {
        all = summaries.count
        for summary in summaries {
            if !summary.labeled { inbox += 1 }
            if summary.starred { starred += 1 }
            if LibraryFilter.isActive(summary.status) { processing += 1 }
        }
    }

    init() {}
}
