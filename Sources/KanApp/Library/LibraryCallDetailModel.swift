import AppKit
import Foundation
import Observation
import KanCore

/// A request to scroll the transcript to a segment (or the segment at a time) and flash it.
struct LibraryTranscriptScroll: Equatable {
    var segmentID: Int?
    var time: Double?
    var nonce = UUID()
}

/// Find-in-transcript matches and which one is current.
struct LibraryFindState: Equatable {
    var ranges: [NSRange] = []
    var current: Int?
    /// Changes whenever the matches or the current match change.
    var revision = 0
    /// Scroll to the current match (navigation and new queries do; a jump to a search hit doesn't).
    var reveal = false
}

/// What the transcript text view can ask for. The closures hold the detail model weakly.
struct LibraryTranscriptActions {
    var seek: (_ time: Double, _ play: Bool) -> Void = { _, _ in }
    var togglePlay: () -> Void = {}
    var skip: (_ seconds: Double) -> Void = { _ in }
    var reassign: (_ segmentID: Int, _ speakerID: String) -> Void = { _, _ in }
    var bookmark: (_ segmentID: Int) -> Void = { _ in }
    var copy: (_ segmentID: Int, _ withTimestamp: Bool) -> Void = { _, _ in }
    /// Escape in the transcript; returns true when it did something (cleared the find).
    var escape: () -> Bool = { false }
}

/// A speaker chip of the speakers bar.
struct LibrarySpeakerChip: Identifiable, Equatable {
    var id: String { speaker.id }
    let speaker: Speaker
    /// Share of the talk time, when known.
    let share: Double?
    let colorSlot: Int?
    /// The cleanest stretch of their voice ("play a sample").
    let sample: TranscriptSegment?
}

/// The open call: its record (read off the main thread), the styled transcript, find state and
/// edits. Edits are applied to the local copy at once and sent to `AppModel` (which writes them with
/// `LibraryStore.update`); the record is re-read whenever the library changes, so the view always
/// converges on what is on disk. Unsaved drafts (title being typed, notes waiting for the debounce)
/// survive those reloads. Main-actor only.
@MainActor
@Observable
final class LibraryCallDetailModel {
    enum Phase: Equatable {
        case loading, loaded, missing
        case failed(String)
    }

    /// What OpenAI's text is compared with to tell whether it's outdated.
    private struct OutdatedInputs: Equatable {
        var ai: CallInsights?
        var segments: [TranscriptSegment]
        var speakers: [Speaker]
    }

    static let minFontSize = 12.0
    static let maxFontSize = 24.0

    let callID: CallID
    @ObservationIgnored let window: LibraryWindowModel

    private(set) var phase: Phase = .loading
    private(set) var record: CallRecord?
    private(set) var document: LibraryTranscriptDocument?
    private(set) var echoCount = 0
    private(set) var showEchoLines = false
    private(set) var fontSize: Double
    private(set) var speakerChips: [LibrarySpeakerChip] = []
    private(set) var colorSlots: [String: Int] = [:]
    /// The kept audio (or the raw recording) exists, so the call can be transcribed again.
    private(set) var canRetranscribe = false
    /// OpenAI's summary / title ideas were written from another version of the transcript.
    /// Worked out when what they depend on changes (`refreshOutdated`), not on every redraw: it
    /// hashes the whole transcript.
    private(set) var summaryOutdated = false
    private(set) var titleIdeasOutdated = false

    private(set) var findQuery = ""
    private(set) var findState = LibraryFindState()
    private(set) var scrollRequest: LibraryTranscriptScroll?
    private(set) var transcriptFocusToken: UUID?

    var titleDraft = ""
    /// The title field has focus (`beginEditingTitle`).
    private(set) var isEditingTitle = false
    private(set) var notesDraft = ""

    /// The title the field showed when editing began; an untouched draft follows the stored title.
    @ObservationIgnored private var titleEditBase: String?
    /// What `summaryOutdated` / `titleIdeasOutdated` were worked out from.
    @ObservationIgnored private var outdatedInputs: OutdatedInputs?
    @ObservationIgnored private var notesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var documentRevision = 0
    @ObservationIgnored private var pendingFocus: LibraryTranscriptFocus?
    @ObservationIgnored private(set) var transcriptActions = LibraryTranscriptActions()

    init(callID: CallID, window: LibraryWindowModel) {
        self.callID = callID
        self.window = window
        let stored = UserDefaults.standard.double(forKey: LibraryDefaults.transcriptFontSize)
        fontSize = stored >= Self.minFontSize && stored <= Self.maxFontSize ? stored : 14
        transcriptActions = makeTranscriptActions()
    }

