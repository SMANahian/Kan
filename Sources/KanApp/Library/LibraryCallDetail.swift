import AppKit
import SwiftUI
import KanCore

/// The selected call: header (title with OpenAI's ideas, folder, tags, star, metadata), status
/// banner, speakers, OpenAI's summary, transcript reader and player, with notes and bookmarks in
/// the inspector.
struct LibraryCallDetail: View {
    let callID: CallID
    let window: LibraryWindowModel
    @Environment(AppModel.self) private var model
    @State private var detail: LibraryCallDetailModel
    @AppStorage(LibraryDefaults.showInspector) private var showInspector = true
    @FocusState private var findFocused: Bool

    init(callID: CallID, window: LibraryWindowModel) {
        self.callID = callID
        self.window = window
        _detail = State(initialValue: LibraryCallDetailModel(callID: callID, window: window))
    }

    var body: some View {
        content
            .inspector(isPresented: $showInspector) {
                LibraryInspector(detail: detail, player: window.player)
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
            }
            .toolbar { toolbar }
            .background {
                LibraryShortcuts(shortcuts: [
                    .init(title: "Find in Transcript", key: "f", modifiers: .command) { findFocused = true },
                    .init(title: "Find Next", key: "g", modifiers: .command) { detail.findNext() },
                    .init(title: "Find Previous", key: "g", modifiers: [.command, .shift]) { detail.findPrevious() },
                    .init(title: "Copy for AI", key: "c", modifiers: [.command, .shift]) { copyForAI() },
                    .init(title: "Show Notes & Bookmarks", key: "i", modifiers: [.command, .option]) { showInspector.toggle() },
                    .init(title: "Bigger Text", key: "=", modifiers: .command) { detail.setFontSize(detail.fontSize + 1) },
                    .init(title: "Smaller Text", key: "-", modifiers: .command) { detail.setFontSize(detail.fontSize - 1) },
                ])
            }
            .task { await detail.start() }
            .onChange(of: window.revision) { detail.reload() }
            // Every save of this call, also those that leave the list row as it was (OpenAI's
            // title ideas or summary arriving).
            .onChange(of: model.recordRevisions[callID]) { detail.reload() }
            .onChange(of: window.transcriptFocus, initial: true) { _, focus in
                guard let focus, focus.callID == callID else { return }
                detail.apply(focus)
                window.consumeTranscriptFocus(focus)
            }
            .onDisappear { detail.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch detail.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView("This Call Is No Longer in the Library", systemImage: "questionmark.folder",
                                   description: Text("It was deleted or moved out of the library folder."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open This Call", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { detail.reload() }
            }
        case .loaded:
            VStack(spacing: 0) {
                LibraryCallHeader(detail: detail, window: window)
                LibraryStatusBannerView(detail: detail)
                LibrarySpeakersBar(detail: detail)
                LibrarySummarySection(detail: detail)
                Divider()
                LibraryTranscriptReader(detail: detail, player: window.player)
                Divider()
                LibraryPlayerBar(player: window.player)
            }
            // One surface with the transcript, like a document.
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            LibraryFindField(detail: detail, focused: $findFocused)
        }
        ToolbarItem {
            Menu {
                ForEach(model.settings.promptTemplates) { template in
                    Button(template.name) { window.copyForAI(callID, template: template) }
                }
            } label: {
                Label("Copy for AI", systemImage: "sparkles")
            } primaryAction: {
                copyForAI()
            }
            .help("Copy the transcript with a prompt for your AI assistant (⇧⌘C)")
            .disabled(detail.record == nil)
        }
        ToolbarItem {
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.displayName + "…") { window.export(callID, format: format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the transcript")
            .disabled(detail.record == nil)
        }
        ToolbarItem {
            Menu {
                ForEach(LanguageMode.allCases, id: \.self) { mode in
                    Button {
                        detail.retranscribe(mode)
                    } label: {
                        if detail.record?.languageMode == mode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
                Divider()
                Text("The current transcript stays until the new one is ready.")
            } label: {
                Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
            }
            .help(detail.canRetranscribe ? "Transcribe this call again" : "The audio is no longer available")
            .disabled(!detail.canRetranscribe)
        }
        ToolbarItem {
            Button {
                window.reveal(callID)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show the transcript files in Finder")
            .disabled(detail.record == nil)
        }
        ToolbarItem {
            Menu {
                if detail.record?.labeled == false {
                    Button("Mark as Labeled") { detail.markLabeled() }
                    Divider()
                }
                Button("Open Transcript in Default App") { openMarkdown() }
                Button("Copy Transcript File Path") { copyMarkdownPath() }
                Divider()
                Button("Delete Audio…") { window.requestDeleteAudio(callID) }
                    .disabled(!detail.canRetranscribe)
                Button("Delete Call…", role: .destructive) { window.requestDelete([callID]) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
            .disabled(detail.record == nil)
        }
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Notes & Bookmarks", systemImage: "sidebar.right")
            }
            .help("Show or hide notes and bookmarks (⌥⌘I)")
        }
    }

    private func copyForAI() {
        guard detail.record != nil, let template = model.settings.promptTemplates.first else { return }
        window.copyForAI(callID, template: template)
    }

    private func openMarkdown() {
        guard let url = model.library.files(for: callID)?.markdown else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyMarkdownPath() {
        guard let url = model.library.files(for: callID)?.markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        window.showToast("Copied the file path", systemImage: "doc.on.doc")
    }
}

/// Find in transcript: the field, "3 of 12", previous / next (⇧⌘G / ⌘G). Return goes to the next
/// match, Esc clears and returns to the transcript.
private struct LibraryFindField: View {
    let detail: LibraryCallDetailModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 4) {
            TextField("Find in transcript", text: Binding(get: { detail.findQuery }, set: { detail.setFindQuery($0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused(focused)
                .onSubmit { detail.findNext() }
                .onExitCommand {
                    detail.clearFind()
                    focused.wrappedValue = false
                    detail.focusTranscript()
                }
                .help("Find in this transcript (⌘F)")
            if !detail.findQuery.isEmpty {
                Text(detail.findStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    detail.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Previous match (⇧⌘G)")
                .disabled(detail.findState.ranges.isEmpty)
                Button {
                    detail.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Next match (⌘G)")
                .disabled(detail.findState.ranges.isEmpty)
            }
        }
    }
}

/// Recording / queued / transcribing / failed, with Cancel or Retry.
struct LibraryStatusBannerView: View {
    let detail: LibraryCallDetailModel
    @Environment(AppModel.self) private var model

    var body: some View {
        if let record = detail.record,
           let banner = LibraryCallStatus.banner(status: record.status, processing: model.processing[record.id],
                                                 hasTranscript: !record.segments.isEmpty, error: record.processing?.error) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol(banner.kind))
                    .font(.title3)
                    .foregroundStyle(tint(banner.kind))
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.title)
                        .font(.callout.weight(.semibold))
                    if let text = banner.detail {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    if banner.kind == .transcribing {
                        if let progress = banner.progress {
                            ProgressView(value: progress)
                                .frame(maxWidth: 320)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 320)
                        }
                    }
                }
                Spacer()
                if let progress = banner.progress {
                    Text(LibraryFormat.percent(progress))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if banner.canRetry {
                    Button("Retry") { detail.retranscribe(nil) }
                        .disabled(!detail.canRetranscribe)
                        .help(detail.canRetranscribe ? "Transcribe this call again" : "The audio is no longer available")
                }
                if banner.canCancel {
                    Button("Cancel") { detail.cancelProcessing() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(tint(banner.kind).opacity(0.08))
        }
    }

    private func symbol(_ kind: LibraryStatusBanner.Kind) -> String {
        switch kind {
        case .recording: return "record.circle.fill"
        case .queued: return "clock"
        case .paused: return "pause.circle"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func tint(_ kind: LibraryStatusBanner.Kind) -> Color {
        switch kind {
        case .recording: return .red
        case .failed: return .orange
        case .transcribing: return .accentColor
        case .queued, .paused, .cancelled: return .secondary
        }
    }
}
