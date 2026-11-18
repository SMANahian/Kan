import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import KanCore

/// A row of the call list: a call, or one search hit inside a call.
enum LibraryListItem: Hashable {
    case call(CallID)
    /// `SearchHit.id` ("<call id>#<field>#<segment>").
    case hit(String)
}

/// What the detail column shows.
enum LibraryDetailSelection: Equatable {
    case none
    case call(CallID)
    case multiple([CallID])
}

/// A request for the transcript reader: go to a moment, highlight terms, take keyboard focus.
struct LibraryTranscriptFocus: Equatable {
    var callID: CallID
    var segmentID: Int?
    var time: Double?
    var play = false
    /// Text for find-in-transcript (the library search); nil leaves the find field alone.
    var findText: String?
    var focusTranscript = false
    var nonce = UUID()
}

/// Scrolls the call list to a row.
struct LibraryListScroll: Equatable {
    var item: LibraryListItem
    var nonce = UUID()
}

/// What a search's results belong to.
struct LibrarySearchKey: Equatable {
    var text: String
    var item: LibrarySidebarItem
    var revision: Int
}

/// Confirmations and error messages.
struct LibraryAlert: Identifiable {
    enum Kind {
        case message
        case deleteCalls([CallID])
        case deleteAudio(CallID)
        case deleteFolder(String)
        case mergeSpeakers(CallID, from: String, into: String)
        case removeSummary(CallID)
    }

    let id = UUID()
    var title: String
    var message: String
    var kind: Kind

    var confirmTitle: String? {
        switch kind {
        case .message: return nil
        case .deleteCalls(let ids): return ids.count == 1 ? "Delete Call" : "Delete \(ids.count) Calls"
        case .deleteAudio: return "Delete Audio"
        case .deleteFolder: return "Delete Folder"
        case .mergeSpeakers: return "Merge"
        case .removeSummary: return "Remove Summary"
        }
    }

    var isDestructive: Bool {
        switch kind {
        case .deleteCalls, .deleteAudio, .deleteFolder, .removeSummary: return true
        case .message, .mergeSpeakers: return false
        }
    }
}

/// The name prompt for new and renamed folders.
struct LibraryFolderPrompt: Identifiable {
    enum Mode: Equatable {
        /// A folder inside `parent` (nil = top level); afterwards `moving` calls move into it.
        case create(parent: String?, moving: [CallID])
        case rename(String)
    }

    let id = UUID()
    var mode: Mode

    var title: String {
        switch mode {
        case .create: return "New Folder"
        case .rename: return "Rename Folder"
        }
    }

    var confirmTitle: String {
        switch mode {
        case .create: return "Create"
        case .rename: return "Rename"
        }
    }

    var message: String {
        switch mode {
        case .create(let parent?, _) where !parent.isEmpty: return "Inside “\(parent)”."
        case .create: return "Folders are directories in your Kan library; use “/” for subfolders."
        case .rename(let path): return "Renaming “\(path)” moves its files on disk too."
        }
    }
}

struct LibraryToast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var systemImage: String
}

/// The sidebar's data derived from the library.
struct LibrarySidebarData {
    var counts = LibraryCounts()
    /// Calls without a folder (stored in the Inbox directory).
    var unfiledCount = 0
    var folders: [LibraryFolderNode] = []
    var folderMenu: [LibraryFolderMenuItem] = []
    var tags: [NamedCount] = []
    var people: [NamedCount] = []
    var apps: [LibraryAppEntry] = []
}

/// State and actions of one library window: sidebar selection, search, list selection, the audio
/// player, alerts and toasts. Main-actor only. Library reads that can take a while (search,
/// folders/tags/people, folder operations, reconciling) run on detached tasks — `LibraryStore` is
/// thread-safe — and their results are applied back on the main actor.
@MainActor
@Observable
final class LibraryWindowModel {
    static let hitsPerCall = 5
    static let maxSearchCalls = 300

    @ObservationIgnored let app: AppModel
    let player = LibraryPlayer()

    /// Restored from the last session.
    var sidebarSelection: LibrarySidebarItem? = UserDefaults.standard.string(forKey: LibraryDefaults.sidebarSelection)
        .flatMap(LibrarySidebarItem.init(storageKey:)) ?? .all
    var searchText = ""
    var listSelection: Set<LibraryListItem> = []

