import SwiftUI
import KanCore

/// The inspector: notes (saved automatically shortly after typing stops) and bookmarks (click the
/// time to go there; edit the note in place; delete).
struct LibraryInspector: View {
    let detail: LibraryCallDetailModel
    let player: LibraryPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            notes
            Divider()
                .padding(.vertical, 12)
            bookmarks
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.headline)
            TextEditor(text: Binding(get: { detail.notesDraft }, set: { detail.editNotes($0) }))
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if detail.notesDraft.isEmpty {
                        Text("What was this about? Ideas, follow-ups…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 120, idealHeight: 200, maxHeight: 320)
                .disabled(detail.record == nil)
        }
    }

    private var bookmarks: some View {
        let items = (detail.record?.bookmarks ?? []).sorted { $0.time < $1.time }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                Spacer()
                LibraryAddBookmarkButton(detail: detail, player: player)
            }
            if items.isEmpty {
                Text("Mark moments with “Bookmark Here” in the transcript’s menu, or add one where playback is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { bookmark in
                            LibraryBookmarkRow(bookmark: bookmark, detail: detail)
                        }
                    }
                }
            }
        }
    }
}

/// "+" — a bookmark where playback is (reads the playhead, so it is its own small view).
private struct LibraryAddBookmarkButton: View {
    let detail: LibraryCallDetailModel
    let player: LibraryPlayer

    var body: some View {
        Button {
            detail.addBookmark(at: player.isReady ? player.currentTime : 0)
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help(player.isReady ? "Add a bookmark at \(KanTime.hms(player.currentTime))" : "Add a bookmark")
        .disabled(detail.record == nil)
    }
}

private struct LibraryBookmarkRow: View {
    let bookmark: Bookmark
    let detail: LibraryCallDetailModel
    @State private var note: String
    @FocusState private var focused: Bool

    init(bookmark: Bookmark, detail: LibraryCallDetailModel) {
        self.bookmark = bookmark
        self.detail = detail
        _note = State(initialValue: bookmark.note)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                detail.jump(to: bookmark)
            } label: {
                Text(timeLabel)
                    .monospacedDigit()
            }
            .buttonStyle(.link)
            .help("Go to this moment")
            TextField("Add a note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(commit)
            Button {
                detail.deleteBookmark(bookmark.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete this bookmark")
            .accessibilityLabel("Delete bookmark at \(timeLabel)")
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: bookmark.note) { oldValue, newValue in
            // Focused but untouched, it follows too: leaving the field then writes nothing back.
            if !focused || note == oldValue { note = newValue }
        }
    }

    private var timeLabel: String {
        if let end = bookmark.endTime, end > bookmark.time {
            return "\(KanTime.hms(bookmark.time))–\(KanTime.hms(end))"
        }
        return KanTime.hms(bookmark.time)
    }

    private func commit() {
        if note != bookmark.note { detail.updateBookmark(bookmark.id, note: note) }
    }
}
