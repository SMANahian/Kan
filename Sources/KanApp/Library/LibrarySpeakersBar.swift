import SwiftUI
import KanCore

/// The call's speakers as chips (color, name, share of talk time). A chip opens the speaker editor.
struct LibrarySpeakersBar: View {
    let detail: LibraryCallDetailModel

    var body: some View {
        if !detail.speakerChips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(detail.speakerChips) { chip in
                        LibrarySpeakerChipButton(chip: chip, detail: detail)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct LibrarySpeakerChipButton: View {
    let chip: LibrarySpeakerChip
    let detail: LibraryCallDetailModel
    @State private var editing = false

    var body: some View {
        let color = LibrarySpeakerColors.color(chip.colorSlot)
        Button {
            editing = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(chip.speaker.isMe ? "\(chip.speaker.name) (me)" : chip.speaker.name)
                    .lineLimit(1)
                if let share = chip.share {
                    Text(LibraryFormat.percent(share))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if chip.speaker.suggestedName != nil && chip.speaker.hasDefaultName {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Kan has a guess for this voice")
                }
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename, play a sample or merge this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            LibrarySpeakerEditor(chip: chip, detail: detail) { editing = false }
        }
    }
}

/// Naming a speaker: the name field with suggestions (people from the library and remembered
/// voices, "Sounds like X?"), "Remember this voice", a 5 s sample, and merging into another speaker.
private struct LibrarySpeakerEditor: View {
    let chip: LibrarySpeakerChip
    let detail: LibraryCallDetailModel
    let dismiss: () -> Void
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var rememberVoice = true
    @State private var suggestions: [String] = []
    @FocusState private var nameFocused: Bool

    init(chip: LibrarySpeakerChip, detail: LibraryCallDetailModel, dismiss: @escaping () -> Void) {
        self.chip = chip
        self.detail = detail
        self.dismiss = dismiss
        _name = State(initialValue: chip.speaker.hasDefaultName ? "" : chip.speaker.name)
    }

    private var speaker: Speaker { chip.speaker }
    private var trimmed: String { LibraryTextMatch.singleLine(name) }
    private var others: [Speaker] { (detail.record?.speakers ?? []).filter { $0.id != speaker.id } }
    private var mergeTarget: Speaker? {
        LibrarySpeakerStats.speaker(named: trimmed, in: detail.record?.speakers ?? [], excluding: speaker.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(speaker.isMe ? "Your name in this call" : "Who is “\(speaker.name)”?")
                .font(.headline)
            TextField(speaker.name, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($nameFocused)
                .textInputSuggestions {
                    ForEach(matchingSuggestions, id: \.self) { suggestion in
                        Text(suggestion).textInputCompletion(suggestion)
                    }
                }
            if let suggested = speaker.suggestedName, !speaker.isMe {
                Button {
                    name = suggested
                } label: {
                    Label("Sounds like \(suggested)?", systemImage: "waveform")
                }
                .controlSize(.small)
                .help("A remembered voice that is similar, but not a sure match")
            }
            if !quickPicks.isEmpty {
                LibraryFlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(quickPicks, id: \.self) { person in
                        Button(person) { name = person }
                            .controlSize(.small)
                    }
                }
                .frame(width: 260, alignment: .leading)
            }
            if model.settings.rememberVoices && !speaker.isMe {
                Toggle("Remember this voice for future calls", isOn: $rememberVoice)
                    .toggleStyle(.checkbox)
            }
            if let target = mergeTarget {
                Text("“\(target.name)” is already in this call: saving merges the two speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    detail.playSample(of: speaker.id)
                } label: {
                    Label("Play Sample", systemImage: "play.circle")
                }
                .disabled(chip.sample == nil || !detail.player.isReady)
                .help(chip.sample == nil ? "No clear stretch of this voice" : "Play 5 seconds of this voice")
                if !others.isEmpty && !speaker.isMe {
                    Menu("Merge Into") {
                        ForEach(others) { other in
                            Button(other.name) {
                                dismiss()
                                detail.requestMerge(speaker.id, into: other.id)
                            }
                        }
                    }
                    .fixedSize()
                    .help("Everything this speaker said is attributed to the other speaker")
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(mergeTarget == nil ? "Save" : "Merge", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
        .onAppear {
            suggestions = detail.nameSuggestions()
            nameFocused = true
        }
    }

    private var matchingSuggestions: [String] {
        let key = LibraryFilter.nameKey(trimmed)
        guard !key.isEmpty else { return [] }
        return Array(suggestions.lazy.filter { name in
            let nameKey = LibraryFilter.nameKey(name)
            return nameKey.hasPrefix(key) && nameKey != key
        }.prefix(8))
    }

    /// A few people to pick with one click while the field is empty.
    private var quickPicks: [String] {
        guard trimmed.isEmpty, !speaker.isMe else { return [] }
        return Array(suggestions.prefix(6))
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        dismiss()
        detail.renameSpeaker(speaker.id, to: trimmed, rememberVoice: model.settings.rememberVoices && rememberVoice)
    }
}