    /// Increments on every library change (re-runs the search, reloads the open call).
    private(set) var revision = 0
    private(set) var summaryByID: [CallID: CallSummary] = [:]
    private(set) var sidebar = LibrarySidebarData()
    private(set) var searchResults: [CallSearchResult] = []
    private(set) var hitsByID: [String: SearchHit] = [:]
    private(set) var isSearchRunning = false
    /// The text the current `searchResults` were found for.
    private(set) var searchedText: String?
    /// Sidebar folders the user collapsed (remembered; folders start expanded).
    private(set) var collapsedFolders = Set(UserDefaults.standard.stringArray(forKey: LibraryDefaults.collapsedFolders) ?? [])

    var transcriptFocus: LibraryTranscriptFocus?
    var listScroll: LibraryListScroll?
    var alert: LibraryAlert?
    var folderPrompt: LibraryFolderPrompt?
    var folderPromptText = ""
    private(set) var toast: LibraryToast?

    @ObservationIgnored private var sidebarGeneration = 0
    @ObservationIgnored private var programmaticSelection: Set<LibraryListItem>?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Derived state

    var selectedItem: LibrarySidebarItem { sidebarSelection ?? .all }

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isSearching: Bool { !trimmedSearch.isEmpty }

    var searchKey: LibrarySearchKey { LibrarySearchKey(text: trimmedSearch, item: selectedItem, revision: revision) }

    /// Selected calls (hits count as their call), newest first.
    var selectedCallIDs: [CallID] {
        var seen = Set<CallID>()
        var ids: [CallID] = []
        for item in listSelection {
            if let id = callID(for: item), seen.insert(id).inserted { ids.append(id) }
        }
        return ids.sorted { a, b in
            (summaryByID[a]?.startedAt ?? .distantPast) > (summaryByID[b]?.startedAt ?? .distantPast)
        }
    }

    var detailSelection: LibraryDetailSelection {
        let ids = selectedCallIDs
        switch ids.count {
        case 0: return .none
        case 1: return .call(ids[0])
        default: return .multiple(ids)
        }
    }

    func callID(for item: LibraryListItem) -> CallID? {
        switch item {
        case .call(let id):
            return id
        case .hit(let hitID):
            if let hit = hitsByID[hitID] { return hit.callID }
            let prefix = hitID.prefix { $0 != "#" }
            return prefix.isEmpty ? nil : CallID(rawValue: String(prefix))
        }
    }

    func callIDs(for items: Set<LibraryListItem>) -> [CallID] {
        var seen = Set<CallID>()
        return items.compactMap { callID(for: $0) }.filter { seen.insert($0).inserted }
    }

    /// The list's browse rows for the current sidebar selection (newest first).
    func browseSummaries(_ summaries: [CallSummary]) -> [CallSummary] {
        let item = selectedItem
        return item == .all ? summaries : summaries.filter { LibraryFilter.matches($0, item) }
    }

    var listTitle: String { selectedItem.title }

    // MARK: Library changes

    /// Call when `AppModel.summaries` changed (and once when the window opens).
    func summariesChanged() {
        let summaries = app.summaries
        revision += 1
        summaryByID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sidebar.counts = LibraryCounts(summaries)
        sidebar.apps = LibraryAppGrouping.entries(summaries)
        let missing = listSelection.filter { item in
            if case .call(let id) = item { return summaryByID[id] == nil && !app.library.contains(id) }
            return false
        }
        if !missing.isEmpty { listSelection.subtract(missing) }
        refreshSidebar()
    }

    /// Re-reads folders, tags and people from the library (off the main thread).
    func refreshSidebar() {
        sidebarGeneration += 1
        let generation = sidebarGeneration
        let library = app.library
        Task {
            let (folders, tags, people) = await Task.detached(priority: .userInitiated) {
                (library.folders(), library.tags(), library.people())
            }.value
            guard generation == sidebarGeneration else { return }
            let tree = LibraryFolderTree.build(folders)
            sidebar.folders = tree
            sidebar.folderMenu = LibraryFolderTree.flatten(tree)
            sidebar.unfiledCount = folders.first { $0.name.isEmpty }?.count ?? 0
            sidebar.tags = tags
            sidebar.people = people
            validateSidebarSelection(folders: folders, tags: tags, people: people)
        }
    }

