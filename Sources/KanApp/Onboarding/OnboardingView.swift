import SwiftUI
import KanCore

/// First-launch guide (reopenable from Settings): what Kan does, your name, permissions, models,
/// remembered voices and launch at login. Every step can be skipped; nothing is required to
/// finish.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Step = .welcome
    @State private var launchAtLogin = true

    enum Step: Int, CaseIterable {
        case welcome, name, required, optional, models, voices, login, done
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .name: NameStep()
                case .required: RequiredPermissionsStep()
                case .optional: OptionalPermissionsStep()
                case .models: ModelsStep()
                case .voices: VoicesStep()
                case .login: LoginStep(launchAtLogin: $launchAtLogin)
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Circle()
                            .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { move(by: -1) }
                }
                Button(step == .done ? "Start Using Kan" : "Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 580, height: 480)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onAppear {
            model.refreshPermissions()
            model.refreshModelReadiness()
            launchAtLogin = model.loginItemStatus != .disabled || !model.settings.onboardingCompleted
        }
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }

    private func advance() {
        if step == .voices && !model.settings.askedAboutVoices {
            model.settings.askedAboutVoices = true
        }
        guard step == .done else {
            move(by: 1)
            return
        }
        model.completeOnboarding(launchAtLogin: launchAtLogin)
        dismissWindow(id: SceneID.onboarding)
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 14)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "ear", title: "Welcome to Kan (কান)",
                       subtitle: "Kan listens for your calls, records both sides, and turns them into searchable transcripts — Bangla and English, even mixed in one sentence.")
            Bullet("phone.connection", "Detects calls in Zoom, Google Meet (in any browser, including Zen), Teams, Telegram, Slack, WhatsApp, FaceTime and more.")
            Bullet("person.2.wave.2", "Knows who said what: your microphone is you; the other side is split into speakers you can name.")
            Bullet("tag", "Right after a call, asks for a title, folder and tags so your library stays organized.")
            Bullet("doc.text.magnifyingglass", "Stores every call as Markdown + JSON you can read, search, export or hand to your AI agents.")
            Bullet("lock.shield", "Everything happens on this Mac. Kan uploads nothing — its only network use is downloading models.")
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String
    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NameStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "person.crop.circle", title: "What's your name?",
                       subtitle: "Transcripts label your microphone with it, so “who said what” reads naturally.")
            TextField("Your name", text: $model.settings.userName, prompt: Text("e.g. Nahian"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 320)
            SettingsFootnote("You can change it later in Settings › General.")
        }
    }
}

private struct RequiredPermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "lock.shield", title: "Two permissions to record calls",
                       subtitle: "macOS asks once for each. Kan records only during calls.")
            OnboardingPermissionRow(kind: .microphone,
                                    detail: "Records your side of the call.")
            OnboardingPermissionRow(kind: .systemAudio,
                                    detail: "Records the other side — just the call app's sound. While Kan records it, macOS shows a purple indicator in the menu bar. If you allow it in System Settings, Kan may need to relaunch.")
        }
    }
}

private struct OptionalPermissionsStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "sparkles", title: "Optional: better names for calls",
                       subtitle: "Detection works without these. They only help Kan title your calls.")
            OnboardingPermissionRow(kind: .accessibility,
                                    detail: "Reads browser window titles — Zen, Firefox, Chrome, Safari — to recognize Google Meet and Teams calls on the web and name them.")
            OnboardingPermissionRow(kind: .calendar,
                                    detail: "Uses the calendar event you're in for the title and attendees.",
                                    onRequest: { model.settings.useCalendar = true })
        }
    }
}

private struct OnboardingPermissionRow: View {
    @Environment(AppModel.self) private var model
    let kind: PermissionKind
    let detail: String
    var onRequest: (() -> Void)?
    @State private var requesting = false

    var body: some View {
        let status = model.permissionStatuses[kind] ?? .unknown
        let needsRelaunch = status == .granted && model.needsRelaunch(kind)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: PermissionSettingsRow.symbol(kind)).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(kind.displayName).font(.headline)
                    PermissionStatusBadge(status: status, needsRelaunch: needsRelaunch)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if needsRelaunch {
                // Allowed in System Settings while Kan ran: it applies once Kan starts again.
                Button("Relaunch Kan") { model.perform(.relaunch) }
            } else if status == .granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } else if status == .denied {
                Button("Open Settings") { model.openPermissionSettings(kind) }
            } else {
                Button(requesting ? "Asking…" : "Allow…") {
                    requesting = true
                    onRequest?()
                    Task {
                        await model.requestPermission(kind)
                        requesting = false
                    }
                }
                .disabled(requesting)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ModelsStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let missing = model.missingRecommendedModels
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "square.and.arrow.down", title: "Transcription models",
                       subtitle: "Kan transcribes on this Mac with Whisper models (one download, kept in Application Support).")
            if let readiness = model.modelReadiness {
                if readiness.canTranscribe {
                    Label("Kan can transcribe with what's installed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(readiness.missing, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                ForEach(readiness.recommendations, id: \.self) { Label($0, systemImage: "lightbulb").foregroundStyle(.secondary) }
            } else {
                ProgressView().controlSize(.small)
            }
            if !missing.isEmpty {
                let total = missing.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Button("Download Recommended Models (\(KanFormat.bytes(total)))") {
                    for info in missing { model.downloadModel(info.id) }
                }
                .disabled(missing.allSatisfy { model.modelDownloads[$0.id] != nil })
            }
            ForEach(model.availableModels.filter { model.modelDownloads[$0.id] != nil }) { info in
                HStack {
                    Text(info.displayName).font(.callout)
                    ProgressView(value: model.modelDownloads[info.id] ?? 0)
                }
            }
            SettingsFootnote("Fine to skip: downloads continue in the background, and Settings › Transcription lists every model.")
        }
    }
}

private struct VoicesStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "person.wave.2", title: "Remember voices?",
                       subtitle: "When you name a speaker after a call, Kan can remember their voice and name them automatically next time.")
            SettingsFootnote("Voice samples are stored only on this Mac (never in your library), and Settings can forget them at any time. Ask people before remembering their voice.")
            Picker("Remember voices", selection: Binding(
                get: { model.settings.rememberVoices },
                set: { newValue in
                    model.settings.rememberVoices = newValue
                    model.settings.askedAboutVoices = true
                })) {
                Text("Remember voices I name").tag(true)
                Text("Don't remember voices").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

private struct LoginStep: View {
    @Binding var launchAtLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "power", title: "Start with your Mac",
                       subtitle: "Kan can only notice calls while it's running. It lives in the menu bar and uses very little power when idle.")
            Toggle("Launch Kan at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
        }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "checkmark.seal", title: "You're set",
                       subtitle: "Kan is in your menu bar — look for the ear at the top right of the screen.")
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right").font(.title).foregroundStyle(.tint)
                HStack(spacing: 4) {
                    Image(systemName: "ear")
                    Text("Kan")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            Bullet("record.circle", "When a call starts, Kan records it and shows a small notice at the top right.")
            Bullet("tag", "When it ends, label it — or press Esc to do it later.")
            Bullet("keyboard", "⌃⌥⌘R records anything, ⌃⌥⌘B bookmarks a moment, ⌃⌥⌘L opens the library.")
            if model.libraryInICloud {
                // Before the first call: a transcript iCloud has uploaded can't be taken back.
                LibraryCloudNotice()
            }
        }
    }
}
