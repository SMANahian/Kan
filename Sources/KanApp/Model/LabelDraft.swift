import Foundation
import KanCore

/// What a label save writes, field by field: nil keeps the call's stored value.
struct LabelEdits: Equatable {
    var title: String?
    var folder: String?
    var tags: [String]?
    var notes: String?
    var starred: Bool?
    var languageMode: LanguageMode?
}

/// The label panel's form: its fields, and which of them the user changed.
///
/// The panel can stay open for minutes (the transcript arrives meanwhile) while the same call is
/// edited in the library window or by an agent. So untouched fields follow the stored call
/// (`refresh(from:)`) and Save writes only the touched ones (`edits(for:)`). A remote speaker is
/// renamed — and their voice remembered — only when the user typed or picked the name, or
/// confirmed a recognized voice: a name Kan assigned from a remembered voice is never confirmed
/// silently, because a wrong match would then teach that voiceprint the wrong person.
///
/// A value type, so the self-test drives exactly what the panel does.
struct LabelDraft: Equatable {
    enum Field: Hashable {
        case title, folder, tags, notes, starred
    }

    /// The panel's text fields (`text(of:in:)`, `setText(_:of:in:)`).
    enum TextInput: Hashable {
        case title, folder, notes
        case speakerName(String)
    }

    struct SpeakerRename: Equatable {
        var speakerID: String
        /// "" restores the automatic "Speaker N".
        var name: String
        var rememberVoice: Bool
    }

    /// What the user typed as the title; nil while untouched (the panel shows the suggested title).
    private(set) var typedTitle: String?
    private(set) var folder = ""
    private(set) var tags: [String] = []
    private(set) var notes = ""
    private(set) var starred = false
    /// The name field of each remote speaker ("" = the automatic "Speaker N").
    private(set) var speakerNames: [String: String] = [:]
    private(set) var edited: Set<Field> = []
    /// Speakers whose name the user typed, picked or confirmed.
    private(set) var editedSpeakers: Set<String> = []
    private var rememberVoice: [String: Bool] = [:]

    init() {}

    init(record: CallRecord) {
        refresh(from: record)
    }

    func isEdited(_ field: Field) -> Bool { edited.contains(field) }

    // MARK: Following the stored call

    /// Untouched fields take the stored call's values (the transcript arrived, the library window
    /// changed something); whatever the user changed in the panel stays.
    mutating func refresh(from record: CallRecord) {
        if !edited.contains(.folder) { folder = record.folder }
        if !edited.contains(.tags) { tags = record.tags }
        if !edited.contains(.notes) { notes = record.notes }
        if !edited.contains(.starred) { starred = record.starred }
        for speaker in Self.remoteSpeakers(of: record) where !editedSpeakers.contains(speaker.id) {
            speakerNames[speaker.id] = speaker.hasDefaultName ? "" : speaker.name
        }
    }

    // MARK: Edits by the user

    mutating func setTitle(_ value: String) {
        typedTitle = value
        edited.insert(.title)
    }

    mutating func setFolder(_ value: String) {
        folder = value
        edited.insert(.folder)
    }

    mutating func setNotes(_ value: String) {
        notes = value
        edited.insert(.notes)
    }

    mutating func setStarred(_ value: Bool) {
        starred = value
        edited.insert(.starred)
    }

    /// Adds a cleaned tag (no "#", no duplicates, at most `AppModel.maxTags`).
    @MainActor
    mutating func addTag(_ raw: String) {
        guard let tag = AppModel.cleanTags([raw]).first, tags.count < AppModel.maxTags,
              !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        edited.insert(.tags)
    }