    /// A selected folder, tag or person that no longer exists (restored from the last session, or
    /// its last call is gone) falls back to All Calls.
    private func validateSidebarSelection(folders: [FolderInfo], tags: [NamedCount], people: [NamedCount]) {
        let exists: Bool
        switch sidebarSelection {
        case .folder(let path)? where !path.isEmpty:
            exists = folders.contains { $0.name.caseInsensitiveCompare(path) == .orderedSame }
        case .tag(let tag)?:
            let key = LibraryFilter.tagKey(tag)
            exists = tags.contains { LibraryFilter.tagKey($0.name) == key }
        case .person(let name)?:
            let key = LibraryFilter.nameKey(name)
            exists = people.contains { LibraryFilter.nameKey($0.name) == key }
        default:
            exists = true
        }
        if !exists { sidebarSelection = .all }
    }

    /// The window appeared.
    func windowOpened() {
        #if DEBUG
        LibraryHelperChecks.runOnceAndLog()
        #endif
        refresh()
    }

    /// Re-reads the library from disk, picking up edits made outside Kan (agents, editors):
    /// `AppModel.reloadLibrary` reconciles the store off the main thread and refreshes the summaries.
    func refresh() {
        app.reloadLibrary()
        refreshSidebar()
    }

    func windowClosed() {
        player.unload()
    }

    // MARK: Search

    /// Runs the search for `key` after a short debounce; called from `.task(id:)`, which cancels a
    /// stale search when the text, the sidebar selection or the library changes.
    func runSearch(_ key: LibrarySearchKey) async {
        guard !key.text.isEmpty else {
            searchResults = []
            hitsByID = [:]
            isSearchRunning = false
            searchedText = nil
            return
        }
        isSearchRunning = true
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return
        }
        let item = key.item
        let query = LibraryFilter.searchQuery(text: key.text, item: item,
                                              limit: LibraryFilter.needsPostFiltering(item) ? 0 : Self.maxSearchCalls)
        let library = app.library
        let hitsPerCall = Self.hitsPerCall
        let found = await Task.detached(priority: .userInitiated) {
            library.searchCalls(query, hitsPerCall: hitsPerCall)
        }.value
        guard !Task.isCancelled else { return }
        let results = Array(found.lazy.filter { LibraryFilter.matches($0.summary, item) }.prefix(Self.maxSearchCalls))
        searchResults = results
        hitsByID = Dictionary(results.flatMap(\.hits).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        isSearchRunning = false
        searchedText = key.text
        let stale = listSelection.filter { item in
            if case .hit(let id) = item { return hitsByID[id] == nil }
            return false
        }
        if !stale.isEmpty { listSelection.subtract(stale) }
    }

    // MARK: Selection & focus

    /// The list selection changed: a search hit opens its call at the hit; a call found by the search
    /// highlights the search terms in its transcript. Any older, unconsumed request is dropped.
    func listSelectionChanged(to selection: Set<LibraryListItem>) {
        if let programmatic = programmaticSelection {
            programmaticSelection = nil
            if programmatic == selection { return }
        }
        transcriptFocus = nil
        guard selection.count == 1, let item = selection.first, let id = callID(for: item) else { return }
        let findText = isSearching ? trimmedSearch : nil
        switch item {
        case .hit(let hitID):
            guard let hit = hitsByID[hitID] else { return }
            transcriptFocus = LibraryTranscriptFocus(callID: id, segmentID: hit.segmentID, time: hit.time, findText: findText)
        case .call:
            if let findText { transcriptFocus = LibraryTranscriptFocus(callID: id, findText: findText) }
        }
    }

    /// The sidebar selection changed: remember it, and while browsing drop selected calls the new
    /// filter hides.
    func sidebarSelectionChanged() {
        UserDefaults.standard.set(selectedItem.storageKey, forKey: LibraryDefaults.sidebarSelection)
        guard !isSearching else { return }
        let item = selectedItem
        let hidden = listSelection.filter { entry in
            guard let id = callID(for: entry) else { return true }
            return summaryByID[id].map { !LibraryFilter.matches($0, item) } ?? false
        }
        if !hidden.isEmpty { listSelection.subtract(hidden) }
    }

