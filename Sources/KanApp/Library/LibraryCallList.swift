import SwiftUI
import KanCore

/// The middle column: the calls of the sidebar selection grouped by day, or — while searching — the
/// matching calls (best first), each followed by its hits with highlighted snippets.
struct LibraryCallList: View {
    @Bindable var window: LibraryWindowModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let key = window.searchKey
        ScrollViewReader { proxy in
            Group {
                if window.isSearching {
                    searchResults
                } else {
                    browseList
                }
            }
            .onChange(of: window.listScroll) { _, scroll in
                guard let scroll else { return }
                proxy.scrollTo(scroll.item, anchor: .center)
            }
        }
        .navigationTitle(window.isSearching ? "Search" : window.listTitle)
        .navigationSubtitle(subtitle)
        .task(id: key) { await window.runSearch(key) }
        .onChange(of: window.listSelection) { _, selection in
            window.listSelectionChanged(to: selection)
        }
    }

    private var subtitle: String {
        if window.isSearching {
            let hits = window.searchResults.reduce(0) { $0 + $1.totalHits }
            return window.isSearchRunning && window.searchResults.isEmpty
                ? "Searching…"
                : "\(LibraryFormat.count(window.searchResults.count, "call")) · \(LibraryFormat.count(hits, "match", "matches"))"
        }
        return LibraryFormat.count(window.browseSummaries(model.summaries).count, "call")
    }

    // MARK: Browse

    private var browseList: some View {
        let summaries = window.browseSummaries(model.summaries)
        let sections = LibraryDayGrouping.sections(summaries, date: \.startedAt)
        let userName = model.settings.effectiveUserName
        let live = showsLiveCard ? model.liveCall : nil
        return List(selection: $window.listSelection) {
            if let live {
                LibraryRecordingNowRow(live: live) {
                    if window.summaryByID[live.id] != nil || model.library.contains(live.id) { window.select(live.id) }
                }
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { summary in
                        LibraryCallRow(summary: summary, userName: userName)
                            .tag(LibraryListItem.call(summary.id))
                            .id(LibraryListItem.call(summary.id))
                            .onDrag { window.dragItem(for: summary) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: LibraryListItem.self) { items in
            LibraryCallMenu(ids: window.callIDs(for: items), window: window)
        } primaryAction: { items in
            window.open(items)
        }
        .onDeleteCommand { window.requestDelete(window.selectedCallIDs) }
        .onKeyPress(.return) {
            guard !window.listSelection.isEmpty else { return .ignored }
            window.open(window.listSelection)
            return .handled
        }
        .onKeyPress(.space) {
            guard window.player.isReady, window.detailSelection != .none else { return .ignored }
            window.player.togglePlay()
            return .handled
        }
        .overlay {
            if summaries.isEmpty && live == nil { emptyState }
        }
    }

    private var showsLiveCard: Bool {
        switch window.selectedItem {
        case .all, .inbox, .processing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch window.selectedItem {
        case .all:
            ContentUnavailableView("Kan is listening for calls", systemImage: "ear",
                                   description: Text("Your transcripts will appear here."))
        case .inbox:
            ContentUnavailableView("No Unlabeled Calls", systemImage: "tray",
                                   description: Text("New calls wait here until you label them."))
        case .starred:
            ContentUnavailableView("No Starred Calls", systemImage: "star",
                                   description: Text("Star the calls with ideas worth coming back to."))
        case .processing:
            ContentUnavailableView("Nothing to Transcribe", systemImage: "waveform",
                                   description: Text("Calls being recorded or transcribed show up here."))
        case .folder(let path):
            ContentUnavailableView("No Calls in “\(path.isEmpty ? LibraryFilter.unfiledTitle : path)”", systemImage: "folder",
                                   description: Text("Move calls here with “Move to Folder” or by dragging them onto the folder."))
        case .tag, .person, .app:
            ContentUnavailableView("No Calls", systemImage: "tray", description: Text("Nothing matches this filter."))
        }
    }

    // MARK: Search

    private var searchResults: some View {
        let results = window.searchResults
        let terms = LibraryTextMatch.terms(in: window.trimmedSearch)
        let userName = model.settings.effectiveUserName
        return List(selection: $window.listSelection) {
            ForEach(results) { result in
                Section {
                    LibraryCallRow(summary: result.summary, userName: userName, highlightTerms: terms, showsDate: true)
                        .tag(LibraryListItem.call(result.id))
                        .id(LibraryListItem.call(result.id))
                        .onDrag { window.dragItem(for: result.summary) }
                    ForEach(result.hits.filter { $0.field != .title }) { hit in
                        LibraryHitRow(hit: hit, terms: hit.terms.isEmpty ? terms : hit.terms)
                            .tag(LibraryListItem.hit(hit.id))
                            .id(LibraryListItem.hit(hit.id))
                    }
                    if result.totalHits > result.hits.count {
                        Button("\(result.totalHits - result.hits.count) more in this call") {
                            window.show(result.id, focus: LibraryTranscriptFocus(callID: result.id, findText: window.trimmedSearch,
                                                                                 focusTranscript: true))
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.leading, 34)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: LibraryListItem.self) { items in
            LibraryCallMenu(ids: window.callIDs(for: items), window: window)
        } primaryAction: { items in
            window.open(items)
        }
        .onDeleteCommand { window.requestDelete(window.selectedCallIDs) }
        .onKeyPress(.return) {
            guard !window.listSelection.isEmpty else { return .ignored }
            window.open(window.listSelection)
            return .handled
        }
        .overlay {
            if results.isEmpty {
                if window.searchedText == window.trimmedSearch && !window.isSearchRunning {
                    ContentUnavailableView.search(text: window.trimmedSearch)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Rows

/// A call in the list: app icon, title (bold while unlabeled), time and duration, people, tags,
/// status badge.
struct LibraryCallRow: View {
    let summary: CallSummary
    let userName: String
    var highlightTerms: [String] = []
    /// Search results aren't grouped by day, so they show the date.
    var showsDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LibraryAppIcon(appName: summary.appName, platform: summary.platform, size: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LibraryHighlightedText(text: summary.title, terms: highlightTerms)
                        .fontWeight(summary.labeled ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if summary.starred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
                    LibraryStatusBadge(callID: summary.id, status: summary.status)
                }
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let people = LibraryFilter.otherPeople(in: summary, userName: userName)
                if !people.isEmpty || !summary.tags.isEmpty {
                    // People first (they get the room); then as many tags as fit nicely.
                    let shownTags = people.isEmpty ? 3 : 2
                    HStack(spacing: 6) {
                        if !people.isEmpty {
                            Label(people.joined(separator: ", "), systemImage: "person.2")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        ForEach(summary.tags.prefix(shownTags), id: \.self) { tag in
                            LibraryTagChip(tag: tag)
                        }
                        if summary.tags.count > shownTags {
                            Text("+\(summary.tags.count - shownTags)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
                if highlightTerms.isEmpty, !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        var parts: [String] = []
        if showsDate { parts.append(summary.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        parts.append(LibraryFormat.timeRange(summary.startedAt, summary.endedAt))
        parts.append(KanTime.humanDuration(summary.duration))
        parts.append(LibraryFormat.appLabel(appName: summary.appName, platform: summary.platform))
        return parts.joined(separator: " · ")
    }
}

/// One search hit under its call: where it matched, the snippet with the terms highlighted, and
/// the speaker and time for transcript hits.
struct LibraryHitRow: View {
    let hit: SearchHit
    let terms: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                LibraryHighlightedText(text: hit.snippet, terms: terms)
                    .font(.callout)
                    .lineLimit(3)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch hit.field {
        case .title: return "textformat"
        case .tags: return "number"
        case .notes: return "note.text"
        case .bookmark: return "bookmark"
        case .transcript: return "text.quote"
        }
    }

    private var caption: String {
        let time = hit.time.map { "[\(KanTime.hms($0))]" }
        switch hit.field {
        case .title: return "Title"
        case .tags: return "Tags"
        case .notes: return "Notes"
        case .bookmark: return ["Bookmark", time].compactMap { $0 }.joined(separator: " · ")
        case .transcript: return [hit.speakerName ?? "Transcript", time].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// The call currently being recorded, on top of the list.
private struct LibraryRecordingNowRow: View {
    let live: LiveCall
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: live.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.title3)
                    .foregroundStyle(live.isPaused ? Color.secondary : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.isPaused ? "Recording paused" : "Recording now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(live.isPaused ? Color.secondary : Color.red)
                    Text(title)
                        .lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(KanTime.compact(context.date.timeIntervalSince(live.startedAt)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The call being recorded")
    }

    private var title: String {
        let trimmed = live.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(live.appName) call" : trimmed
    }
}

/// A status capsule: Recording / Queued / Paused / 42% / Failed.
struct LibraryStatusBadge: View {
    let callID: CallID
    let status: CallStatus
    @Environment(AppModel.self) private var model

    var body: some View {
        if let badge = LibraryCallStatus.badge(status: status, processing: model.processing[callID]) {
            Text(badge.label)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(color(badge))
                .background(Capsule().fill(color(badge).opacity(0.15)))
                .accessibilityLabel("Status: \(badge.label)")
        }
    }

    private func color(_ badge: LibraryCallBadge) -> Color {
        switch badge {
        case .recording: return .red
        case .failed: return .orange
        case .transcribing: return .accentColor
        case .queued, .paused: return .secondary
        }
    }
}

/// Text with the search terms highlighted (the library's matching rules, whole characters).
struct LibraryHighlightedText: View {
    let text: String
    let terms: [String]

    var body: some View {
        Text(Self.attributed(text, terms: terms))
    }

    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        guard !terms.isEmpty else { return AttributedString(text) }
        let ranges = LibraryTextMatch.ranges(of: terms, in: text)
        guard !ranges.isEmpty else { return AttributedString(text) }
        var out = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound { out += AttributedString(String(text[cursor..<range.lowerBound])) }
            var match = AttributedString(String(text[range]))
            match.backgroundColor = Color.yellow.opacity(0.4)
            match.inlinePresentationIntent = .stronglyEmphasized
            out += match
            cursor = range.upperBound
        }
        if cursor < text.endIndex { out += AttributedString(String(text[cursor...])) }
        return out
    }
}

/// "#tag" capsule, optionally with a remove button.
struct LibraryTagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text("#" + tag)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove #\(tag)")
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Menus

/// The context menu of one or several calls.
struct LibraryCallMenu: View {
    let ids: [CallID]
    let window: LibraryWindowModel
    @Environment(AppModel.self) private var model

    var body: some View {
        if ids.count == 1, let id = ids.first {
            let summary = window.summaryByID[id]
            Button("Open") { window.open([.call(id)]) }
            Divider()
            Button(summary?.starred == true ? "Unstar" : "Star") { window.setStarred([id], !(summary?.starred ?? false)) }
            if summary?.labeled == false {
                Button("Mark as Labeled") { window.markLabeled([id]) }
            }
            LibraryMoveMenu(ids: ids, window: window, current: summary?.folder)
            Divider()
            Menu("Copy for AI") {
                ForEach(model.settings.promptTemplates) { template in
                    Button(template.name) { window.copyForAI(id, template: template) }
                }
            }
            Menu("Export") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.displayName + "…") { window.export(id, format: format) }
                }
            }
            Button("Reveal in Finder") { window.reveal(id) }
            Divider()
            Button("Delete…", role: .destructive) { window.requestDelete(ids) }
        } else if ids.count > 1 {
            let allStarred = ids.allSatisfy { window.summaryByID[$0]?.starred == true }
            Button(allStarred ? "Unstar \(ids.count) Calls" : "Star \(ids.count) Calls") { window.setStarred(ids, !allStarred) }
            if ids.contains(where: { window.summaryByID[$0]?.labeled == false }) {
                Button("Mark as Labeled") { window.markLabeled(ids) }
            }
            LibraryMoveMenu(ids: ids, window: window)
            Divider()
            Button("Delete \(ids.count) Calls…", role: .destructive) { window.requestDelete(ids) }
        }
    }
}

/// "Move to Folder ▸": Unfiled, every folder (indented), New Folder….
struct LibraryMoveMenu: View {
    let ids: [CallID]
    let window: LibraryWindowModel
    /// The calls' current folder (checked), when there is a single one.
    var current: String?

    var body: some View {
        Menu("Move to Folder") {
            folderToggle(path: "", title: LibraryFilter.unfiledTitle)
            if !window.sidebar.folderMenu.isEmpty { Divider() }
            ForEach(window.sidebar.folderMenu) { item in
                folderToggle(path: item.path, title: String(repeating: "\u{2003}", count: item.depth) + item.name)
            }
            Divider()
            Button("New Folder…") { window.promptNewFolder(parent: nil, moving: ids) }
        }
    }

    private func folderToggle(path: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { current.map { $0.caseInsensitiveCompare(path) == .orderedSame } ?? false },
            set: { isOn in if isOn { window.move(ids, toFolder: path) } }))
    }
}
