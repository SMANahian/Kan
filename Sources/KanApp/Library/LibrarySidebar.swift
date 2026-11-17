import SwiftUI
import UniformTypeIdentifiers
import KanCore

/// The sidebar: Library (Inbox, All Calls, Starred, Processing), Folders (a tree with context menus;
/// calls can be dropped on a folder), Tags, People and Apps. The selection filters the call list.
struct LibrarySidebar: View {
    @Bindable var window: LibraryWindowModel

    var body: some View {
        let data = window.sidebar
        List(selection: $window.sidebarSelection) {
            Section("Library") {
                LibrarySidebarRow(title: "Inbox", count: data.counts.inbox) { Image(systemName: "tray") }
                    .tag(LibrarySidebarItem.inbox)
                    .help("Calls you haven't labeled yet")
                LibrarySidebarRow(title: "All Calls", count: data.counts.all) { Image(systemName: "square.stack") }
                    .tag(LibrarySidebarItem.all)
                LibrarySidebarRow(title: "Starred", count: data.counts.starred) { Image(systemName: "star") }
                    .tag(LibrarySidebarItem.starred)
                if data.counts.processing > 0 || window.sidebarSelection == .processing {
                    LibrarySidebarRow(title: "Processing", count: data.counts.processing) { Image(systemName: "waveform") }
                        .tag(LibrarySidebarItem.processing)
                        .help("Calls being recorded or transcribed")
                }
            }

            Section {
                LibrarySidebarRow(title: LibraryFilter.unfiledTitle, count: data.unfiledCount) { Image(systemName: "tray.full") }
                    .tag(LibrarySidebarItem.folder(""))
                    .help("Calls without a folder (stored in the Inbox folder of your library)")
                    .contextMenu {
                        Button("New Folder…") { window.promptNewFolder(parent: nil) }
                        Button("Reveal in Finder") { window.revealFolder("") }
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil) { window.handleDrop($0, toFolder: "") }
                ForEach(data.folders) { node in
                    LibraryFolderTreeRow(node: node, window: window)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        window.promptNewFolder(parent: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Folder")
                }
            }

            if !data.tags.isEmpty {
                Section("Tags") {
                    ForEach(data.tags) { tag in
                        LibrarySidebarRow(title: "#" + tag.name, count: tag.count) { Image(systemName: "number") }
                            .tag(LibrarySidebarItem.tag(tag.name))
                    }
                }
            }

            if !data.people.isEmpty {
                Section("People") {
                    ForEach(data.people) { person in
                        LibrarySidebarRow(title: person.name, count: person.count) { Image(systemName: "person") }
                            .tag(LibrarySidebarItem.person(person.name))
                    }
                }
            }

            if !data.apps.isEmpty {
                Section("Apps") {
                    ForEach(data.apps) { app in
                        LibrarySidebarRow(title: app.name, count: app.count) {
                            LibraryAppIcon(appName: app.isApp ? app.name : nil, platform: app.platform, size: 16)
                        }
                        .tag(LibrarySidebarItem.app(app.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: window.sidebarSelection) { window.sidebarSelectionChanged() }
        .alert(window.folderPrompt?.title ?? "", isPresented: promptShown, presenting: window.folderPrompt) { prompt in
            TextField("Folder name", text: $window.folderPromptText)
            Button(prompt.confirmTitle) { window.commitFolderPrompt(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { window.folderPrompt != nil }, set: { if !$0 { window.folderPrompt = nil } })
    }
}

/// A folder (count includes its subfolders) and, while expanded, its subfolders. Folders start
/// expanded; collapsing one is remembered.
private struct LibraryFolderTreeRow: View {
    let node: LibraryFolderNode
    let window: LibraryWindowModel

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { child in
                    // AnyView breaks the recursive opaque type.
                    AnyView(LibraryFolderTreeRow(node: child, window: window))
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        LibrarySidebarRow(title: node.name, count: node.totalCount) { Image(systemName: "folder") }
            .tag(LibrarySidebarItem.folder(node.path))
            .contextMenu {
                Button("New Folder Inside…") { window.promptNewFolder(parent: node.path) }
                Button("Rename…") { window.promptRenameFolder(node.path) }
                Button("Reveal in Finder") { window.revealFolder(node.path) }
                Divider()
                Button("Delete Folder…", role: .destructive) { window.requestDeleteFolder(node.path) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { window.handleDrop($0, toFolder: node.path) }
    }

    private var expanded: Binding<Bool> {
        Binding(get: { !window.collapsedFolders.contains(node.path) },
                set: { window.setFolder(node.path, expanded: $0) })
    }
}

/// A sidebar row: icon, title and a count badge.
private struct LibrarySidebarRow<Icon: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            icon()
        }
        .badge(count)
    }
}