    mutating func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        edited.insert(.tags)
    }

    mutating func setSpeakerName(_ name: String, for speakerID: String) {
        speakerNames[speakerID] = name
        editedSpeakers.insert(speakerID)
    }

    /// "Confirm" next to a recognized voice: the name becomes the user's own, and Save adds this
    /// call's voice sample when "Remember voice" is on.
    mutating func confirmSpeaker(_ speakerID: String) {
        editedSpeakers.insert(speakerID)
    }

    mutating func setRememberVoice(_ remember: Bool, for speakerID: String) {
        rememberVoice[speakerID] = remember
    }

    func remembersVoice(of speakerID: String) -> Bool { rememberVoice[speakerID] ?? true }

    // MARK: Text fields
    //
    // SwiftUI's TextField writes the text it shows back through its binding when it gains or loses
    // focus, and again after the value changed under it (the panel focuses the title as it opens).
    // That write is no edit: taken as one, it would freeze an untouched field — Kan's title idea,
    // the names typed for the speakers and the library window's changes would stop showing, Save
    // would write the stale value back, and a recognized voice would count as confirmed. So the
    // panel's text fields read and write through these, which ignore a write of what the field
    // shows. Chips, menus and shortcuts call the setters above: a value picked there is a choice,
    // even the one already shown.

    /// What `input` shows. The title is `title(for:)`, or what was typed before the call was read.
    func text(of input: TextInput, in record: CallRecord?) -> String {
        switch input {
        case .title: return record.map(title(for:)) ?? typedTitle ?? ""
        case .folder: return folder
        case .notes: return notes
        case .speakerName(let id): return speakerNames[id] ?? ""
        }
    }

    /// `input`'s binding wrote `value`: an edit, unless it's what the field shows.
    mutating func setText(_ value: String, of input: TextInput, in record: CallRecord?) {
        guard value != text(of: input, in: record) else { return }
        switch input {
        case .title: setTitle(value)
        case .folder: setFolder(value)
        case .notes: setNotes(value)
        case .speakerName(let id): setSpeakerName(value, for: id)
        }
    }

    // MARK: Results

    /// The title field: what the user typed; otherwise the stored title, which — while it's still
    /// the automatic one — follows the names typed for the speakers ("Zoom call with Prof. Rahman").
    func title(for record: CallRecord) -> String {
        typedTitle ?? automaticTitle(for: record) ?? record.title
    }

    /// What Save writes. Pass the stored call as it is before the speaker renames: whether its
    /// title is still the automatic one depends on the old names.
    func edits(for record: CallRecord) -> LabelEdits {
        var edits = LabelEdits()
        if let typedTitle {
            edits.title = typedTitle
        } else if let automatic = automaticTitle(for: record), automatic != record.title {
            edits.title = automatic
        }
        if edited.contains(.folder) { edits.folder = folder }
        if edited.contains(.tags) { edits.tags = tags }
        if edited.contains(.notes) { edits.notes = notes }
        if edited.contains(.starred) { edits.starred = starred }
        return edits
    }

    /// The renames the user asked for: only speakers whose field they changed or confirmed.
    func speakerRenames(in record: CallRecord) -> [SpeakerRename] {
        Self.remoteSpeakers(of: record).compactMap { speaker -> SpeakerRename? in
            guard editedSpeakers.contains(speaker.id) else { return nil }
            let typed = (speakerNames[speaker.id] ?? "").kanSingleLine
            if typed.isEmpty {
                // Clearing the field restores "Speaker N".
                return speaker.hasDefaultName ? nil : SpeakerRename(speakerID: speaker.id, name: "", rememberVoice: false)
            }
            // Keeping (or retyping) a recognized name confirms it.
            guard typed != speaker.name || speaker.nameSource == .voiceprint else { return nil }
            return SpeakerRename(speakerID: speaker.id, name: typed, rememberVoice: remembersVoice(of: speaker.id))
        }
    }

    static func remoteSpeakers(of record: CallRecord) -> [Speaker] {
        record.speakers.filter { !$0.isMe && $0.id != Speaker.meID }
    }

    /// The automatic title with the typed speaker names, or nil when the stored title isn't automatic.
    private func automaticTitle(for record: CallRecord) -> String? {
        guard record.title == TranscriptRenderer.suggestedTitle(for: record) else { return nil }
        var draft = record
        for i in draft.speakers.indices {
            if let typed = speakerNames[draft.speakers[i].id]?.kanNonEmpty { draft.speakers[i].name = typed }
        }
        return TranscriptRenderer.suggestedTitle(for: draft)
    }
}