    private var app: AppModel { window.app }
    var player: LibraryPlayer { window.player }

    // MARK: Loading

    func start() async {
        await load()
    }

    /// The detail went away: save drafts, stop this call's playback.
    func stop() {
        if isEditingTitle { commitTitle() }
        saveNotes()
        findTask?.cancel()
        resyncTask?.cancel()
        if player.callID == callID { player.unload() }
    }

    func reload() {
        Task { await load() }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let library = app.library
        let id = callID
        let result = await Task.detached(priority: .userInitiated) { () -> Result<CallRecord, Error> in
            Result { try library.record(id) }
        }.value
        guard generation == loadGeneration else { return }
        switch result {
        case .success(let loaded):
            apply(loaded)
        case .failure(let error):
            if let libraryError = error as? LibraryError, case .notFound = libraryError {
                record = nil
                document = nil
                phase = .missing
                if player.callID == callID { player.unload() }
                return
            }
            KanLog.error("Couldn't read call \(id): \(AppModel.logDescription(error))", category: "library-ui")
            // Keep showing the last good copy; only a call that never loaded shows the error.
            if record == nil { phase = .failed(error.localizedDescription) }
        }
    }

    private func apply(_ loaded: CallRecord) {
        let previous = record
        record = loaded
        phase = .loaded
        if !isEditingTitle {
            titleDraft = loaded.title
        } else if titleDraft == titleEditBase {
            // Focused but untouched (OpenAI's idea arrived meanwhile): show the new title, and
            // leaving the field writes nothing back.
            titleDraft = loaded.title
            titleEditBase = loaded.title
        }
        if notesSaveTask == nil { notesDraft = loaded.notes }
        if previous == nil || previous?.segments != loaded.segments || previous?.speakers != loaded.speakers {
            rebuildTranscript()
        }
        refreshOutdated()
        if previous == nil || previous?.audio != loaded.audio || previous?.status != loaded.status {
            loadAudio(resume: previous != nil)
        }
        applyPendingFocus()
    }

    /// Works the outdated flags out again when the summary, the ideas or the transcript they're
    /// compared with changed: after a reload, and after an edit here replaced `record` (a speaker
    /// renamed, a line moved), whose reload then finds nothing new.
    private func refreshOutdated() {
        guard let record else { return }
        let inputs = OutdatedInputs(ai: record.ai, segments: record.segments, speakers: record.speakers)
        guard inputs != outdatedInputs else { return }
        outdatedInputs = inputs
        summaryOutdated = record.isSummaryOutdated
        titleIdeasOutdated = record.areTitleIdeasOutdated
    }