    /// The detail took `focus` over (it keeps it until its call has loaded).
    func consumeTranscriptFocus(_ focus: LibraryTranscriptFocus) {
        if transcriptFocus?.nonce == focus.nonce { transcriptFocus = nil }
    }

    func setFolder(_ path: String, expanded: Bool) {
        if expanded {
            collapsedFolders.remove(path)
        } else {
            collapsedFolders.insert(path)
        }
        UserDefaults.standard.set(collapsedFolders.sorted(), forKey: LibraryDefaults.collapsedFolders)
    }

    /// Return or double-click on rows: open the transcript (and play from a hit's moment).
    func open(_ items: Set<LibraryListItem>) {
        guard items.count == 1, let item = items.first, let id = callID(for: item) else { return }
        let findText = isSearching ? trimmedSearch : nil
        if case .hit(let hitID) = item, let hit = hitsByID[hitID], let time = hit.time {
            transcriptFocus = LibraryTranscriptFocus(callID: id, segmentID: hit.segmentID, time: time, play: true,
                                                     findText: findText, focusTranscript: true)
        } else {
            transcriptFocus = LibraryTranscriptFocus(callID: id, findText: findText, focusTranscript: true)
        }
    }

    /// `AppModel.libraryFocus`: select the call (making its row visible) and seek, playing when a
    /// time is given.
    func handleFocusRequest(_ request: LibraryFocusRequest) {
        let id = request.callID
        if isSearching { searchText = "" }
        if let summary = summaryByID[id], !LibraryFilter.matches(summary, selectedItem) { sidebarSelection = .all }
        show(id, focus: LibraryTranscriptFocus(callID: id, time: request.time, play: request.time != nil))
        listScroll = LibraryListScroll(item: .call(id))
    }

    /// Selects one call and hands `focus` to its detail (without the selection change replacing it).
    func show(_ id: CallID, focus: LibraryTranscriptFocus?) {
        let selection: Set<LibraryListItem> = [.call(id)]
        if listSelection != selection {
            programmaticSelection = selection
            listSelection = selection
        }
        transcriptFocus = focus
    }

    /// Selects a call (e.g. the "Recording now" card).
    func select(_ id: CallID) {
        listSelection = [.call(id)]
        listScroll = LibraryListScroll(item: .call(id))
    }

    // MARK: Call actions

    func setStarred(_ ids: [CallID], _ starred: Bool) {
        for id in ids { app.update(id, markLabeled: false) { $0.starred = starred } }
    }

    func markLabeled(_ ids: [CallID]) {
        for id in ids { app.update(id, markLabeled: true) { _ in } }
    }

    func move(_ ids: [CallID], toFolder folder: String) {
        guard !ids.isEmpty else { return }
        guard let target = LibraryStore.sanitizeFolder(folder) else {
            showError("Invalid folder name", "“\(folder)” can't be used as a folder name.")
            return
        }
        for id in ids { app.update(id) { $0.folder = target } }
        let name = target.isEmpty ? LibraryFilter.unfiledTitle : target
        showToast(ids.count == 1 ? "Moved to “\(name)”" : "Moved \(ids.count) calls to “\(name)”", systemImage: "folder")
    }

    /// `AppModel.copyForAI` confirms with its own notice.
    func copyForAI(_ id: CallID, template: PromptTemplate) {
        app.copyForAI(id, template: template)
    }

    func reveal(_ id: CallID) {
        app.revealInFinder(id)
    }

