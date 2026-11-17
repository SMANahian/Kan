import AVFoundation
import SwiftUI
import KanCore

/// Plays a few seconds of one speaker from the call's audio (the label panel's ▶ buttons).
@MainActor
@Observable
private final class SamplePlayer {
    private(set) var playingKey: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func toggle(key: String, url: URL, start: Double, seconds: Double) {
        if playingKey == key {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.currentTime = max(0, min(start, max(0, player.duration - 0.2)))
            player.play()
            self.player = player
            playingKey = key
            stopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            KanLog.warning("Can't play \(url.lastPathComponent): \(error.localizedDescription)", category: "ui")
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingKey = nil
    }
}

/// Speaker colours shared by Kan's views (index = position among remote speakers).
private enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// The post-call label panel: title, folder, tags, a one-line note, star, language, transcription
/// status and — once the transcript is ready — the remote speakers to name.
///
/// Keys: Return = Save, ⌘Return = Save & open in the library, Esc = Later, ⌘1…⌘9 = one of the
/// nine most recent folders. Discard has no shortcut and its confirmation defaults to Cancel: the
/// panel is for typing, where ⌘⌫ means "delete to the start of the line" and Return means "done",
/// and deleting a call can't be undone.
///
/// The form is a `LabelDraft`: Save writes only what was changed here, so edits made to the same
/// call in the library window meanwhile survive.
struct LabelPanelView: View {
    let callID: CallID
    let panelID: AnyHashable

    @Environment(AppModel.self) private var model
    @State private var record: CallRecord?
    @State private var draft = LabelDraft()
    @State private var tagDraft = ""
    @State private var language: LanguageMode = .auto
    @State private var confirmingDiscard = false
    @State private var folderError: String?
    @State private var recentFolders: [String] = []
    @State private var player = SamplePlayer()
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title, folder, tags, notes, speaker(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            titleField
            folderField
            tagsField
            TextField("What was this about?", text: Binding(get: { draft.notes }, set: { draft.setNotes($0) }))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .notes)
            starAndLanguage
            if let record, Self.hasTranscript(record), !LabelDraft.remoteSpeakers(of: record).isEmpty {
                Divider()
                speakersSection(record)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: PanelStack.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .reportsPanelHeight(id: panelID)
        .onAppear(perform: load)
        .onChange(of: model.recordRevisions[callID]) { _, _ in refresh() }
        .onDisappear { player.stop() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ear")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Label this call").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.pendingLabels.count > 1 {
                Text("\(model.pendingLabels.count - 1) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var subtitle: String {
        guard let record else { return "" }
        let app = record.source.appName.isEmpty ? record.source.platform.displayName : record.source.appName
        return "\(app) · \(KanTime.humanDuration(record.duration)) · \(KanFormat.shortMoment(record.startedAt))"
    }

    private var titleField: some View {
        // Untouched, it shows the suggested title, which follows the names typed for the speakers.
        TextField("Title", text: Binding(get: { record.map(draft.title(for:)) ?? draft.typedTitle ?? "" },
                                         set: { draft.setTitle($0) }))
        .textFieldStyle(.roundedBorder)
        .font(.title3)
        .focused($focus, equals: .title)
    }

    private var folderField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("Inbox", text: Binding(get: { draft.folder }, set: { draft.setFolder($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .folder)
                    .onChange(of: draft.folder) { _, _ in folderError = nil }
                Menu {
                    Button("Inbox") { draft.setFolder("") }
                    if !recentFolders.isEmpty { Divider() }
                    ForEach(recentFolders, id: \.self) { name in
                        Button(name) { draft.setFolder(name) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a folder")
            }
            if let folderError {
                Text(folderError).font(.caption).foregroundStyle(.red)
            }
            let chips = folderChips
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(chips.enumerated()), id: \.element) { index, name in
                            Chip(text: name, hint: isTypingFolder ? nil : "⌘\(index + 1)", selected: draft.folder == name) {
                                draft.setFolder(name)
                            }
                        }
                    }
                }
            }
        }
        // ⌘1…⌘9 always pick the recent folders, even while typing.
        .background(folderShortcuts)
    }

    private var isTypingFolder: Bool {
        focus == .folder && !draft.folder.trimmingCharacters(in: .whitespaces).isEmpty
            && !recentFolders.contains(draft.folder)
    }

    /// Recent folders, or the folders matching what's typed ("type to create" when none match).
    private var folderChips: [String] {
        guard isTypingFolder else { return Array(recentFolders.prefix(9)) }
        let typed = draft.folder.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(recentFolders.filter { $0.lowercased().contains(typed) }.prefix(5))
    }

    private var folderShortcuts: some View {
        ZStack {
            ForEach(Array(recentFolders.prefix(9).enumerated()), id: \.element) { index, name in
                HiddenShortcut(KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)) {
                    draft.setFolder(name)
                }
            }
        }
    }

