import SwiftUI
import KanCore

/// The top of a call: app icon, editable title (saved on Return or when the field loses focus; Esc
/// reverts), star, the metadata line, folder menu and tags.
struct LibraryCallHeader: View {
    @Bindable var detail: LibraryCallDetailModel
    let window: LibraryWindowModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let record = detail.record {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    LibraryAppIcon(appName: record.source.appName, bundleID: record.source.bundleID,
                                   platform: record.source.platform, size: 30)
                    TextField("Title", text: $detail.titleDraft)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit {
                            detail.commitTitle()
                            titleFocused = false
                        }
                        .onExitCommand {
                            detail.revertTitle()
                            titleFocused = false
                        }
                        .help("Click to rename the call")
                    Button {
                        detail.toggleStar()
                    } label: {
                        Image(systemName: record.starred ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(record.starred ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(record.starred ? "Unstar" : "Star — worth coming back to")
                    .accessibilityLabel(record.starred ? "Unstar" : "Star")
                }
                Text(metadata(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(window.summaryByID[record.id].map { "Saved as \($0.markdownPath)" } ?? "")
                if let line = processingLine(record) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    LibraryFolderPicker(folder: record.folder, window: window) { folder in
                        detail.setFolder(folder)
                    } onNewFolder: {
                        window.promptNewFolder(parent: nil, moving: [record.id])
                    }
                    LibraryTagsEditor(tags: record.tags, suggestions: window.sidebar.tags) { tags in
                        detail.setTags(tags)
                    }
                    Spacer(minLength: 0)
                    if !record.labeled {
                        Button("Mark as Labeled") { detail.markLabeled() }
                            .controlSize(.small)
                            .help("Done labeling: take it out of the Inbox")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .onChange(of: titleFocused) { _, focused in
                if focused {
                    detail.isEditingTitle = true
                } else if detail.isEditingTitle {
                    detail.commitTitle()
                }
            }
        }
    }

    private func metadata(_ record: CallRecord) -> String {
        var parts = [
            LibraryFormat.longDate(record.startedAt),
            LibraryFormat.timeRange(record.startedAt, record.endedAt),
            KanTime.humanDuration(record.duration),
            LibraryFormat.appLabel(appName: record.source.appName, platform: record.source.platform),
        ]
        if !record.languages.isEmpty { parts.append(LibraryFormat.languages(record.languages)) }
        if let zone = TimeZone(identifier: record.timeZone), zone.secondsFromGMT(for: record.startedAt)
            != TimeZone.current.secondsFromGMT(for: record.startedAt) {
            let local = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
            let zoneName = zone.abbreviation(for: record.startedAt) ?? zone.identifier
            parts.append("\(record.startedAt.formatted(local)) \(zoneName) there")
        }
        return parts.joined(separator: " · ")
    }

    private func processingLine(_ record: CallRecord) -> String? {
        guard let info = record.processing, !info.modelsUsed.isEmpty else { return nil }
        var line = "Transcribed on this Mac with " + info.modelsUsed.joined(separator: ", ")
        if let seconds = info.processingSeconds, seconds > 0 { line += " in " + KanTime.humanDuration(seconds) }
        return line
    }
}

/// The folder menu: Unfiled, every folder (indented, current one checked), New Folder….
private struct LibraryFolderPicker: View {
    let folder: String
    let window: LibraryWindowModel
    let onSelect: (String) -> Void
    let onNewFolder: () -> Void

    var body: some View {
        Menu {
            toggle(path: "", title: LibraryFilter.unfiledTitle)
            if !window.sidebar.folderMenu.isEmpty { Divider() }
            ForEach(window.sidebar.folderMenu) { item in
                toggle(path: item.path, title: String(repeating: "\u{2003}", count: item.depth) + item.name)
            }
            Divider()
            Button("New Folder…", action: onNewFolder)
        } label: {
            Label(folder.isEmpty ? LibraryFilter.unfiledTitle : folder, systemImage: folder.isEmpty ? "tray" : "folder")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Folder")
    }

    private func toggle(path: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { folder.caseInsensitiveCompare(path) == .orderedSame },
            set: { isOn in if isOn { onSelect(path) } }))
    }
}

/// Tag chips with remove buttons and a field that suggests the library's tags while typing.
/// Commas separate several tags; "#" is optional.
private struct LibraryTagsEditor: View {
    let tags: [String]
    let suggestions: [NamedCount]
    let onChange: ([String]) -> Void
    @State private var input = ""

    var body: some View {
        LibraryFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(tags, id: \.self) { tag in
                LibraryTagChip(tag: tag) { onChange(tags.filter { $0 != tag }) }
            }
            TextField(tags.isEmpty ? "Add tags" : "Add tag", text: $input)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 100)
                .onSubmit(add)
                .disabled(tags.count >= LibraryFilter.maxTags)
                .textInputSuggestions {
                    ForEach(matches) { tag in
                        Text("#" + tag.name)
                            .textInputCompletion(tag.name)
                    }
                }
                .help(tags.count >= LibraryFilter.maxTags
                      ? "A call can have up to \(LibraryFilter.maxTags) tags"
                      : "Add tags (separate several with commas)")
        }
    }

    private var matches: [NamedCount] {
        let key = LibraryFilter.tagKey(input)
        guard !key.isEmpty else { return [] }
        let used = Set(tags.map(LibraryFilter.tagKey))
        return Array(suggestions.lazy.filter { tag in
            let tagKey = LibraryFilter.tagKey(tag.name)
            return !used.contains(tagKey) && tagKey.hasPrefix(key)
        }.prefix(8))
    }

    private func add() {
        let added = LibraryFilter.parseTags(input, existing: tags)
        input = ""
        guard !added.isEmpty else { return }
        onChange(tags + added)
    }
}

/// Lays its subviews out left to right, wrapping onto new lines.
struct LibraryFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