    /// Asks where to save, then writes `AppModel.exportData` there.
    func export(_ id: CallID, format: ExportFormat) {
        let fileName: String
        if let record = try? app.library.record(id) {
            fileName = TranscriptRenderer.suggestedFileName(for: record, format: format)
        } else {
            fileName = (summaryByID[id]?.title ?? "Kan call") + "." + format.fileExtension
        }
        let panel = NSSavePanel()
        panel.title = "Export \(format.displayName)"
        panel.prompt = "Export"
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.writeExport(id, format: format, to: url) }
        }
    }

    private func writeExport(_ id: CallID, format: ExportFormat, to url: URL) {
        do {
            let data = try app.exportData(id, format: format)
            try data.write(to: url, options: .atomic)
            showToast("Exported “\(url.lastPathComponent)”", systemImage: "square.and.arrow.up")
        } catch {
            // Not the destination: its file name is the call's title.
            KanLog.error("Export of \(id) as \(format.rawValue) failed: \(AppModel.logDescription(error))",
                         category: "library-ui")
            showError("Couldn't export the call", error.localizedDescription, log: false)
        }
    }

    func requestDelete(_ ids: [CallID]) {
        guard !ids.isEmpty else { return }
        let what = ids.count == 1
            ? "“\(summaryByID[ids[0]]?.title ?? "This call")” — its transcript, notes, bookmarks and audio —"
            : "\(ids.count) calls — their transcripts, notes, bookmarks and audio —"
        alert = LibraryAlert(title: ids.count == 1 ? "Delete this call?" : "Delete \(ids.count) calls?",
                             message: "\(what) will be deleted from this Mac. This can't be undone.",
                             kind: .deleteCalls(ids))
    }

    func requestDeleteAudio(_ id: CallID) {
        let title = summaryByID[id]?.title ?? "this call"
        alert = LibraryAlert(title: "Delete the audio?",
                             message: "The recording of “\(title)” will be deleted. The transcript stays, but you won't be "
                                 + "able to play the call or transcribe it again.",
                             kind: .deleteAudio(id))
    }

    func requestRemoveSummary(_ id: CallID) {
        alert = LibraryAlert(title: "Remove the summary?",
                             message: "OpenAI's summary of “\(summaryByID[id]?.title ?? "this call")” is removed from the call's "
                                 + "files. Writing it again sends the transcript to OpenAI again.",
                             kind: .removeSummary(id))
    }

    func requestMerge(_ callID: CallID, from: Speaker, into: Speaker) {
        alert = LibraryAlert(title: "Merge “\(from.name)” into “\(into.name)”?",
                             message: "Everything “\(from.name)” said in this call will be attributed to “\(into.name)”.",
                             kind: .mergeSpeakers(callID, from: from.id, into: into.id))
    }

    /// The user confirmed `alert`.
    func confirm(_ alert: LibraryAlert) {
        switch alert.kind {
        case .message:
            break
        case .deleteCalls(let ids):
            for id in ids {
                if player.callID == id { player.unload() }
                app.deleteCall(id, deleteAudio: true)
            }
            listSelection = listSelection.filter { item in callID(for: item).map { !ids.contains($0) } ?? true }
        case .deleteAudio(let id):
            if player.callID == id { player.unload() }
            app.deleteAudio(id)
            showToast("Audio deleted", systemImage: "trash")
        case .deleteFolder(let path):
            deleteFolder(path)
        case .mergeSpeakers(let callID, let from, let into):
            app.mergeSpeakers(callID, from: from, into: into)
        case .removeSummary(let id):
            app.removeSummary(id)
            showToast("Summary removed", systemImage: "trash")
        }
    }

    /// Shows (and by default logs) a user-visible failure. Only the title is logged: messages name
    /// folders and calls, and the log outlives them.
    func showError(_ title: String, _ message: String, log: Bool = true) {
        if log { KanLog.warning(title, category: "library-ui") }
        // An alert can't be presented while another (e.g. the folder name prompt) is closing.
        guard alert == nil && folderPrompt == nil else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.alert = LibraryAlert(title: title, message: message, kind: .message)
            }
            return
        }
        alert = LibraryAlert(title: title, message: message, kind: .message)
    }

    func showToast(_ message: String, systemImage: String = "checkmark.circle") {
        let toast = LibraryToast(message: message, systemImage: systemImage)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    // MARK: Drag and drop

    /// A call dragged out of the list carries its Markdown file: Finder, editors and AI apps get the
    /// transcript; dropping it on a sidebar folder moves the call.
    func dragItem(for summary: CallSummary) -> NSItemProvider {
        if !summary.markdownPath.isEmpty {
            let url = app.library.root.appendingPathComponent(summary.markdownPath)
            if let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = url.lastPathComponent
                return provider
            }
        }
        return NSItemProvider(object: summary.title as NSString)
    }

    /// Files dropped on a sidebar folder: Kan calls of this library (their .md or .json) move there.
    func handleDrop(_ providers: [NSItemProvider], toFolder folder: String) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.moveDroppedFile(url, toFolder: folder) }
            }
        }
        return true
    }

    private func moveDroppedFile(_ url: URL, toFolder folder: String) {
        let root = app.library.root
        let path = url.standardizedFileURL.path
        let match = summaryByID.values.first { summary in
            [summary.markdownPath, summary.jsonPath].contains { relative in
                !relative.isEmpty && root.appendingPathComponent(relative).standardizedFileURL.path == path
            }
        }
        guard let match else {
            showToast("Only calls from your Kan library can be moved into its folders", systemImage: "exclamationmark.circle")
            return
        }
        if match.folder != folder { move([match.id], toFolder: folder) }
    }

    // MARK: Folders

    func promptNewFolder(parent: String?, moving: [CallID] = []) {
        folderPromptText = ""
        folderPrompt = LibraryFolderPrompt(mode: .create(parent: parent, moving: moving))
    }

    func promptRenameFolder(_ path: String) {
        folderPromptText = LibraryFolderTree.name(of: path)
        folderPrompt = LibraryFolderPrompt(mode: .rename(path))
    }

    func commitFolderPrompt(_ prompt: LibraryFolderPrompt) {
        let name = folderPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch prompt.mode {
        case .create(let parent, let moving):
            guard let folder = LibraryStore.sanitizeFolder(LibraryFolderTree.join(parent, name)), !folder.isEmpty else {
                showError("Invalid folder name", "“\(name)” can't be used as a folder name.")
                return
            }
            performFolderOperation("Couldn't create the folder", { try $0.createFolder(folder) }) { [weak self] in
                guard let self else { return }
                if moving.isEmpty {
                    sidebarSelection = .folder(folder)
                } else {
                    move(moving, toFolder: folder)
                }
            }
        case .rename(let path):
            guard let target = LibraryStore.sanitizeFolder(LibraryFolderTree.join(LibraryFolderTree.parent(of: path), name)),
                  !target.isEmpty else {
                showError("Invalid folder name", "“\(name)” can't be used as a folder name.")
                return
            }
            guard target != path else { return }
            performFolderOperation("Couldn't rename the folder", { try $0.renameFolder(path, to: target) }) { [weak self] in
                guard let self else { return }
                if case .folder(let selected)? = sidebarSelection, LibraryFolderTree.folder(selected, isInside: path) {
                    sidebarSelection = .folder(LibraryFolderTree.renamed(selected, from: path, to: target))
                }
            }
        }
    }

    func requestDeleteFolder(_ path: String) {
        let count = summaryByID.values.filter { LibraryFolderTree.folder($0.folder, isInside: path) }.count
        let calls = count == 0 ? "It has no calls." : "Its \(LibraryFormat.count(count, "call")) move to the Inbox."
        alert = LibraryAlert(title: "Delete the folder “\(LibraryFolderTree.name(of: path))”?",
                             message: "\(calls) Files that aren't Kan calls stay where they are on disk.",
                             kind: .deleteFolder(path))
    }

    private func deleteFolder(_ path: String) {
        performFolderOperation("Couldn't delete the folder", { try $0.deleteFolder(path) }) { [weak self] in
            guard let self else { return }
            if case .folder(let selected)? = sidebarSelection, LibraryFolderTree.folder(selected, isInside: path) {
                sidebarSelection = .all
            }
        }
    }

    func revealFolder(_ path: String) {
        let library = app.library
        if let url = library.directoryURL(forFolder: path), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([library.root])
        }
    }

    /// Runs a folder operation off the main thread (renaming rewrites every call inside), then `done`
    /// on success or an error alert, and refreshes the sidebar either way.
    private func performFolderOperation(_ failureTitle: String, _ operation: @escaping @Sendable (LibraryStore) throws -> Void,
                                        done: @escaping @MainActor () -> Void) {
        let library = app.library
        Task {
            let failure: (message: String, logged: String)? = await Task.detached(priority: .userInitiated) {
                do {
                    try operation(library)
                    return nil
                } catch {
                    return (error.localizedDescription, AppModel.logDescription(error))
                }
            }.value
            if let failure {
                KanLog.error("\(failureTitle): \(failure.logged)", category: "library-ui")
                showError(failureTitle, failure.message, log: false)
            } else {
                done()
            }
            refreshSidebar()
        }
    }
}
