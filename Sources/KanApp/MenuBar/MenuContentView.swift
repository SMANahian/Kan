import AppKit
import SwiftUI
import KanCore

/// The menu-bar panel (MenuBarExtra, window style): status, recording controls, calls that need
/// labeling or are being transcribed, recent calls, detection and the app commands.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusSection(close: close)
            if model.liveCall == nil {
                MenuDivider()
                startRecordingMenu
            }
            if !model.problems.isEmpty {
                MenuDivider()
                ProblemsSection(close: close)
            }
            if !model.needsLabeling.isEmpty || !model.activeProcessing.isEmpty {
                MenuDivider()
                if !model.needsLabeling.isEmpty { needsLabelingMenu }
                ProcessingSection(close: close)
            }
            if !model.recentCalls.isEmpty {
                MenuDivider()
                recentCalls
            }
            MenuDivider()
            MenuRow("Search calls…", systemImage: "magnifyingglass") { close { model.searchCalls() } }
            autoDetectMenu
            MenuDivider()
            MenuRow("Library…", systemImage: "books.vertical", shortcut: "⌃⌥⌘L") { close { model.openLibrary() } }
            MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                close {
                    AppActivation.activateForWindow()
                    openSettings()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
            if model.isDebugMenuAvailable {
                DebugMenu(close: close)
            }
            MenuDivider()
            MenuRow("Quit Kan", systemImage: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        .onAppear {
            WindowRouter.shared.capture(openWindow: openWindow, openSettings: openSettings)
            model.refreshPermissions()
            model.pruneFinishedProcessing()
        }
    }

    /// Runs the action, then closes the panel (activation happens inside the action).
    private func close(_ action: () -> Void) {
        action()
        dismiss()
    }

    // MARK: Sections

    private var startRecordingMenu: some View {
        Menu {
            let apps = model.activeAudioApps()
            if !apps.isEmpty {
                Section("Apps using audio") {
                    ForEach(apps, id: \.app.bundleID) { activity in
                        Button("\(activity.app.name)\(activity.micActive ? " (mic on)" : "")") {
                            close { model.startManualRecording(.app(activity)) }
                        }
                    }
                }
            }
            Button("All system audio + mic") { close { model.startManualRecording(.systemAudio) } }
            Button("Mic only (in-person)") { close { model.startManualRecording(.micOnly) } }
        } label: {
            Label("Start recording", systemImage: "record.circle")
        }
        .menuStyle(.borderlessButton)
        .kanMenuRowLayout()
    }

    private var needsLabelingMenu: some View {
        Menu {
            ForEach(model.needsLabeling.prefix(12)) { summary in
                Button("\(summary.title) — \(KanFormat.shortMoment(summary.startedAt))") {
                    close { model.labelNow(summary.id) }
                }
            }
            if model.needsLabeling.count > 12 {
                Divider()
                Button("Show all in the library…") { close { model.openLibrary() } }
            }
        } label: {
            Label("Needs labeling (\(model.needsLabeling.count))", systemImage: "tag")
        }
        .menuStyle(.borderlessButton)
        .kanMenuRowLayout()
    }

    private var recentCalls: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuSectionHeader("Recent calls")
            ForEach(model.recentCalls) { summary in
                MenuRow(summary.title, systemImage: summary.starred ? "star.fill" : Self.symbol(for: summary.platform),
                        shortcut: KanFormat.shortMoment(summary.startedAt)) {
                    close { model.showInLibrary(summary.id) }
                }
            }
        }
    }

    private var autoDetectMenu: some View {
        Menu {
            Button("Pause for 1 hour") { model.pauseDetection(for: 3600) }
            Button("Pause until tomorrow") { model.pauseDetection(for: model.secondsUntilTomorrow()) }
            Button("Turn off") {
                model.settings.autoDetect = false
                model.saveSettings()
            }
            Divider()
            Button("Resume") { model.resumeDetection() }
                .disabled(model.settings.autoDetect && model.detectionPausedUntil == nil && !model.detectionPausedIndefinitely)
        } label: {
            Label("Auto-detect", systemImage: "waveform.badge.magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .kanMenuRowLayout()
    }

    static func symbol(for platform: CallPlatform) -> String {
        switch platform {
        case .zoom, .teams, .webex, .googleMeet, .jitsi, .whereby: return "video"
        case .facetime: return "phone"
        case .telegram, .whatsapp, .signal, .messenger, .slack, .discord: return "bubble.left.and.bubble.right"
        case .manual: return "mic"
        case .imported: return "square.and.arrow.down"
        case .browser, .skype, .other: return "phone.connection"
        }
    }
}

// MARK: - Status and recording controls

private struct StatusSection: View {
    @Environment(AppModel.self) private var model
    let close: (() -> Void) -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(model.liveCall == nil ? Color.secondary : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.headline).lineLimit(1)
                    if let detail = statusDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if model.services.isMock {
                    Text("Mock mode")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .help("Simulated services: no real audio is recorded")
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)

            if model.liveCall != nil {
                LevelMeters()
                    .padding(.horizontal, 15)
                prompts
                controls
            }
        }
        .padding(.bottom, 4)
    }

    private var statusSymbol: String {
        guard let live = model.liveCall else {
            return detectionActive ? "ear" : "ear.trianglebadge.exclamationmark"
        }
        return live.isPaused ? "pause.circle.fill" : "record.circle.fill"
    }

    private var detectionActive: Bool {
        model.settings.autoDetect && !model.detectionPausedIndefinitely && model.detectionPausedUntil == nil
    }

    private var statusTitle: String {
        if let live = model.liveCall {
            let elapsed = KanFormat.timer(model.now.timeIntervalSince(live.startedAt))
            if live.isTentative { return "Asking about \(live.appName) · \(elapsed)" }
            return live.isPaused ? "Paused · \(elapsed)" : "Recording \(live.appName) · \(elapsed)"
        }
        if !model.settings.autoDetect { return "Auto-detect is off" }
        if model.detectionPausedIndefinitely { return "Detection paused" }
        if let until = model.detectionPausedUntil { return "Detection paused until \(KanFormat.shortMoment(until))" }
        return "Listening for calls"
    }

    private var statusDetail: String? {
        if let live = model.liveCall {
            return live.title == "\(live.appName) call" ? nil : live.title
        }
        if !model.isStarted { return "Starting…" }
        return detectionActive ? "Kan records calls in Zoom, Meet, Telegram and more." : nil
    }

    @ViewBuilder
    private var prompts: some View {
        if let live = model.liveCall {
            if live.isTentative {
                PromptRow(text: "Record this call?") {
                    Button("Record") { close { model.respondToAsk(.record) } }.buttonStyle(.borderedProminent)
                    Button("Not now") { close { model.respondToAsk(.notNow) } }
                    Button("Never") { close { model.respondToAsk(.never) } }
                }
            }
            switch model.phase {
            case .ending(let deadline):
                PromptRow(text: "Call ended · saving in \(Int(max(0, deadline.timeIntervalSince(model.now)).rounded(.up))) s") {
                    Button("Keep recording") { close { model.keepRecording() } }
                    Button("Save now") { close { model.stopRecording() } }.buttonStyle(.borderedProminent)
                }
            case .stale:
                PromptRow(text: "Still in a call?") {
                    Button("Still in a call") { close { model.keepRecording() } }
                    Button("Stop & save") { close { model.stopRecording() } }.buttonStyle(.borderedProminent)
                }
            case .idle, .recording:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let live = model.liveCall {
            VStack(alignment: .leading, spacing: 0) {
                MenuRow("Stop & Save", systemImage: "stop.circle") { close { model.stopRecording() } }
                if live.isPaused {
                    MenuRow("Resume", systemImage: "play.circle") { model.resumeRecording() }
                } else {
                    MenuRow("Pause", systemImage: "pause.circle") { model.pauseRecording() }
                }
                MenuRow("Add bookmark", systemImage: "bookmark", shortcut: "⌃⌥⌘B") { model.addBookmark() }
                if confirmingDiscard {
                    PromptRow(text: "Delete this recording?") {
                        Button("Cancel") { confirmingDiscard = false }
                        Button("Discard", role: .destructive) {
                            confirmingDiscard = false
                            close { model.discardCurrentRecording() }
                        }
                    }
                } else {
                    MenuRow("Discard recording…", systemImage: "trash") { confirmingDiscard = true }
                }
            }
        }
    }
}

/// Me / Them level meters (only this view re-renders at the meters' 10 Hz).
private struct LevelMeters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MeterRow(label: "Me", level: model.levels.me)
            if model.liveCall != nil && model.liveRecordsRemoteTrack {
                MeterRow(label: "Them", level: model.levels.them)
            }
        }
    }
}

