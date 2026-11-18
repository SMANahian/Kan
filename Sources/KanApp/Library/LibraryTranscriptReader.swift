import SwiftUI
import KanCore

/// The transcript area: a strip with the echo-lines toggle, text size and "follow playback", then
/// the transcript text view (or a placeholder while there is none).
struct LibraryTranscriptReader: View {
    let detail: LibraryCallDetailModel
    let player: LibraryPlayer
    @AppStorage(LibraryDefaults.followPlayback) private var followPlayback = true

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            if let document = detail.document, !document.plan.isEmpty {
                LibraryTranscriptView(document: document, find: detail.findState, scrollRequest: detail.scrollRequest,
                                      focusToken: detail.transcriptFocusToken, followPlayback: followPlayback,
                                      player: player, actions: detail.transcriptActions)
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 12) {
            if detail.echoCount > 0 {
                Toggle(isOn: Binding(get: { detail.showEchoLines }, set: { detail.setShowEchoLines($0) })) {
                    Text(detail.showEchoLines
                         ? "Showing \(LibraryFormat.count(detail.echoCount, "possible echo line"))"
                         : "Show \(LibraryFormat.count(detail.echoCount, "possible echo line"))")
                }
                .toggleStyle(.checkbox)
                .help("Lines your microphone probably picked up from the other side (speakers instead of headphones)")
            } else {
                Text("Transcript")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ControlGroup {
                Button {
                    detail.setFontSize(detail.fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text (⌘−)")
                .disabled(detail.fontSize <= LibraryCallDetailModel.minFontSize)
                Button {
                    detail.setFontSize(detail.fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Bigger text (⌘=)")
                .disabled(detail.fontSize >= LibraryCallDetailModel.maxFontSize)
            }
            .controlSize(.small)
            .fixedSize()
            Toggle(isOn: $followPlayback) {
                Label("Follow Playback", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep the line being played in view")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
    }

    /// Shown instead of the transcript. Compact on purpose: the header above already says what the
    /// call is, and a tall placeholder would push it out of a short window.
    @ViewBuilder
    private var placeholder: some View {
        switch detail.record?.status {
        case .recording?:
            LibraryReaderPlaceholder(systemImage: "record.circle", title: "Recording in progress",
                                     message: "The transcript will appear after the call.")
        case .queued?, .processing?:
            LibraryReaderPlaceholder(systemImage: "waveform", title: "The transcript is being generated",
                                     message: "Kan transcribes on this Mac; the audio never leaves it.")
        case .failed?:
            LibraryReaderPlaceholder(systemImage: "exclamationmark.bubble", title: "No transcript yet",
                                     message: "Transcription didn't finish. The audio was kept, so you can retry.")
        case .ready?, nil:
            if detail.echoCount > 0 && !detail.showEchoLines {
                LibraryReaderPlaceholder(systemImage: "speaker.wave.2", title: "Only possible echo lines",
                                         message: "Every line looks like your microphone picking up the other side.",
                                         actionTitle: "Show Them") { detail.setShowEchoLines(true) }
            } else {
                LibraryReaderPlaceholder(systemImage: "waveform.slash", title: "No speech was detected",
                                         message: "Nobody seems to have spoken in this call.")
            }
        }
    }
}

/// A small centered icon, title and message (with an optional button).
private struct LibraryReaderPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }
}