    /// Re-reads the record a moment after an edit, in case `AppModel` changed more than we did
    /// (talk times, nothing at all because the write failed…).
    private func scheduleResync() {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func loadAudio(resume: Bool) {
        guard let record else { return }
        let sameCall = player.callID == callID
        let position = sameCall ? player.currentTime : nil
        let wasPlaying = sameCall && player.isPlaying
        let files: (me: URL?, them: URL?) = record.status == .recording ? (nil, nil) : app.audioFiles(for: callID)
        canRetranscribe = [files.me, files.them].contains { url in
            url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        player.load(callID: callID, me: files.me, them: files.them, fallbackDuration: record.duration,
                    unavailableReason: unavailableReason(record), resumeAt: resume ? position : nil,
                    autoplay: resume && wasPlaying)
    }

    private func unavailableReason(_ record: CallRecord) -> String {
        if record.status == .recording { return "The audio can be played once the call has ended." }
        if let deleted = record.audio?.deletedAt {
            return "The audio was deleted on \(deleted.formatted(date: .abbreviated, time: .omitted))."
        }
        if !app.settings.keepAudio { return "Audio isn't kept after transcription (see Settings)." }
        return "No audio was kept for this call."
    }

    // MARK: Transcript

    private func rebuildTranscript() {
        guard let record else { return }
        colorSlots = LibrarySpeakerStats.colorSlots(speakers: record.speakers, slotCount: LibrarySpeakerColors.count)
        echoCount = LibraryTurnMerging.echoSuspectCount(record.segments)
        let plan = LibraryTranscriptPlan(segments: record.segments, includeEchoSuspects: showEchoLines) {
            record.speakerName($0)
        }
        documentRevision += 1
        document = LibraryTranscriptDocument(callID: callID, plan: plan, record: record, colorSlots: colorSlots,
                                             fontSize: fontSize, revision: documentRevision)
        let shares = LibrarySpeakerStats.talkShares(speakers: record.speakers, segments: record.segments)
        speakerChips = LibrarySpeakerStats.displayOrder(record.speakers).map { speaker in
            LibrarySpeakerChip(speaker: speaker, share: shares[speaker.id], colorSlot: colorSlots[speaker.id],
                               sample: LibrarySpeakerStats.sampleSegment(for: speaker.id, in: record.segments))
        }
        recomputeFind(resetIndex: false, reveal: false)
    }

    func setShowEchoLines(_ show: Bool) {
        guard show != showEchoLines else { return }
        showEchoLines = show
        rebuildTranscript()
    }

    func setFontSize(_ size: Double) {
        let clamped = min(Self.maxFontSize, max(Self.minFontSize, size.rounded()))
        guard clamped != fontSize else { return }
        fontSize = clamped
        UserDefaults.standard.set(clamped, forKey: LibraryDefaults.transcriptFontSize)
        rebuildTranscript()
    }

    // MARK: Focus requests

    func apply(_ focus: LibraryTranscriptFocus) {
        guard focus.callID == callID else { return }
        pendingFocus = focus
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard let focus = pendingFocus, phase == .loaded else { return }
        pendingFocus = nil
        if let text = focus.findText {
            findTask?.cancel()
            findQuery = text
            recomputeFind(resetIndex: true, reveal: focus.segmentID == nil && focus.time == nil)
            if let segmentID = focus.segmentID { selectMatch(inSegment: segmentID) }
        }
        if let time = focus.time {
            player.seek(to: time, play: focus.play ? true : nil)
        }
        if focus.segmentID != nil || focus.time != nil {
            scrollRequest = LibraryTranscriptScroll(segmentID: focus.segmentID, time: focus.time)
        }
        if focus.focusTranscript { focusTranscript() }
    }

    func focusTranscript() {
        transcriptFocusToken = UUID()
    }

    func scroll(toTime time: Double) {
        scrollRequest = LibraryTranscriptScroll(time: time)
    }

    // MARK: Find in transcript

    var findStatus: String {
        guard !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard !findState.ranges.isEmpty else { return "No matches" }
        return "\((findState.current ?? 0) + 1) of \(findState.ranges.count)"
    }

    func setFindQuery(_ text: String) {
        // The field writes its text back when it gains or loses focus: that would start over at
        // the first match and scroll there.
        guard text != findQuery else { return }
        findQuery = text
        findTask?.cancel()
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.recomputeFind(resetIndex: true, reveal: true)
        }
    }

    func clearFind() {
        findTask?.cancel()
        findQuery = ""
        recomputeFind(resetIndex: true, reveal: false)
    }

    func findNext() {
        moveFind(by: 1)
    }

    func findPrevious() {
        moveFind(by: -1)
    }

    private func moveFind(by step: Int) {
        if findTask != nil {
            // A query typed less than the debounce ago: apply it first.
            findTask?.cancel()
            findTask = nil
            recomputeFind(resetIndex: true, reveal: true)
            if step > 0 { return }
        }
        let count = findState.ranges.count
        guard count > 0 else { return }
        let current = findState.current ?? (step > 0 ? -1 : 0)
        findState.current = ((current + step) % count + count) % count
        findState.reveal = true
        findState.revision += 1
    }

    private func recomputeFind(resetIndex: Bool, reveal: Bool) {
        findTask = nil
        let terms = LibraryTextMatch.terms(in: findQuery)
        let ranges = document?.plan.matchRanges(of: terms) ?? []
        var current: Int?
        if !ranges.isEmpty {
            if !resetIndex, let previous = findState.current, previous < ranges.count {
                current = previous
            } else {
                current = 0
            }
        }
        findState = LibraryFindState(ranges: ranges, current: current, revision: findState.revision + 1,
                                     reveal: reveal && current != nil)
    }

    /// Makes the first match inside a segment current (a search hit was opened).
    private func selectMatch(inSegment segmentID: Int) {
        guard let plan = document?.plan, let index = plan.segmentIndex(forID: segmentID) else { return }
        let range = plan.segments[index].range
        guard let match = findState.ranges.firstIndex(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
        findState.current = match
        findState.reveal = false
        findState.revision += 1
    }

    // MARK: Edits

    /// Applies `change` locally and through `AppModel.update`.
    func mutate(markLabeled: Bool, _ change: (inout CallRecord) -> Void) {
        guard var local = record else { return }
        change(&local)
        if markLabeled { local.labeled = true }
        let transcriptChanged = local.segments != record?.segments || local.speakers != record?.speakers
        record = local
        if transcriptChanged { rebuildTranscript() }
        refreshOutdated()
        app.update(callID, markLabeled: markLabeled) { change(&$0) }
        scheduleResync()
    }

    /// The title field got focus. The draft keeps what's typed across reloads; untouched, it
    /// follows the stored title.
    func beginEditingTitle() {
        guard !isEditingTitle else { return }
        isEditingTitle = true
        titleEditBase = titleDraft
    }

    /// Return, or the field lost focus: renames the call when the draft differs from what the
    /// field showed when editing began — the user's own title, which new title ideas never replace.
    func commitTitle() {
        let base = titleEditBase
        isEditingTitle = false
        titleEditBase = nil
        guard let record else { return }
        let title = LibraryTextMatch.singleLine(titleDraft)
        guard !title.isEmpty, title != (base.map(LibraryTextMatch.singleLine) ?? record.title) else {
            titleDraft = record.title
            return
        }
        mutate(markLabeled: true) { AppModel.setUserTitle(title, of: &$0) }
    }

    func revertTitle() {
        isEditingTitle = false
        titleEditBase = nil
        titleDraft = record?.title ?? ""
    }

    func editNotes(_ text: String) {
        // A write that changes nothing (a text view writing its text back) starts no save.
        guard text != notesDraft else { return }
        notesDraft = text
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNotes()
        }
    }

    /// Writes a pending notes draft now.
    func saveNotes() {
        guard notesSaveTask != nil else { return }
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard let record, notesDraft != record.notes else { return }
        let notes = notesDraft
        mutate(markLabeled: true) { $0.notes = notes }
    }

    func setFolder(_ folder: String) {
        guard let record, record.folder != folder else { return }
        guard let target = LibraryStore.sanitizeFolder(folder) else {
            window.showError("Invalid folder name", "“\(folder)” can't be used as a folder name.")
            return
        }
        mutate(markLabeled: true) { $0.folder = target }
    }

    func setTags(_ tags: [String]) {
        guard let record, tags != record.tags else { return }
        mutate(markLabeled: true) { $0.tags = tags }
    }

    func toggleStar() {
        guard let record else { return }
        let starred = !record.starred
        mutate(markLabeled: false) { $0.starred = starred }
    }

    func markLabeled() {
        mutate(markLabeled: true) { _ in }
    }

    // MARK: Bookmarks

    func addBookmark(at time: Double) {
        let bookmark = Bookmark(time: max(0, time))
        mutate(markLabeled: false) { $0.bookmarks.append(bookmark) }
        window.showToast("Bookmark added at \(KanTime.hms(time))", systemImage: "bookmark")
    }

    func updateBookmark(_ id: String, note: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = record?.bookmarks.first(where: { $0.id == id }), current.note != text else { return }
        mutate(markLabeled: false) { record in
            if let index = record.bookmarks.firstIndex(where: { $0.id == id }) { record.bookmarks[index].note = text }
        }
    }

    func deleteBookmark(_ id: String) {
        mutate(markLabeled: false) { $0.bookmarks.removeAll { $0.id == id } }
    }

    func jump(to bookmark: Bookmark) {
        go(to: bookmark.time)
    }

    /// Plays from `time` (paused stays paused) and scrolls the transcript there: bookmarks, the
    /// summary's timestamps.
    func go(to time: Double) {
        player.seek(to: time)
        scroll(toTime: time)
    }

    // MARK: OpenAI

    /// The title menu: an idea becomes the title (as if typed, so new ideas won't replace it).
    func applyTitleIdea(_ idea: String) {
        guard var local = record else { return }
        let title = LibraryTextMatch.singleLine(idea)
        guard !title.isEmpty, title != local.title || local.ai?.appliedTitle != nil else { return }
        app.applyTitleIdea(callID, title)
        AppModel.setUserTitle(title, of: &local)
        local.labeled = true
        record = local
        // Picked with the field focused (the menu leaves focus there): editing goes on from the idea.
        if isEditingTitle { titleEditBase = title }
        titleDraft = title
        scheduleResync()
    }

    func suggestTitles() {
        app.suggestTitles(callID)
    }

    /// Summarize, Regenerate and Retry.
    func summarize() {
        app.summarize(callID)
    }

    func cancelSummary() {
        app.cancelAIJob(.summary, for: callID)
    }

    /// Asks first: writing it again is another request.
    func requestRemoveSummary() {
        window.requestRemoveSummary(callID)
    }

    func copySummary() {
        guard let record, let text = LibrarySummaryText.clipboardText(record) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        window.showToast("Copied the summary", systemImage: "doc.on.doc")
    }

    // MARK: Speakers

    /// Renames a speaker. A name another speaker of this call already has asks to merge the two
    /// (into the user's own speaker when one of them is the user: that one can't be merged away).
    func renameSpeaker(_ speakerID: String, to name: String, rememberVoice: Bool) {
        guard let record, let speaker = record.speaker(speakerID) else { return }
        let trimmed = LibraryTextMatch.singleLine(name)
        guard !trimmed.isEmpty, trimmed != speaker.name || speaker.nameSource != .user else { return }
        if let other = LibrarySpeakerStats.speaker(named: trimmed, in: record.speakers, excluding: speakerID) {
            if speaker.isMe {
                window.requestMerge(callID, from: other, into: speaker)
            } else {
                window.requestMerge(callID, from: speaker, into: other)
            }
            return
        }
        app.renameSpeaker(callID, speakerID: speakerID, to: trimmed, rememberVoice: rememberVoice)
        var local = record
        if let index = local.speakers.firstIndex(where: { $0.id == speakerID }) {
            local.speakers[index].name = trimmed
            local.speakers[index].nameSource = .user
            local.speakers[index].suggestedName = nil
        }
        self.record = local
        rebuildTranscript()
        refreshOutdated()
        scheduleResync()
    }

    /// Asks to merge `speakerID` into `otherID` (the user's own speaker can only be merged into).
    func requestMerge(_ speakerID: String, into otherID: String) {
        guard let record, let from = record.speaker(speakerID), let into = record.speaker(otherID),
              !from.isMe, from.id != into.id else { return }
        window.requestMerge(callID, from: from, into: into)
    }

    func playSample(of speakerID: String) {
        guard let segment = speakerChips.first(where: { $0.id == speakerID })?.sample else { return }
        player.playSample(from: segment.start, to: min(segment.end, segment.start + 5), channel: segment.channel)
    }

    /// Names to offer when naming a speaker: people from the library and remembered voices, minus
    /// the names already used in this call.
    func nameSuggestions() -> [String] {
        var names = window.sidebar.people.map(\.name)
        if app.settings.rememberVoices { names += app.voiceprints.people().map(\.name) }
        let used = Set((record?.speakers ?? []).map { LibraryFilter.nameKey($0.name) })
        var seen = Set<String>()
        return names.filter { name in
            let key = LibraryFilter.nameKey(name)
            return !key.isEmpty && !used.contains(key) && seen.insert(key).inserted
        }
    }

    // MARK: Segments

    func reassign(segmentID: Int, to speakerID: String) {
        guard let record, let index = record.segments.firstIndex(where: { $0.id == segmentID }),
              record.segments[index].speakerID != speakerID, record.speaker(speakerID) != nil else { return }
        app.reassignSegment(callID, segmentID: segmentID, to: speakerID)
        var local = record
        local.segments[index].speakerID = speakerID
        self.record = local
        rebuildTranscript()
        refreshOutdated()
        scheduleResync()
    }

    func copy(segmentID: Int, withTimestamp: Bool) {
        guard let record, let segment = record.segments.first(where: { $0.id == segmentID }) else { return }
        let text = LibraryTextMatch.singleLine(segment.text)
        let string = withTimestamp
            ? LibraryFormat.transcriptLine(time: segment.start, speaker: record.speakerName(segment.speakerID), text: text)
            : text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func bookmark(segmentID: Int) {
        guard let segment = record?.segments.first(where: { $0.id == segmentID }) else { return }
        addBookmark(at: segment.start)
    }

    // MARK: Processing

    /// Progress shows in the status banner; `AppModel` reports a failure itself.
    func retranscribe(_ mode: LanguageMode?) {
        app.retranscribe(callID, languageMode: mode)
    }

    func cancelProcessing() {
        app.cancelProcessing(callID)
    }

    // MARK: Reader actions

    private func makeTranscriptActions() -> LibraryTranscriptActions {
        LibraryTranscriptActions(
            seek: { [weak self] time, play in self?.player.seek(to: time, play: play ? true : nil) },
            togglePlay: { [weak self] in self?.player.togglePlay() },
            skip: { [weak self] seconds in self?.player.skip(by: seconds) },
            reassign: { [weak self] segmentID, speakerID in self?.reassign(segmentID: segmentID, to: speakerID) },
            bookmark: { [weak self] segmentID in self?.bookmark(segmentID: segmentID) },
            copy: { [weak self] segmentID, withTimestamp in self?.copy(segmentID: segmentID, withTimestamp: withTimestamp) },
            escape: { [weak self] in
                guard let self, !findQuery.isEmpty else { return false }
                clearFind()
                return true
            })
    }
}
