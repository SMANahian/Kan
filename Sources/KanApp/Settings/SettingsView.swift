import AppKit
import SwiftUI
import KanCore

/// The Settings window. Every change is saved at once (and applied to detection, hot keys,
/// retention… by `AppModel.saveSettings()`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DetectionSettingsView()
                .tabItem { Label("Detection", systemImage: "waveform.badge.magnifyingglass") }
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AgentsSettingsView()
                .tabItem { Label("AI Agents", systemImage: "terminal") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 560)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}

/// Secondary explanatory text under a setting.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The library folder is synced by iCloud Drive, so macOS uploads every transcript Kan saves:
/// says so and offers a folder on this Mac (onboarding's last step, Settings › General).
struct LibraryCloudNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folder = (model.library.root.path as NSString).abbreviatingWithTildeInPath
        let local = (model.localLibrarySuggestion.path as NSString).abbreviatingWithTildeInPath
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "icloud.and.arrow.up").font(.title3).foregroundStyle(.orange).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your library is in iCloud Drive").font(.headline)
                if model.libraryRelocationPending {
                    Text("Kan saves calls in the new folder once it relaunches. Calls already in \(folder) stay there.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch Kan") { model.perform(.relaunch) }
                } else {
                    Text("iCloud syncs \(folder), so macOS would upload every transcript to iCloud. Kan itself uploads nothing.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Keep Transcripts on This Mac (\(local))") { model.useLocalLibrary() }
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MenuBarDefaults.showsText) private var menuBarShowsText = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("You") {
                TextField("Your name", text: $model.settings.userName, prompt: Text("Me"))
                SettingsFootnote("Kan uses it for your microphone track (“who said what”).")
            }
            Section("Startup") {
                Toggle("Launch Kan at login", isOn: Binding(
                    get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(isLoginItemUnavailable)
                switch model.loginItemStatus {
                case .requiresApproval:
                    HStack {
                        SettingsFootnote("Allow Kan in System Settings › General › Login Items.")
                        Spacer()
                        Button("Open Login Items") { model.environment.loginItem.openSystemSettings() }
                    }
                case .unavailable(let reason):
                    SettingsFootnote(reason)
                case .enabled, .disabled:
                    EmptyView()
                }
            }
            Section("Library") {
                LabeledContent("Location") {
                    Text(model.settings.libraryURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseLibrary)
                    Button("Show in Finder") { model.environment.openURL(model.library.root) }
                    if !model.settings.libraryPath.isEmpty {
                        Button("Use Default") { model.settings.libraryPath = "" }
                    }
                }
                SettingsFootnote("Transcripts are Markdown + JSON files that you and your AI agents can read. It can be inside an Obsidian vault.")
                if model.libraryInICloud {
                    LibraryCloudNotice()
                } else if model.libraryRelocationPending {
                    HStack {
                        SettingsFootnote("Kan switches to the new location when it restarts. Files aren't moved.")
                        Spacer()
                        Button("Relaunch Kan") { model.environment.relaunch() }
                    }
                }
            }
            Section("Menu bar") {
                Toggle("Show the call timer and transcription progress", isOn: $menuBarShowsText)
                SettingsFootnote("The menu always shows them. Next to a MacBook's notch there's room for only a few icons, and macOS hides the ones that don't fit, so a wider icon can vanish during calls.")
            }
            Section("After each call") {
                Toggle("Ask me to label the call", isOn: $model.settings.showLabelPrompt)
                SettingsFootnote("A small panel asks for a title, folder and tags when the call ends. It never appears during a call.")
            }
            Section("Keyboard") {
                Toggle("Global shortcuts", isOn: $model.settings.globalHotkeysEnabled)
                ForEach(GlobalHotkey.allCases, id: \.self) { key in
                    LabeledContent(key.actionDescription, value: key.displayName)
                        .foregroundStyle(model.settings.globalHotkeysEnabled ? .primary : .secondary)
                }
                if !model.hotkeyFailures.isEmpty {
                    SettingsFootnote("Another app already uses \(model.hotkeyFailures.map(\.displayName).joined(separator: ", ")).")
                }
            }
            Section {
                Button("Show the Welcome Guide…") { model.openOnboarding() }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItemStatus() }
    }

    private var isLoginItemUnavailable: Bool {
        if case .unavailable = model.loginItemStatus { return true }
        return false
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Kan keeps your transcripts."
        panel.directoryURL = model.settings.libraryURL.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                useLibraryFolder(url.standardizedFileURL)
            }
        }
    }

    /// An empty folder or a Kan library is used as it is. A folder with other files in it (an
    /// Obsidian vault, ~/Documents) never is: Kan would spread Inbox and its index files among
    /// them. It offers a "Kan" folder inside instead, or nothing changes.
    private func useLibraryFolder(_ folder: URL) {
        guard LibraryLocation.contents(of: folder) == .other else {
            model.settings.libraryPath = folder.path
            return
        }
        let inside = LibraryLocation.suggestedSubfolder(in: folder)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(folder.lastPathComponent)” already has other files in it"
        alert.informativeText = "Kan fills its library folder with its own folders and files (Inbox, your call folders, "
            + "index.md, AGENTS.md). Keep the library in a “\(inside.lastPathComponent)” folder inside it instead, so "
            + "what's already there stays as it is."
        alert.addButton(withTitle: "Use “\(inside.lastPathComponent)” Inside")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        } catch {
            model.report("Couldn't create the folder “\(inside.lastPathComponent)”", error: error, category: "settings",
                         log: "Couldn't create the library folder")
            return
        }
        model.settings.libraryPath = inside.standardizedFileURL.path
    }
}

