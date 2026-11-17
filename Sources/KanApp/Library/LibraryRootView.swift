import SwiftUI
import KanCore

/// Entry point of the "Kan Library" window: sidebar (Inbox, folders, tags, people, apps) · call list
/// (by day, or search results with highlighted snippets) · the selected call (transcript reader,
/// player, speakers, notes and bookmarks).
struct LibraryRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LibraryWindowContent(model: model)
    }
}

/// Owns the window-scoped state for as long as the window is open.
private struct LibraryWindowContent: View {
    let model: AppModel
    @State private var window: LibraryWindowModel
    @FocusState private var searchFocused: Bool
    private let sidebarWidth: CGFloat
    private let listWidth: CGFloat

    init(model: AppModel) {
        self.model = model
        _window = State(initialValue: LibraryWindowModel(app: model))
        sidebarWidth = Self.storedWidth(LibraryDefaults.sidebarWidth, default: 220, range: 180...360)
        listWidth = Self.storedWidth(LibraryDefaults.listWidth, default: 340, range: 280...560)
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(window: window)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
                .modifier(LibraryWidthRecorder(key: LibraryDefaults.sidebarWidth))
        } content: {
            LibraryCallList(window: window)
                .navigationSplitViewColumnWidth(min: 280, ideal: listWidth, max: 560)
                .modifier(LibraryWidthRecorder(key: LibraryDefaults.listWidth))
        } detail: {
            LibraryDetailColumn(window: window)
        }
        .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search calls")
        .searchFocused($searchFocused)
        .frame(minWidth: 980, idealWidth: 1280, minHeight: 640, idealHeight: 820)
        .background {
            LibraryShortcuts(shortcuts: [
                .init(title: "Search Calls", key: "f", modifiers: [.command, .option]) { searchFocused = true },
                .init(title: "Refresh Library", key: "r", modifiers: .command) { window.refresh() },
            ])
        }
        .onChange(of: model.summaries, initial: true) { window.summariesChanged() }
        .onChange(of: model.libraryFocus, initial: true) { _, request in
            guard let request else { return }
            window.handleFocusRequest(request)
            // Consumed: reopening the window must not jump to it again.
            model.libraryFocus = nil
        }
        // "Search calls…" in the menu (also when it opened this window).
        .onChange(of: model.librarySearchRequest, initial: true) { _, request in
            guard request != nil else { return }
            model.librarySearchRequest = nil
            focusSearchField()
        }
        .onAppear { window.windowOpened() }
        .onDisappear { window.windowClosed() }
        .alert(window.alert?.title ?? "", isPresented: alertShown, presenting: window.alert) { alert in
            if let confirmTitle = alert.confirmTitle {
                Button(confirmTitle, role: alert.isDestructive ? .destructive : nil) { window.confirm(alert) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        .overlay(alignment: .bottom) {
            LibraryToastView(toast: window.toast)
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { window.alert != nil }, set: { if !$0 { window.alert = nil } })
    }

    /// A window that is just opening adds the search field to its toolbar a moment after it
    /// appears, so focus again once it's there.
    private func focusSearchField() {
        searchFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            searchFocused = true
        }
    }

    private static func storedWidth(_ key: String, default value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let stored = CGFloat(UserDefaults.standard.double(forKey: key))
        return range.contains(stored) ? stored : value
    }
}

/// Remembers a split-view column's width (restored as its ideal width next time).
private struct LibraryWidthRecorder: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width > 0 else { return }
            UserDefaults.standard.set(Double(width.rounded()), forKey: key)
        }
    }
}

/// Keyboard shortcuts without a visible control: invisible buttons in the view hierarchy, active
/// while their view is.
struct LibraryShortcuts: View {
    struct Shortcut {
        var title: String
        var key: KeyEquivalent
        var modifiers: EventModifiers
        var action: () -> Void
    }

    let shortcuts: [Shortcut]

    var body: some View {
        ZStack {
            ForEach(shortcuts.indices, id: \.self) { index in
                let shortcut = shortcuts[index]
                Button(shortcut.title, action: shortcut.action)
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The detail column: one call, several, or nothing selected.
private struct LibraryDetailColumn: View {
    let window: LibraryWindowModel

    var body: some View {
        switch window.detailSelection {
        case .none:
            ContentUnavailableView("No Call Selected", systemImage: "text.bubble",
                                   description: Text("Select a call to read its transcript."))
        case .call(let id):
            LibraryCallDetail(callID: id, window: window)
                .id(id)
        case .multiple(let ids):
            LibraryMultipleSelection(ids: ids, window: window)
        }
    }
}

/// Bulk actions for several selected calls.
private struct LibraryMultipleSelection: View {
    let ids: [CallID]
    let window: LibraryWindowModel

    var body: some View {
        let summaries = ids.compactMap { window.summaryByID[$0] }
        let allStarred = !summaries.isEmpty && summaries.allSatisfy(\.starred)
        let total = summaries.reduce(0) { $0 + $1.duration }
        ContentUnavailableView {
            Label("\(ids.count) Calls Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text("\(KanTime.humanDuration(total)) of conversation.")
        } actions: {
            HStack {
                Button(allStarred ? "Unstar" : "Star") { window.setStarred(ids, !allStarred) }
                if summaries.contains(where: { !$0.labeled }) {
                    Button("Mark as Labeled") { window.markLabeled(ids) }
                }
                LibraryMoveMenu(ids: ids, window: window)
                    .fixedSize()
                Button("Delete…", role: .destructive) { window.requestDelete(ids) }
            }
        }
    }
}

/// A short confirmation at the bottom of the window ("Copied for AI").
private struct LibraryToastView: View {
    let toast: LibraryToast?

    var body: some View {
        ZStack {
            if let toast {
                Label(toast.message, systemImage: toast.systemImage)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .padding(.bottom, 64)
        .animation(.easeOut(duration: 0.2), value: toast)
        .allowsHitTesting(false)
    }
}