private struct MeterRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            LevelBar(level: level)
        }
    }
}

/// A level meter on a dB scale (-50 dBFS…0 dBFS).
private struct LevelBar: View {
    let level: Float

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db + 50) / 50)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * fraction)
                    .animation(.linear(duration: 0.1), value: fraction)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Problems and processing

private struct ProblemsSection: View {
    @Environment(AppModel.self) private var model
    let close: (() -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.problems) { problem in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let detail = problem.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if let action = problem.action, let title = problem.actionTitle {
                        Button(title) { close { model.perform(action) } }
                            .controlSize(.small)
                    } else if problem.id == "error" {
                        Button {
                            model.clearLastError()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 4)
    }
}

private struct ProcessingSection: View {
    @Environment(AppModel.self) private var model
    let close: (() -> Void) -> Void

    var body: some View {
        let jobs = model.activeProcessing
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                MenuSectionHeader("Processing")
                ForEach(jobs) { status in
                    ProcessingRow(status: status, title: model.summary(for: status.callID)?.title ?? "Call") {
                        close { model.showInLibrary(status.callID) }
                    } retry: {
                        model.retranscribe(status.callID, languageMode: nil)
                    }
                }
            }
        }
    }
}

private struct ProcessingRow: View {
    let status: ProcessingStatus
    let title: String
    let open: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    HStack(spacing: 6) {
                        if status.state == .running {
                            ProgressView(value: status.progress?.fraction ?? 0).frame(width: 80)
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if status.state == .failed || status.state == .cancelled {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 3)
    }

    private var detail: String {
        switch status.state {
        case .running:
            let stage = status.progress?.stage.displayName ?? "Transcribing"
            return "\(stage) · \(KanFormat.percent(status.progress?.fraction ?? 0))"
        case .queued: return "Waiting"
        case .paused: return "Paused during the call"
        case .failed: return status.error ?? "Failed"
        case .cancelled: return "Cancelled"
        case .done: return "Done"
        }
    }
}

// MARK: - Building blocks

/// A menu-like row: full width, highlighted on hover.
private struct MenuRow: View {
    let title: String
    let systemImage: String?
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).frame(width: 16)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.callout).foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.vertical, 5).padding(.horizontal, 10)
    }
}

private struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.bottom, 2)
    }
}

/// A short question with inline buttons (ask / ending / stale / confirm).
private struct PromptRow<Buttons: View>: View {
    let text: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout)
            HStack(spacing: 6) { buttons }
                .controlSize(.small)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 4)
    }
}

extension View {
    /// Lays out a submenu (`Menu`) like a menu row.
    func kanMenuRowLayout() -> some View {
        menuIndicator(.visible)
            .padding(.horizontal, 15)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
