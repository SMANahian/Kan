import Foundation
import KanCore

// MARK: - Settings & setup

extension AppModel {
    func saveSettings() {
        let previous = appliedSettings
        let current = settings
        do {
            try settingsStore.save(current)
        } catch {
            report("Couldn't save the settings", error: error, category: "settings")
        }
        settingsSnapshot.set(current)
        appliedSettings = current
        if previous.rememberVoices && !current.rememberVoices { deleteAllVoiceSamples() }
        if previous.aiSummarize && !current.aiSummarize { dropWaitingSummaries() }
        guard isStarted else { return }

        if DetectionConfig(settings: previous) != DetectionConfig(settings: current) {
            applyDetectionConfig()
        }
        if previous.globalHotkeysEnabled != current.globalHotkeysEnabled {
            applyHotkeys(enabled: current.globalHotkeysEnabled)
        }
        if previous.audioRetentionDays != current.audioRetentionDays {
            startRetentionSweeps()
        }
        if previous.libraryURL.standardizedFileURL != current.libraryURL.standardizedFileURL {
            libraryRelocationPending = current.libraryURL.standardizedFileURL != library.root.standardizedFileURL
            if libraryRelocationPending {
                KanLog.info("Library location changed to \(current.libraryURL.path); applies after relaunch", category: "settings")
            }
        }
        let readinessKeys = { (s: KanSettings) in [s.generalModelID, s.englishModelID, s.banglaModelID, s.languageMode.rawValue] }
        if readinessKeys(previous) != readinessKeys(current) || previous.diarize != current.diarize {
            refreshModelReadiness()
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        recheckLibrary()
        let permissions = services.permissions
        let calendar = environment.calendar
        Task { [weak self] in
            // `status` can block briefly (Apple-event checks), so read everything off the main thread.
            let (statuses, relaunch) = await Task.detached(priority: .userInitiated) {
                () -> ([PermissionKind: PermissionStatus], Set<PermissionKind>) in
                var out: [PermissionKind: PermissionStatus] = [:]
                var relaunch: Set<PermissionKind> = []
                for kind in PermissionKind.allCases {
                    out[kind] = kind == .calendar ? calendar.authorizationStatus() : permissions.status(kind)
                    if kind != .calendar, out[kind] == .granted, permissions.needsRelaunch(kind) { relaunch.insert(kind) }
                }
                return (out, relaunch)
            }.value
            guard let self else { return }
            if self.permissionStatuses != statuses { self.permissionStatuses = statuses }
            if self.permissionsNeedingRelaunch != relaunch { self.permissionsNeedingRelaunch = relaunch }
        }
    }

    // MARK: Library folder

    /// The library folder couldn't be read or created (`libraryProblem`): the menu says why until
    /// it can be.
    func noteLibraryProblem(_ message: String) {
        let problem = LibraryProblem(accessDenied: library.isRootAccessDenied, message: message)
        if libraryProblem != problem { libraryProblem = problem }
    }

    /// With a library problem, looks again (with the permissions: when Kan becomes active and when
    /// the menu opens) — the user may have allowed access in System Settings. Once the folder can
    /// be read, the library is loaded, watched, and the problem goes away. Recordings that couldn't
    /// be saved meanwhile are kept in the Calls folder and saved at the next launch.
    func recheckLibrary() {
        guard libraryProblem != nil else { return }
        guard !libraryRecheckRunning else {
            libraryRecheckAgain = true          // the running check may have started before the change
            return
        }
        libraryRecheckRunning = true
        libraryRecheckAgain = false
        let library = self.library
        Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try library.reconcile()
                    return nil
                } catch {
                    return AppModel.describe(error)
                }
            }.value
            guard let self else { return }
            self.libraryRecheckRunning = false
            if let failure {
                self.noteLibraryProblem(failure)
                if self.libraryRecheckAgain { self.recheckLibrary() }
                return
            }
            self.libraryProblem = nil
            KanLog.info("The library folder can be read again", category: "library")
            if let error = self.libraryWatcher?.start() { self.noteLibraryProblem(Self.describe(error)) }
            self.refreshSummaries()
        }
    }

    /// Whether iCloud Drive syncs the library folder (`libraryInICloud`), checked off the main thread.
    func refreshLibraryCloudStatus() {
        let root = library.root
        let check = environment.isInICloudDrive
        Task { [weak self] in
            let synced = await Task.detached(priority: .utility) { check(root) }.value
            guard let self else { return }
            if self.libraryInICloud != synced { self.libraryInICloud = synced }
            if synced { KanLog.warning("The library folder is synced by iCloud Drive", category: "library") }
        }
    }

    /// The folder on this Mac Kan offers when iCloud Drive syncs the library: "Kan" in the home
    /// folder (or "Kan 2"… when that one holds other files).
    var localLibrarySuggestion: URL {
        LibraryLocation.suggestedSubfolder(in: KanPaths.userHome)
    }

    /// "Keep the library on this Mac": the suggested folder becomes the library. Like any change of
    /// library folder it applies when Kan relaunches, and calls saved so far stay where they are.
    func useLocalLibrary() {
        settings.libraryPath = localLibrarySuggestion.path
        saveSettings()
    }

    /// Granted, but the grant reaches Kan only after a relaunch: shown as "Allowed — relaunch Kan
    /// to apply", with a Relaunch button, wherever the permission's state is shown.
    func needsRelaunch(_ kind: PermissionKind) -> Bool {
        permissionsNeedingRelaunch.contains(kind)
    }

    func requestPermission(_ kind: PermissionKind) async {
        KanLog.info("Requesting permission: \(kind.rawValue)", category: "permissions")
        let status: PermissionStatus
        if kind == .calendar {
            status = await environment.calendar.requestAccess()
        } else {
            status = await services.permissions.request(kind)
        }
        permissionStatuses[kind] = status
        KanLog.info("Permission \(kind.rawValue): \(status.rawValue)", category: "permissions")
        if kind == .systemAudio, status != .granted {
            postInfo("System Audio Recording", message: "If you allowed Kan in System Settings, relaunch Kan to apply it.",
                     buttons: [.init(title: "Relaunch Kan", command: .relaunch, role: .primary)], seconds: 20)
        }
        refreshPermissions()
    }

    func openPermissionSettings(_ kind: PermissionKind) {
        if kind == .calendar,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            environment.openURL(url)
        } else {
            services.permissions.openSystemSettings(kind)
        }
    }

    // MARK: Models

    func refreshModelReadiness() {
        Task { [weak self] in await self?.updateModelReadiness() }
    }

    /// Reads whether Kan can transcribe and which models are installed (off the main thread) and
    /// publishes both; once it can transcribe, the calls that waited for a model are queued again.
    func updateModelReadiness() async {
        let models = services.models
        let current = settings
        let (readiness, catalog) = await Task.detached(priority: .utility) {
            (models.readiness(for: current), models.availableModels())
        }.value
        if modelReadiness != readiness { modelReadiness = readiness }
        if availableModels != catalog { availableModels = catalog }
        if readiness.canTranscribe {
            retryCallsWaitingForModels(installed: Set(catalog.filter(\.installed).map(\.id)))
        }
    }

    /// The queue keeps the calls whose transcription failed because a model wasn't installed
    /// (`ProcessingQueue.retryWaitingForModels`). They are queued again once Kan can transcribe: at
    /// launch, and whenever the installed models change (a download). A call still missing its
    /// model fails again and waits, and the same installed models never retry it twice, so this
    /// can't loop; the queue skips calls already queued or running, so nothing is queued twice.
    func retryCallsWaitingForModels(installed: Set<String>) {
        guard let queue, installed != modelsRetriedFor else { return }
        modelsRetriedFor = installed
        queue.retryWaitingForModels()
    }

    func downloadModel(_ id: String) {
        guard downloadTasks[id] == nil else { return }
        let models = services.models
        modelDownloads[id] = 0
        KanLog.info("Downloading model \(id)", category: "models")
        downloadTasks[id] = Task { [weak self] in
            do {
                try await models.download(id) { fraction in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.modelDownloads[id] != nil else { return }
                            self.modelDownloads[id] = min(1, max(self.modelDownloads[id] ?? 0, fraction))
                        }
                    }
                }
                guard let self else { return }
                let name = self.availableModels.first { $0.id == id }?.displayName ?? id
                KanLog.info("Downloaded model \(id)", category: "models")
                self.postInfo("Downloaded \(name)", seconds: 4)
                // A new model pays its one-time compilation in the warm-up, not in the first call.
                self.scheduleModelWarmUp()
            } catch is CancellationError {
                KanLog.info("Download of \(id) cancelled", category: "models")
            } catch {
                self?.report("Couldn't download \(id)", error: error, category: "models")
            }
            guard let self else { return }
            self.downloadTasks[id] = nil
            self.modelDownloads[id] = nil
            // After a download, this queues the calls that waited for a model again.
            await self.updateModelReadiness()
        }
    }

    func cancelModelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    func deleteModel(_ id: String) {
        do {
            try services.models.delete(id)
            WarmUpRecord.forget(id)
            KanLog.info("Deleted model \(id)", category: "models")
        } catch {
            report("Couldn't delete \(id)", error: error, category: "models")
        }
        refreshModelReadiness()
    }

    /// Recommended models that aren't installed yet, for jobs no installed model does
    /// (onboarding's one-click download): an installed full large-v3 already does what the
    /// recommended large-v3 q5_0 would, so the 1 GB download isn't offered next to "Kan can
    /// transcribe with what's installed".
    var missingRecommendedModels: [ModelInfo] {
        let covered = Set(availableModels.filter(\.installed).map(\.role))
        return availableModels.filter { $0.recommended && !$0.installed && $0.downloadable && !covered.contains($0.role) }
    }

    // MARK: Voices

    func refreshRememberedVoices() {
        let count = voiceprints.people().count
        if rememberedVoiceCount != count { rememberedVoiceCount = count }
        let calls = environment.callsDirectory
        Task { [weak self] in
            let samples = await Task.detached(priority: .utility) { SpeakerEmbeddingsFile.count(in: calls) }.value
            guard let self, self.voiceSampleCallCount != samples else { return }
            self.voiceSampleCallCount = samples
        }
    }

    /// "Forget All Voices" has something to delete: remembered people, or calls' voice samples
    /// (with Keep call audio off they outlive the audio, so there can be samples and no one yet).
    var canForgetVoices: Bool { rememberedVoiceCount > 0 || voiceSampleCallCount > 0 }

    func forgetAllVoices() {
        do {
            try voiceprints.forgetAll()
            KanLog.info("Forgot every remembered voice", category: "voiceprints")
        } catch {
            report("Couldn't forget the remembered voices", error: error, category: "voiceprints")
        }
        refreshRememberedVoices()
    }

    /// Remember voices was turned off (Settings, onboarding: `saveSettings` notices): the voice
    /// samples kept with every call to remember a voice when a speaker is named are deleted, off
    /// the main thread. The queue keeps none from then on; remembered voices stay until "Forget
    /// All Voices".
    func deleteAllVoiceSamples() {
        let calls = environment.callsDirectory
        KanLog.info("Remember voices turned off; deleting the voice samples kept with calls", category: "voiceprints")
        Task { [weak self] in
            await Task.detached(priority: .utility) { _ = SpeakerEmbeddingsFile.deleteAll(in: calls) }.value
            self?.refreshRememberedVoices()
        }
    }

    // MARK: Launch at login

    func refreshLoginItemStatus() {
        let status = environment.loginItem.status
        if loginItemStatus != status { loginItemStatus = status }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try environment.loginItem.setEnabled(enabled)
            KanLog.info("Launch at login \(enabled ? "enabled" : "disabled")", category: "settings")
        } catch {
            report("Couldn't change Launch at login", error: error, category: "settings")
        }
        refreshLoginItemStatus()
        if enabled, loginItemStatus == .requiresApproval {
            environment.loginItem.openSystemSettings()
        }
    }

    // MARK: Global hot keys

    func applyHotkeys(enabled: Bool) {
        guard let hotkeys = environment.hotkeys else { return }
        hotkeyFailures = hotkeys.setEnabled(enabled) { [weak self] key in
            self?.handleHotkey(key)
        }
        if !hotkeyFailures.isEmpty {
            KanLog.warning("Couldn't register hot keys: \(hotkeyFailures.map(\.displayName).joined(separator: ", "))",
                           category: "hotkeys")
        }
    }

    func handleHotkey(_ key: GlobalHotkey) {
        KanLog.info("Hot key \(key.displayName)", category: "hotkeys")
        switch key {
        case .addBookmark:
            if active != nil {
                addBookmark()
            } else {
                postInfo("Nothing is being recorded", message: "⌃⌥⌘R starts a recording.", seconds: 3)
            }
        case .openLibrary:
            openLibrary()
        case .toggleRecording:
            toggleManualRecording()
        }
    }

    // MARK: Onboarding

    func completeOnboarding(launchAtLogin: Bool) {
        settings.onboardingCompleted = true
        saveSettings()
        refreshLoginItemStatus()
        switch loginItemStatus {
        case .unavailable:
            break       // a development build outside an app bundle
        case .enabled, .requiresApproval:
            if !launchAtLogin { setLaunchAtLogin(false) }
        case .disabled:
            if launchAtLogin { setLaunchAtLogin(true) }
        }
        KanLog.info("Onboarding completed (launch at login: \(launchAtLogin))", category: "settings")
    }

    // MARK: AI agents

    /// The `kan` CLI shipped inside Kan.app (next to KanApp when running from a build directory).
    var commandLineToolURL: URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.appendingPathComponent("Contents/MacOS/kan")
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("kan")
    }

    /// Links ~/.local/bin/kan to the bundled CLI. Returns a message for the user.
    func installCommandLineTool() async -> CommandLineInstallResult {
        let source = commandLineToolURL
        let result = await Task.detached(priority: .userInitiated) {
            CommandLineInstaller.install(source: source)
        }.value
        switch result {
        case .installed(let link, let onPath):
            KanLog.info("Linked \(link.path) → \(source.path) (on PATH: \(onPath.map { $0 ? "yes" : "no" } ?? "unknown"))", category: "agents")
        case .failed(let message):
            KanLog.error("Couldn't install the kan command: \(message)", category: "agents")
        }
        return result
    }
}
