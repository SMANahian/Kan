import SwiftUI
import KanCore

/// Play / pause, ±5 s, scrubber, elapsed / total and speed. Space and ←/→ work in the transcript.
struct LibraryPlayerBar: View {
    let player: LibraryPlayer
    @State private var scrubTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            switch player.state {
            case .idle:
                controls.disabled(true)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading audio…")
                    .foregroundStyle(.secondary)
                Spacer()
            case .ready:
                controls
            case .unavailable(let reason):
                Image(systemName: "speaker.slash")
                    .foregroundStyle(.secondary)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(.bar)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                player.skip(by: -5)
            } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.borderless)
            .help("Back 5 seconds (←)")
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button {
                player.skip(by: 5)
            } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.borderless)
            .help("Forward 5 seconds (→)")
            Text(KanTime.compact(scrubTime ?? player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Slider(value: Binding(get: { scrubTime ?? player.currentTime }, set: { scrubTime = $0 }),
                   in: 0...max(player.duration, 0.1)) { editing in
                if !editing, let time = scrubTime {
                    player.seek(to: time)
                    scrubTime = nil
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Playback position")
            Text(KanTime.compact(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
            Menu {
                ForEach(LibraryPlayer.rates, id: \.self) { rate in
                    Toggle(Self.label(rate), isOn: Binding(get: { player.rate == rate },
                                                          set: { isOn in if isOn { player.setRate(rate) } }))
                }
            } label: {
                Text(Self.label(player.rate))
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")
            if let note = player.note {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(note)
                    .accessibilityLabel(note)
            }
        }
    }

    static func label(_ rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }
}