// MARK: - Detection

struct DetectionSettingsView: View {
    @Environment(AppModel.self) private var model
    /// Apps outside the catalog that saved calls came from (read when the tab opens and when the
    /// number of calls changes).
    @State private var recordedApps: [RecordedApp] = []

    private struct AppGroup: Identifiable {
        var title: String
        var category: AppCategory
        var id: AppCategory { category }
    }

    private static let groups = [
        AppGroup(title: "Meeting apps", category: .meeting),
        AppGroup(title: "Messaging apps", category: .messaging),
        AppGroup(title: "Browsers", category: .browser),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Detect calls automatically", isOn: $model.settings.autoDetect)
                SettingsFootnote("Kan notices when an app has used the microphone for a few seconds. Nothing is recorded for apps set to Never.")
            }
            Section("Policies") {
                Picker("Browsers (Meet, Teams, Zoom on the web)", selection: $model.settings.browserPolicy) {
                    ForEach(AppPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Apps Kan doesn't know", selection: $model.settings.unknownAppPolicy) {
                    ForEach(AppPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            ForEach(Self.groups) { group in
                Section(group.title) {
                    ForEach(AppCatalog.known.filter { $0.category == group.category }) { app in
                        Picker(app.name, selection: policyBinding(app)) {
                            ForEach(AppPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            let others = otherApps
            if !others.isEmpty {
                Section("Other apps") {
                    ForEach(others) { app in
                        HStack {
                            Picker(app.name, selection: Binding(
                                get: { model.settings.appPolicies[app.bundleID] ?? model.effectivePolicy(bundleID: app.bundleID) },
                                set: { model.settings.appPolicies[app.bundleID] = $0 })) {
                                ForEach(AppPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .help(app.bundleID)
                            if model.settings.appPolicies[app.bundleID] != nil {
                                Button {
                                    model.settings.appPolicies[app.bundleID] = nil
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget this app's policy")
                            }
                        }
                    }
                    SettingsFootnote("Apps Kan doesn't know: those you gave a policy (“Never record …”) and those calls in your library came from.")
                }
            }
            Section("Timing") {
                Stepper("Ignore automatic recordings shorter than \(Int(model.settings.minCallSeconds)) s",
                        value: $model.settings.minCallSeconds, in: 0...300, step: 5)
                Stepper("End app calls \(Int(model.settings.endGraceNativeSeconds)) s after the mic is released",
                        value: $model.settings.endGraceNativeSeconds, in: 5...120, step: 5)
                Stepper("End browser calls \(Int(model.settings.endGraceBrowserSeconds)) s after the mic is released",
                        value: $model.settings.endGraceBrowserSeconds, in: 5...180, step: 5)
                Stepper("Ask “Still in a call?” after \(Int(model.settings.staleSilenceMinutes)) min of silence",
                        value: $model.settings.staleSilenceMinutes, in: 5...120, step: 5)
            }
            Section("Recording") {
                Picker("Record the other side from", selection: $model.settings.captureScope) {
                    Text("The call app only (recommended)").tag(CaptureScope.callApp)
                    Text("All system audio").tag(CaptureScope.allSystemAudio)
                }
                Toggle("Pause transcription during calls", isOn: $model.settings.pauseTranscriptionDuringCalls)
                SettingsFootnote("Transcription uses the GPU; pausing it keeps calls smooth. It continues when the call ends.")
            }
        }
        .formStyle(.grouped)
        // Again when a call is added or deleted (not on every save: it reads records).
        .task(id: model.summaries.count) { recordedApps = await model.recordedAppsOutsideCatalog() }
    }

    private func defaultPolicy(_ app: KnownApp) -> AppPolicy {
        app.category == .browser ? model.settings.browserPolicy : .auto
    }

    private func policyBinding(_ app: KnownApp) -> Binding<AppPolicy> {
        Binding(
            get: { model.settings.appPolicies[app.id] ?? defaultPolicy(app) },
            set: { newValue in
                let isDefault = newValue == defaultPolicy(app)
                for id in app.bundleIDs { model.settings.appPolicies[id] = isDefault ? nil : newValue }
            })
    }

    /// Apps outside the catalog: those with a policy of their own (set from “Never for <App>” or
    /// here) and those saved calls came from, by name.
    private var otherApps: [RecordedApp] {
        var apps: [String: RecordedApp] = [:]
        for app in recordedApps { apps[app.bundleID] = app }
        for bundleID in model.settings.appPolicies.keys where apps[bundleID] == nil && AppCatalog.lookup(bundleID: bundleID) == nil {
            apps[bundleID] = RecordedApp(bundleID: bundleID, name: Self.installedName(bundleID: bundleID) ?? bundleID)
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Voice Lounge" for an installed app, nil otherwise.
    private static func installedName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Language") {
                Picker("Language", selection: $model.settings.languageMode) {
                    ForEach(LanguageMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                SettingsFootnote("Auto decides Bangla or English for every stretch of speech, so mixed calls work. Pick one language when a call is entirely in it.")
            }
            Section("Models") {
                if let readiness = model.modelReadiness {
                    ForEach(readiness.missing, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    ForEach(readiness.recommendations, id: \.self) { message in
                        Label(message, systemImage: "lightbulb").foregroundStyle(.secondary)
                    }
                    if readiness.canTranscribe && readiness.missing.isEmpty && readiness.recommendations.isEmpty {
                        Label("Everything needed is installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                ForEach(ModelRole.allCases, id: \.self) { role in
                    let models = model.availableModels.filter { $0.role == role }
                    if !models.isEmpty {
                        Text(Self.roleName(role)).font(.subheadline.weight(.semibold)).padding(.top, 4)
                        ForEach(models) { info in ModelRow(info: info) }
                    }
                }
                modelPicker("General model", role: .general, selection: $model.settings.generalModelID)
                modelPicker("English model", role: .english, selection: $model.settings.englishModelID)
                modelPicker("Bangla model", role: .bangla, selection: $model.settings.banglaModelID)
                SettingsFootnote("Models are downloaded once into ~/Library/Application Support/Kan/Models. Everything else stays on this Mac.")
            }
            Section("Vocabulary") {
                TextEditor(text: $model.settings.vocabulary)
                    .font(.body)
                    .frame(height: 70)
                SettingsFootnote("Names, research terms and jargon (comma or newline separated) help the recognizer spell them right.")
            }
            Section("Speakers") {
                Toggle("Tell the other speakers apart", isOn: $model.settings.diarize)
                Picker("Other people on calls", selection: $model.settings.maxRemoteSpeakers) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(1...10, id: \.self) { n in Text("At most \(n)").tag(Int?.some(n)) }
                }
                .disabled(!model.settings.diarize)
                Toggle("Remove echo when the call plays through speakers", isOn: $model.settings.echoSuppression)
            }
            Section("Remembered voices") {
                Toggle("Remember voices to name people automatically", isOn: Binding(
                    get: { model.settings.rememberVoices },
                    set: { newValue in
                        model.settings.rememberVoices = newValue
                        model.settings.askedAboutVoices = true
                    }))
                SettingsFootnote("While this is on, Kan keeps voice samples of each call's speakers (only on this Mac, never in the library), so naming a speaker — right after the call or later — remembers their voice for later calls. The samples stay when call audio isn't kept; deleting a call or its audio, turning this off, or Forget All Voices deletes them. Remembered people stay until you forget them.")
                LabeledContent("Remembered people", value: "\(model.rememberedVoiceCount)")
                LabeledContent("Calls with voice samples", value: "\(model.voiceSampleCallCount)")
                Button("Forget All Voices…", role: .destructive) { confirmingForget = true }
                    .disabled(!model.canForgetVoices)
                    .confirmationDialog("Forget every remembered voice?", isPresented: $confirmingForget) {
                        Button("Forget All Voices", role: .destructive) { model.forgetAllVoices() }
                    } message: {
                        Text("The voice samples kept with your calls are deleted too. Names already in transcripts stay; new calls won't be recognized.")
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshModelReadiness()
            model.refreshRememberedVoices()
        }
    }

    private func modelPicker(_ title: String, role: ModelRole, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic (best installed)").tag("auto")
            ForEach(model.availableModels.filter { $0.role == role }) { info in
                Text(info.installed ? info.displayName : "\(info.displayName) (not installed)").tag(info.id)
            }
        }
    }

    static func roleName(_ role: ModelRole) -> String {
        switch role {
        case .general: return "General (language detection, fallback)"
        case .english: return "English"
        case .bangla: return "Bangla"
        case .vad: return "Speech detection"
        case .diarization: return "Speakers"
        }
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let info: ModelInfo
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName)
                    if info.recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text("\(info.detail) · \(KanFormat.bytes(info.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.modelDownloads[info.id] {
                ProgressView(value: progress).frame(width: 90)
                Button("Cancel") { model.cancelModelDownload(info.id) }.controlSize(.small)
            } else if info.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Installed")
                Button("Delete…") { confirmingDelete = true }
                    .controlSize(.small)
                    .confirmationDialog("Delete \(info.displayName)?", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive) { model.deleteModel(info.id) }
                    } message: {
                        Text("You can download it again later (\(KanFormat.bytes(info.sizeBytes))).")
                    }
            } else if info.downloadable {
                Button("Download") { model.downloadModel(info.id) }.controlSize(.small)
            }
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var usage: Int64?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Audio") {
                Toggle("Keep call audio after transcription", isOn: $model.settings.keepAudio)
                SettingsFootnote("Kept audio (compressed, about 15 MB per hour per side) lets you listen back and transcribe again. Without it, re-transcription isn't possible.")
                Picker("Delete kept audio after", selection: $model.settings.audioRetentionDays) {
                    Text("Never").tag(Int?.none)
                    Text("7 days").tag(Int?.some(7))
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                }
                .disabled(!model.settings.keepAudio)
                SettingsFootnote("Transcripts are never deleted. Starred calls always keep their audio.")
            }
            Section("Disk") {
                LabeledContent("Call audio and working files", value: usage.map(KanFormat.bytes) ?? "Calculating…")
                Button("Show in Finder") { model.environment.openURL(model.environment.callsDirectory) }
            }
            Section("Folders") {
                Button("Open the Library Folder") { model.environment.openURL(model.library.root) }
                Button("Open Kan's Application Support Folder") { model.environment.openURL(KanPaths.appSupport) }
                Button("Open the Logs Folder") { model.environment.openURL(KanPaths.logs) }
            }
        }
        .formStyle(.grouped)
        .task(id: model.libraryRevision) {
            let directory = model.environment.callsDirectory
            usage = await Task.detached(priority: .utility) { AppModel.diskUsage(of: directory) }.value
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Kan").font(.largeTitle.weight(.semibold))
            Text("কান — “ear”").foregroundStyle(.secondary)
            Text("Version \(Self.version)").font(.callout)
            if model.services.isMock {
                Text("Running with mock services (no real audio)").font(.caption).foregroundStyle(.orange)
            }
            Text("Kan records and transcribes your calls entirely on this Mac. It never uploads audio, transcripts or remembered voices; its only network use is downloading transcription models when you ask.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Logs") { model.environment.openURL(KanPaths.logs) }
                Button("Show Library") { model.environment.openURL(model.library.root) }
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? KanVersion.current
        if let build = info["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }
}