    private var tagsField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(draft.tags, id: \.self) { tag in
                            TagToken(text: tag) { draft.removeTag(tag) }
                        }
                        if draft.tags.count < AppModel.maxTags {
                            TextField(draft.tags.isEmpty ? "Tags (comma separated)" : "Add tag", text: $tagDraft)
                                .textFieldStyle(.plain)
                                .frame(minWidth: 110)
                                .focused($focus, equals: .tags)
                                .onSubmit(commitTagDraft)
                                .onChange(of: tagDraft) { _, value in
                                    if value.contains(",") { commitTagDraft() }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
            let suggestions = model.tagSuggestions(matching: tagDraft, excluding: draft.tags)
            if draft.tags.count < AppModel.maxTags && !suggestions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { tag in
                        Chip(text: "#" + tag, hint: nil, selected: false) {
                            draft.addTag(tag)
                            tagDraft = ""
                        }
                    }
                }
            } else if draft.tags.count >= AppModel.maxTags {
                Text("Up to \(AppModel.maxTags) tags").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var starAndLanguage: some View {
        HStack {
            Toggle(isOn: Binding(get: { draft.starred }, set: { draft.setStarred($0) })) {
                Label("Has a research idea", systemImage: draft.starred ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .tint(.yellow)
            .controlSize(.small)
            Spacer()
            Picker("Language", selection: Binding(get: { language }, set: { newValue in
                guard newValue != language else { return }
                language = newValue
                model.setLanguageMode(callID, newValue)
            })) {
                Text("Auto").tag(LanguageMode.auto)
                Text("বাংলা").tag(LanguageMode.bangla)
                Text("English").tag(LanguageMode.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Changing the language transcribes the call again")
        }
    }

    // MARK: Speakers

    private func speakersSection(_ record: CallRecord) -> some View {
        let speakers = LabelDraft.remoteSpeakers(of: record)
        let total = max(1, record.speakers.reduce(0) { $0 + $1.talkTime })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Who was on the call?").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                        speakerRow(speaker, index: index, share: speaker.talkTime / total, record: record)
                    }
                }
            }
            .frame(maxHeight: speakers.count > 3 ? 260 : nil)
        }
    }

    private func speakerRow(_ speaker: Speaker, index: Int, share: Double, record: CallRecord) -> some View {
        let id = speaker.id
        let typed = draft.speakerNames[id] ?? ""
        let suggestions = nameSuggestions(for: speaker, typed: typed)
        // A recognized voice is only a guess until the user confirms it (or types a name).
        let recognized = speaker.nameSource == .voiceprint
        let touched = draft.editedSpeakers.contains(id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(SpeakerPalette.color(index)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Speaker.defaultName(number: AppModel.speakerNumber(of: id, in: record)))
                        .font(.callout)
                    Text("\(KanTime.humanDuration(speaker.talkTime)) · \(Int((share * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 84, alignment: .leading)
                Button {
                    playSample(of: speaker, in: record)
                } label: {
                    Image(systemName: player.playingKey == id ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(sampleSource(for: speaker, in: record) == nil)
                .help("Play 5 seconds of this speaker")
                TextField("Name", text: Binding(get: { draft.speakerNames[id] ?? "" },
                                                set: { draft.setSpeakerName($0, for: id) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .speaker(id))
            }
            if !suggestions.isEmpty || (recognized && (!touched || typed.kanSingleLine == speaker.name)) {
                HStack(spacing: 4) {
                    if recognized && touched && typed.kanSingleLine == speaker.name {
                        Label("Confirmed", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if recognized && !touched {
                        Label("Recognized voice", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Chip(text: "Confirm", hint: nil, selected: false) { draft.confirmSpeaker(id) }
                            .help("This is \(speaker.name)"
                                  + (model.settings.rememberVoices ? ": saving also remembers this call's voice sample" : ""))
                    }
                    ForEach(suggestions, id: \.self) { name in
                        Chip(text: name == speaker.suggestedName ? "Sounds like \(name)" : name, hint: nil, selected: false) {
                            draft.setSpeakerName(name, for: id)
                        }
                    }
                }
                .padding(.leading, 101)
            }
            if model.settings.rememberVoices {
                Toggle("Remember voice", isOn: Binding(get: { draft.remembersVoice(of: id) },
                                                       set: { draft.setRememberVoice($0, for: id) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .padding(.leading, 101)
                    .help("Adds this call's sample when you save a name you typed, picked or confirmed")
            }
        }
    }

    private func nameSuggestions(for speaker: Speaker, typed: String) -> [String] {
        var names: [String] = []
        if let suggested = speaker.suggestedName, typed.isEmpty { names.append(suggested) }
        let taken = Set(draft.speakerNames.values.map { $0.lowercased() })
        names += model.peopleSuggestions(matching: typed).filter { !taken.contains($0.lowercased()) }
        return Array(names.kanUniquedCaseInsensitive().prefix(3))
    }

    /// The speaker's longest segment, from them.* (remote) or me.* (mic).
    private func sampleSource(for speaker: Speaker, in record: CallRecord) -> (url: URL, start: Double, seconds: Double)? {
        guard let segment = record.segments.filter({ $0.speakerID == speaker.id })
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
        let files = model.audioFiles(for: callID)
        guard let url = segment.channel == .me ? files.me : files.them else { return nil }
        return (url, segment.start, min(5, max(1, segment.end - segment.start + 0.3)))
    }

    private func playSample(of speaker: Speaker, in record: CallRecord) {
        guard let source = sampleSource(for: speaker, in: record) else { return }
        player.toggle(key: speaker.id, url: source.url, start: source.start, seconds: source.seconds)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            if confirmingDiscard {
                HStack {
                    Text("Delete this call and its audio?").font(.callout)
                    Spacer()
                    // Return and Esc both keep the call; only a click on Discard deletes it.
                    Button("Cancel") { confirmingDiscard = false }
                        .keyboardShortcut(.defaultAction)
                    Button("Discard", role: .destructive) {
                        player.stop()
                        model.discardCall(callID)
                    }
                    .help("Deletes the call, its transcript and its audio. This can't be undone.")
                }
                .background(HiddenShortcut(.cancelAction) { confirmingDiscard = false })
            } else {
                HStack {
                    // No keyboard shortcut: ⌘⌫ is "delete to the start of the line" in the fields above.
                    Button("Discard…", role: .destructive) { confirmingDiscard = true }
                        .help("Delete this call and its audio (asks first)")
                    Spacer()
                    Button("Later") { later() }
                        .keyboardShortcut(.cancelAction)
                        .help("Keep it in the Inbox unlabeled (Esc)")
                    Button("Save & Open") { save(openAfter: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("⌘Return")
                    Button("Save") { save(openAfter: false) }
                        .keyboardShortcut(tagEntryInProgress ? nil : .defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Return adds the typed tag instead of saving.
    private var tagEntryInProgress: Bool {
        focus == .tags && !tagDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var statusLine: some View {
        if let record {
            let status = model.processing[callID]
            HStack(spacing: 6) {
                switch record.status {
                case .recording, .queued:
                    ProgressView().controlSize(.small)
                    Text(model.liveCall != nil && model.queue?.isPaused == true
                         ? "Transcription starts after the current call" : "Waiting to transcribe…")
                case .processing:
                    ProgressView(value: status?.progress?.fraction ?? 0).frame(width: 60)
                    Text("Transcribing locally… \(KanFormat.percent(status?.progress?.fraction ?? 0))")
                    if let stage = status?.progress?.stage { Text("· \(stage.displayName)").foregroundStyle(.secondary) }
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(LabelDraft.remoteSpeakers(of: record).contains(where: \.hasDefaultName)
                         ? "Transcript ready — name the speakers" : "Transcript ready")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(record.processing?.error ?? "Transcription failed").lineLimit(2)
                    Button("Retry") { model.retranscribe(callID, languageMode: language) }
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func load() {
        recentFolders = model.recentFolders()
        guard let current = model.record(callID) else { return }
        record = current
        draft = LabelDraft(record: current)
        language = current.languageMode
        focus = .title
    }

    /// The record changed (transcript arrived, an edit in the library window…): untouched fields
    /// follow it, what the user changed here stays.
    private func refresh() {
        guard let current = model.record(callID) else { return }
        record = current
        draft.refresh(from: current)
        language = current.languageMode     // the picker applies its changes at once
    }

    private func commitTagDraft() {
        for part in tagDraft.split(separator: ",") { draft.addTag(String(part)) }
        tagDraft = ""
    }

    private func save(openAfter: Bool) {
        guard LibraryStore.sanitizeFolder(draft.folder) != nil else {
            folderError = "“\(draft.folder)” can't be a folder name."
            focus = .folder
            return
        }
        commitTagDraft()
        player.stop()
        model.saveLabel(callID, draft: draft)
        if openAfter && model.presentedLabel != callID { model.showInLibrary(callID) }
    }

    private func later() {
        player.stop()
        model.labelLater(callID, draft: draft)
    }

    private static func hasTranscript(_ record: CallRecord) -> Bool {
        !record.segments.isEmpty && (record.status == .ready || record.status == .processing)
    }
}

/// A keyboard shortcut without a visible control: an invisible button in the hierarchy, active
/// while its view is.
private struct HiddenShortcut: View {
    let shortcut: KeyboardShortcut
    let action: () -> Void

    init(_ shortcut: KeyboardShortcut, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(shortcut)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// A small selectable capsule (folder and tag suggestions).
private struct Chip: View {
    let text: String
    let hint: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                if let hint { Text(hint).foregroundStyle(.tertiary) }
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A tag in the tag field, with a remove button.
private struct TagToken: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("#" + text).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.18), in: Capsule())
    }
}
