import Foundation
import KanCore

// MARK: - Library actions

extension AppModel {
    /// Tags per call (Krisp's cap: more than 7 stops being useful).
    static let maxTags = 7

    /// Rescans the library and re-renders Markdown edited outside Kan (the library window calls this
    /// when it opens; the file-system watcher calls it after external changes).
    func reloadLibrary() {
        guard isStarted || startupTask == nil else { return }   // startup loads the library itself
        let library = self.library
        Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .utility) { try library.reconcile() }.value
                self?.libraryProblem = nil          // the folder can be read (again)
            } catch {
                self?.report("Couldn't reload the library", error: error, category: "library")
            }
            self?.refreshSummaries()
        }
    }

    func record(_ id: CallID) -> CallRecord? {
        do {
            return try library.record(id)
        } catch LibraryError.notFound {
            return nil
        } catch {
            KanLog.error("Couldn't read call \(id): \(Self.logDescription(error))", category: "library")
            return nil
        }
    }

    /// Read-modify-write through LibraryStore.update; marks the call labeled when `markLabeled`.
    func update(_ id: CallID, markLabeled: Bool = true, _ mutate: (inout CallRecord) -> Void) {
        applyUpdate(id, markLabeled: markLabeled, mutate)
    }

    /// `update`, returning the saved record (nil after an error, which is reported).
    @discardableResult
    func applyUpdate(_ id: CallID, markLabeled: Bool, _ mutate: (inout CallRecord) -> Void) -> CallRecord? {
        do {
            let saved = try library.update(id) { record in
                mutate(&record)
                if markLabeled { record.labeled = true }
            }
            if markLabeled, presentedLabel != id { pendingLabels.removeAll { $0 == id } }
            return saved
        } catch {
            report("Couldn't update the call", error: error, category: "library", log: "Couldn't update \(id)")
            return nil
        }
    }

    /// Save from the post-call label panel: first the speaker names the user changed (remembering
    /// their voices as chosen), then only the fields the user changed. Everything else keeps its
    /// stored value, so edits made meanwhile in the library window survive. Marks the call labeled.
    func saveLabel(_ id: CallID, draft: LabelDraft) {
        guard let current = record(id) else {
            closeLabel(id)
            return
        }
        // Before the renames: whether the title is still the automatic one depends on the old names.
        let edits = draft.edits(for: current)
        applySpeakerNames(id, from: draft, in: current, rememberVoices: true)
        saveLabel(id, edits: edits)
    }

    /// Save with every field given (each one replaces the stored value). Changing the language
    /// re-queues transcription.
    func saveLabel(_ id: CallID, title: String, folder: String, tags: [String], notes: String,
                   starred: Bool, languageMode: LanguageMode) {
        saveLabel(id, edits: LabelEdits(title: title, folder: folder, tags: tags, notes: notes, starred: starred,
                                        languageMode: languageMode))
    }

    /// Writes a label (nil fields keep the stored value) and marks the call labeled. An invalid
    /// folder is reported and the call stays where it is; changing the language re-queues
    /// transcription.
    func saveLabel(_ id: CallID, edits: LabelEdits) {
        guard let current = record(id) else {
            closeLabel(id)
            return
        }
        var cleanFolder: String?
        if let folder = edits.folder {
            cleanFolder = LibraryStore.sanitizeFolder(folder)
            if cleanFolder == nil {
                report("“\(folder)” can't be used as a folder name; the call stays in “\(current.folder.isEmpty ? "Inbox" : current.folder)”",
                       log: "Labeling \(id): the folder name can't be used; the call stays where it is")
            }
        }
        let cleanTags = edits.tags.map { Array(Self.cleanTags($0).prefix(Self.maxTags)) }
        let newLanguage = edits.languageMode.flatMap { $0 != current.languageMode ? $0 : nil }
        let saved = applyUpdate(id, markLabeled: true) { record in
            if let title = edits.title?.kanNonEmpty { record.title = title }
            if let cleanFolder { record.folder = cleanFolder }
            if let cleanTags { record.tags = cleanTags }
            if let notes = edits.notes { record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let starred = edits.starred { record.starred = starred }
            if let newLanguage { record.languageMode = newLanguage }
        }
        guard let saved else { return }     // keep the panel open; the error is in the menu
        if let newLanguage { requeueTranscription(id, languageMode: newLanguage) }
        KanLog.info("Labeled \(id) (\(saved.folder.isEmpty ? "Inbox" : "a folder"), \(saved.tags.count) tag(s))", category: "library")
        closeLabel(id)
    }

    /// The label panel's speaker names: renames only the speakers the user changed or confirmed.
    /// `rememberVoices` false never adds a voice sample.
    private func applySpeakerNames(_ id: CallID, from draft: LabelDraft, in record: CallRecord, rememberVoices: Bool) {
        for rename in draft.speakerRenames(in: record) {
            renameSpeaker(id, speakerID: rename.speakerID, to: rename.name,
                          rememberVoice: rememberVoices && rename.rememberVoice)
        }
    }

    /// Tags as stored: single-line, no leading "#", no duplicates (case-insensitive).
    static func cleanTags(_ tags: [String]) -> [String] {
        tags.map { tag -> String in
            var t = tag.kanSingleLine
            while t.hasPrefix("#") { t.removeFirst() }
            return t.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .kanUniquedCaseInsensitive()
    }

    /// "Later": keep it in the Inbox unlabeled and close the panel.
    func labelLater(_ id: CallID) {
        closeLabel(id)
    }

    /// "Later" (Esc) from the label panel: keeps the speaker names the user typed, but never
    /// remembers a voice — Later postpones, and Esc can land in the middle of a word — and never
    /// confirms names Kan recognized by itself. The call stays unlabeled in the Inbox.
    func labelLater(_ id: CallID, draft: LabelDraft) {
        if let current = record(id) { applySpeakerNames(id, from: draft, in: current, rememberVoices: false) }
        labelLater(id)
    }

    /// "Discard" from the label panel: delete the call and its audio.
    func discardCall(_ id: CallID) {
        deleteCall(id, deleteAudio: true)
        closeLabel(id)
    }

    func deleteCall(_ id: CallID, deleteAudio: Bool) {
        queue?.cancel(id)
        let directory = library.callDataDirectory(for: id)
        do {
            try library.delete(id, deleteAudio: deleteAudio)
        } catch {
            report("Couldn't delete the call", error: error, category: "library", log: "Couldn't delete \(id)")
            guard !library.contains(id) else { return }
        }
        processing[id] = nil
        if !deleteAudio, FileManager.default.fileExists(atPath: directory.path) {
            // Kept audio without a call: make sure crash recovery never resurrects it.
            FileManager.default.createFile(atPath: directory.appendingPathComponent(RecordingManifest.detachedMarkerName).path,
                                           contents: Data())
            RecordingManifest.remove(in: directory)
        }
        closeLabel(id)
    }

    func deleteAudio(_ id: CallID) {
        guard let current = record(id) else { return }
        // Whatever the queue is doing with it (the news may not have reached `processing` yet);
        // a no-op when it isn't queued or running.
        queue?.cancel(id)
        let directory = library.callDataDirectory(for: id)
        do {
            try deleteAudioFiles(in: directory)
        } catch {
            report("Couldn't delete the audio of “\(current.title)”", error: error, category: "library",
                   log: "Couldn't delete the audio of \(id)")
            return
        }
        Self.deleteVoiceSamples(in: directory, of: id)
        let deletedAt = environment.now()
        applyUpdate(id, markLabeled: false) { record in
            record.audio = AudioAssets(meFile: nil, themFile: nil, format: record.audio?.format ?? "m4a",
                                       sizeBytes: 0, deletedAt: deletedAt)
        }
        KanLog.info("Deleted the audio of \(id)", category: "library")
    }

    /// The voice samples of a call's speakers (embeddings.json, taken from its audio to remember a
    /// voice when a speaker is named) go when the audio goes: Delete Audio, audio retention.
    /// Failures are logged; the audio is gone either way.
    nonisolated static func deleteVoiceSamples(in directory: URL, of id: CallID) {
        do {
            try SpeakerEmbeddingsFile.delete(in: directory)
        } catch {
            KanLog.error("Couldn't delete the voice samples of \(id): \(logDescription(error))", category: "voiceprints")
        }
    }

    /// Raw and archived audio of one call (embeddings and session files stay; see
    /// `deleteVoiceSamples`).
    func deleteAudioFiles(in directory: URL) throws {
        if let archiver = services.archiver {
            try archiver.deleteAudio(in: directory)
            return
        }
        let fm = FileManager.default
        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    func renameSpeaker(_ callID: CallID, speakerID: String, to name: String, rememberVoice: Bool) {
        let newName = name.kanSingleLine
        var personID: String?
        if !newName.isEmpty, rememberVoice, settings.rememberVoices, speakerID != Speaker.meID {
            let embeddings = SpeakerEmbeddingsFile.read(in: library.callDataDirectory(for: callID))
            if let embedding = embeddings[speakerID] {
                do {
                    personID = try voiceprints.enroll(name: newName, embedding: embedding)
                    refreshRememberedVoices()
                    KanLog.info("Remembered a voice (from \(callID) \(speakerID))", category: "voiceprints")
                } catch {
                    report("Couldn't remember \(newName)'s voice", error: error, category: "voiceprints",
                           log: "Couldn't remember a voice (from \(callID) \(speakerID))")
                }
            } else {
                KanLog.info("No voice sample for \(speakerID) in \(callID); the voice isn't remembered", category: "voiceprints")
            }
        }
        let userName = settings.effectiveUserName
        applyUpdate(callID, markLabeled: false) { record in
            guard let i = record.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            if newName.isEmpty {
                // An empty name returns the speaker to its automatic name.
                record.speakers[i].name = record.speakers[i].isMe
                    ? userName : Speaker.defaultName(number: Self.speakerNumber(of: record.speakers[i].id, in: record))
                record.speakers[i].nameSource = .automatic
                record.speakers[i].personID = nil
            } else {
                record.speakers[i].name = newName
                record.speakers[i].nameSource = .user
                record.speakers[i].suggestedName = nil
                if let personID { record.speakers[i].personID = personID }
            }
        }
    }

    /// "s3" → 3; otherwise the speaker's position among the remote speakers.
    static func speakerNumber(of speakerID: String, in record: CallRecord) -> Int {
        if speakerID.hasPrefix("s"), let n = Int(speakerID.dropFirst()), n > 0 { return n }
        let remote = record.speakers.filter { !$0.isMe }
        return (remote.firstIndex { $0.id == speakerID } ?? remote.count) + 1
    }

    /// Reassign every segment of `from` to `into` and drop `from`.
    func mergeSpeakers(_ callID: CallID, from: String, into: String) {
        guard from != into, from != Speaker.meID else { return }
        applyUpdate(callID, markLabeled: false) { record in
            guard record.speaker(from) != nil, record.speaker(into) != nil else { return }
            for i in record.segments.indices where record.segments[i].speakerID == from {
                record.segments[i].speakerID = into
            }
            record.speakers.removeAll { $0.id == from }
            Self.recomputeTalkTime(&record)
        }
    }

    func reassignSegment(_ callID: CallID, segmentID: Int, to speakerID: String) {
        applyUpdate(callID, markLabeled: false) { record in
            guard record.speaker(speakerID) != nil,
                  let i = record.segments.firstIndex(where: { $0.id == segmentID }),
                  record.segments[i].speakerID != speakerID else { return }
            let previous = record.segments[i].speakerID
            record.segments[i].speakerID = speakerID
            // A remote speaker left without any speech is gone.
            if previous != Speaker.meID, !record.segments.contains(where: { $0.speakerID == previous }) {
                record.speakers.removeAll { $0.id == previous && !$0.isMe }
            }
            Self.recomputeTalkTime(&record)
        }
    }

    /// Talk time per speaker from the visible segments (echo suspects don't count).
    static func recomputeTalkTime(_ record: inout CallRecord) {
        var totals: [String: Double] = [:]
        for segment in record.segments where !segment.flags.contains(.echoSuspect) {
            totals[segment.speakerID, default: 0] += max(0, segment.end - segment.start)
        }
        for i in record.speakers.indices {
            record.speakers[i].talkTime = totals[record.speakers[i].id] ?? 0
        }
    }

    func retranscribe(_ id: CallID, languageMode: LanguageMode?) {
        guard let queue else { return }
        do {
            try queue.retranscribe(id, languageMode: languageMode, settings: settings)
        } catch {
            report("Couldn't transcribe the call again", error: error, category: "queue", log: "Couldn't transcribe \(id) again")
            postProblem("Kan can't transcribe this call again", message: Self.describe(error))
        }
    }

    /// The label panel's language picker: store the choice and transcribe again with it.
    func setLanguageMode(_ id: CallID, _ mode: LanguageMode) {
        guard let current = record(id), current.languageMode != mode else { return }
        applyUpdate(id, markLabeled: false) { $0.languageMode = mode }
        requeueTranscription(id, languageMode: mode)
    }

    /// Transcribe again in `languageMode`: replaces a queued request, restarts a running one.
    func requeueTranscription(_ id: CallID, languageMode: LanguageMode) {
        KanLog.info("Re-queueing \(id) in \(languageMode.rawValue)", category: "queue")
        retranscribe(id, languageMode: languageMode)
    }

    func cancelProcessing(_ id: CallID) {
        queue?.cancel(id)
    }

    /// Playable audio for a call (kept m4a, or the raw WAVs while still processing).
    func audioFiles(for id: CallID) -> (me: URL?, them: URL?) {
        let directory = library.callDataDirectory(for: id)
        func existing(_ name: String?) -> URL? {
            guard let name else { return nil }
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let assets = record(id)?.audio
        if let assets, assets.deletedAt != nil { return (nil, nil) }
        let me = existing(assets?.meFile) ?? existing(KanPaths.CallFile.meM4A) ?? existing(KanPaths.CallFile.meWAV)
        let them = existing(assets?.themFile) ?? existing(KanPaths.CallFile.themM4A) ?? existing(KanPaths.CallFile.themWAV)
        return (me, them)
    }

    /// Puts `TranscriptRenderer.aiPrompt` on the clipboard.
    func copyForAI(_ id: CallID, template: PromptTemplate) {
        guard let record = record(id) else { return }
        let prompt = TranscriptRenderer.aiPrompt(record, template: template, userName: settings.effectiveUserName)
        environment.copyToPasteboard(prompt)
        postInfo("Copied “\(record.title)” for AI", message: template.name, seconds: 2.5)
    }

    func exportData(_ id: CallID, format: ExportFormat) throws -> Data {
        let record = try library.record(id)
        return try TranscriptRenderer.render(record, format: format)
    }

    func revealInFinder(_ id: CallID) {
        guard let files = library.files(for: id) else { return }
        environment.revealInFinder([files.markdown])
    }

    /// Opens (and focuses) the library window on this call.
    func showInLibrary(_ id: CallID, at time: Double? = nil) {
        libraryFocus = LibraryFocusRequest(callID: id, time: time)
        openLibrary()
    }

    func openLibrary() {
        if let ui {
            ui.openLibrary()
        } else {
            KanLog.debug("openLibrary: no window router (headless)")
        }
    }

    func openSettings() {
        ui?.openSettings()
    }

    func openOnboarding() {
        ui?.openOnboarding()
    }

    /// "Search calls…": open the library with its search field focused (the window consumes
    /// `librarySearchRequest`).
    func searchCalls() {
        librarySearchRequest = UUID()
        openLibrary()
    }

    // MARK: Suggestions for the label panel

    /// Folders with the most recent call first (the Inbox excluded), then the rest by name.
    func recentFolders() -> [String] {
        var latest: [String: Date] = [:]
        // The store's current state: `summaries` refreshes asynchronously after a save.
        for summary in library.summaries() where !summary.folder.isEmpty {
            latest[summary.folder] = max(latest[summary.folder] ?? .distantPast, summary.startedAt)
        }
        let all = library.folders().map(\.name).filter { !$0.isEmpty }
        return all.sorted { a, b in
            let x = latest[a] ?? .distantPast, y = latest[b] ?? .distantPast
            return x != y ? x > y : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Library tags matching what's typed (most used first); the top tags when nothing is typed.
    func tagSuggestions(matching text: String, excluding current: [String], limit: Int = 3) -> [String] {
        let typed = text.kanSingleLine.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let taken = Set(current.map { $0.lowercased() })
        return library.tags().map(\.name)
            .filter { !taken.contains($0.lowercased()) && (typed.isEmpty || $0.lowercased().hasPrefix(typed)) }
            .prefix(limit)
            .map { $0 }
    }

    /// Names for speaker fields: remembered voices and people from earlier calls.
    func peopleSuggestions(matching text: String, limit: Int = 4) -> [String] {
        let typed = text.kanSingleLine.lowercased()
        let names = (library.people().map(\.name) + voiceprints.people().map(\.name)).kanUniquedCaseInsensitive()
        return Array(names.filter { typed.isEmpty || $0.lowercased().contains(typed) }.prefix(limit))
    }
}
