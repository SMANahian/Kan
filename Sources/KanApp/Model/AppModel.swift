import AppKit
import Foundation
import Observation
import KanCore

// CONTRACT between the two UI agents.
//  - The "app shell" agent implements every body here (and may add members).
//  - The "library window" agent only USES this API (plus LibraryStore/TranscriptRenderer from KanCore).
// Keep existing signatures stable.
//
// Implementation map: this file holds the shared types, state, lifecycle, notices and the label
// panel queue; the flows live in AppModel+Recording.swift (detection and recording),
// AppModel+Library.swift (library actions), AppModel+Setup.swift (settings, permissions, models)
// and AppModel+Maintenance.swift (crash recovery, audio retention).

/// The services the UI talks to. Live implementations come from KanAudio / KanDetect /
/// KanTranscribe (wired in Services/LiveServices.swift at integration); MockServices drive the UI
/// without real audio (set KAN_MOCK=1, or used automatically if live services can't be created).
struct KanServices {
    var detector: CallDetecting
    var recorder: CallRecording
    var transcriber: Transcribing
    var models: ModelManaging
    var permissions: PermissionsProviding
    var archiver: AudioArchiving?
    var isMock: Bool
}

/// What the menu bar shows.
enum RecorderPhase: Equatable {
    case idle
    case recording
    /// Mic released; recording continues until the deadline unless the call resumes.
    case ending(deadline: Date)
    /// Long silence on both tracks; waiting for "still in a call?".
    case stale
}

/// The call being recorded right now.
struct LiveCall: Equatable, Identifiable {
    var id: CallID
    var detected: DetectedCall
    var startedAt: Date
    /// Unknown app: recording tentatively until the user answers "Record this call?".
    var isTentative: Bool
    var isPaused: Bool
    var title: String
    var bookmarks: [Bookmark]

    var appName: String { detected.app.name }
}

/// Targets for "Start recording ▸" in the menu.
enum ManualTarget: Hashable {
    case app(AppActivity)
    case systemAudio
    case micOnly
}

/// Ask the library window to show a call (optionally playing from a time).
struct LibraryFocusRequest: Equatable {
    var callID: CallID
    var time: Double?
    var nonce = UUID()
}

/// The state the menu-bar icon shows, most important first.
enum MenuBarIndicator: Equatable {
    case recording(elapsed: TimeInterval)
    case paused(elapsed: TimeInterval)
    case ending(remaining: TimeInterval)
    case stale(elapsed: TimeInterval)
    case problem
    case transcribing(fraction: Double?)
    case needsLabeling(Int)
    case idle
}

/// Something the user should fix, shown in the menu.
struct AppProblem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: NoticeCommand?
}

/// Why the library folder can't be used: macOS denied access (Don't Allow on the Documents
/// prompt), or the folder can't be read or created for another reason.
struct LibraryProblem: Equatable {
    var accessDenied: Bool
    var message: String
}

/// The recorder side of the live call (not observed by views; `AppModel.liveCall` mirrors what
/// the UI needs). Main-actor confined.
@MainActor
final class ActiveRecording {
    let callID: CallID
    var call: DetectedCall
    let handle: RecordingHandle
    let directory: URL
    let target: CaptureTarget
    var manifest: RecordingManifest
    var pollTask: Task<Void, Never>?
    var reportedIssues: Set<RecordingIssue> = []
    /// When the call app let go of the microphone, while the end-of-call countdown runs (nil
    /// otherwise). Stopping during the countdown trims the recording there.
    var micReleasedAt: Date?

    init(callID: CallID, call: DetectedCall, handle: RecordingHandle, directory: URL, target: CaptureTarget,
         manifest: RecordingManifest) {
        self.callID = callID
        self.call = call
        self.handle = handle
        self.directory = directory
        self.target = target
        self.manifest = manifest
    }

    var isTentative: Bool { manifest.isTentative }
}

/// A tentative recording that ended before the user answered "Record this call?".
struct UnconfirmedRecording {
    var manifest: RecordingManifest
    var result: RecordingResult
    var noticeID: UUID?
}

/// App-wide state and every user-facing flow. Main-actor isolated: services call back on any
/// thread and their callbacks hop to the main actor before touching this object.
@MainActor
@Observable
final class AppModel {
    // MARK: Services & stores
    let services: KanServices
    let settingsStore: SettingsStore
    let voiceprints: VoiceprintStore
    private(set) var library: LibraryStore
    private(set) var queue: ProcessingQueue?

    // MARK: Observable state
    /// Edit, then call `saveSettings()`.
    var settings: KanSettings
    var phase: RecorderPhase = .idle
    var liveCall: LiveCall?
    var levels: AudioLevels = .zero
    /// Library rows, newest first (kept in sync with LibraryStore.onChange).
    var summaries: [CallSummary] = []
    var processing: [CallID: ProcessingStatus] = [:]
    /// Calls waiting for (or showing) the post-call label panel, oldest first.
    var pendingLabels: [CallID] = []
    var detectionPausedUntil: Date?
    /// True while detection is paused indefinitely (until the user resumes it).
    var detectionPausedIndefinitely = false
    var permissionStatuses: [PermissionKind: PermissionStatus] = [:]
    var modelReadiness: ModelReadiness?
    /// Download progress 0…1 by model id while downloading.
    var modelDownloads: [String: Double] = [:]
    /// Last user-visible error (shown in the menu).
    var lastError: String?
    /// The library window observes this and selects / seeks.
    var libraryFocus: LibraryFocusRequest?

    // MARK: Additional observable state (app shell)
    /// Floating toasts and prompts, oldest first (rendered by ToastPresenter).
    var notices: [AppNotice] = []
    /// The call shown in the post-call label panel (one of `pendingLabels`), nil when hidden.
    var presentedLabel: CallID?
    /// Wall-clock "now", refreshed every second while recording (drives the menu-bar timers).
    var now: Date
    /// The model catalog with install state (refreshed by `refreshModelReadiness()`).
    var availableModels: [ModelInfo] = []
    var loginItemStatus: LoginItemStatus = .disabled
    /// True once `start()` has loaded the library and started detection.
    var isStarted = false
    /// Incremented for a call every time its record is saved (views reload the record on change).
    var recordRevisions: [CallID: Int] = [:]
    /// Incremented on every library change (including reloads).
    var libraryRevision = 0
    /// Set by "Search calls…": the library window focuses its search field when this changes.
    var librarySearchRequest: UUID?
    /// The library location changed in Settings; it applies after a relaunch.
    var libraryRelocationPending = false
    /// Issues reported by the live recording.
    var recordingIssues: [RecordingIssue] = []
    /// Global hot keys that couldn't be registered (taken by another app).
    var hotkeyFailures: [GlobalHotkey] = []
    /// Remembered voices (count shown in Settings).
    var rememberedVoiceCount = 0
    /// Calls that keep voice samples of their speakers (Settings; refreshed with the count above).
    var voiceSampleCallCount = 0
    /// Permissions that are granted but reach Kan only after a relaunch (System Audio Recording
    /// turned on in System Settings while Kan runs). Refreshed with `permissionStatuses`.
    var permissionsNeedingRelaunch: Set<PermissionKind> = []
    /// The library folder can't be read or created, so calls can't be saved (shown in the menu
    /// until it can; checked again with the permissions).
    var libraryProblem: LibraryProblem?
    /// iCloud Drive syncs the folder calls are saved in (Desktop & Documents in iCloud puts the
    /// default ~/Documents/Kan there): macOS uploads every transcript. Onboarding and Settings
    /// say so and offer a folder on this Mac (`useLocalLibrary`).
    var libraryInICloud = false

    // MARK: Internals (not observed)
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored weak var ui: AppUIBridge?
    @ObservationIgnored let settingsSnapshot: SettingsSnapshot
    /// The settings the services were last configured with (to apply only what changed).
    @ObservationIgnored var appliedSettings: KanSettings
    @ObservationIgnored var active: ActiveRecording? {
        didSet { updateActivities() }
    }
    @ObservationIgnored var unconfirmed: [CallID: UnconfirmedRecording] = [:]
    @ObservationIgnored var finalizations: [CallID: Task<Void, Never>] = [:] {
        didSet { updateActivities() }
    }
    @ObservationIgnored var queuePausedForCall = false
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored var isTerminating = false
    @ObservationIgnored var noticeTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var detectionPauseTask: Task<Void, Never>?
    @ObservationIgnored var retentionTask: Task<Void, Never>?
    @ObservationIgnored var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var summariesRefreshPending = false
    @ObservationIgnored var retentionSweepRunning = false
    @ObservationIgnored var libraryWatcher: LibraryWatcher?
    /// Polls while a pending label panel waits for an unrecorded call to end.
    @ObservationIgnored var labelWaitTask: Task<Void, Never>?
    @ObservationIgnored var warmUpTask: Task<Void, Never>?
    /// The installed models the calls waiting for a model were last queued again with (nil: not
    /// yet this launch).
    @ObservationIgnored var modelsRetriedFor: Set<String>?
    /// Power activities held against App Nap, by reason (`updateActivities`).
    @ObservationIgnored var activityTokens: [String: NSObjectProtocol] = [:]
    @ObservationIgnored var libraryRecheckRunning = false
    @ObservationIgnored var libraryRecheckAgain = false

    convenience init(services: KanServices, settingsStore: SettingsStore = SettingsStore(),
                     voiceprints: VoiceprintStore = VoiceprintStore()) {
        self.init(services: services, settingsStore: settingsStore, voiceprints: voiceprints, environment: .live())
    }

    /// Full initializer: the self-test passes a headless environment with a mock clock.
    init(services: KanServices, settingsStore: SettingsStore, voiceprints: VoiceprintStore,
         environment: AppEnvironment) {
        self.services = services
        self.settingsStore = settingsStore
        self.voiceprints = voiceprints
        self.environment = environment
        let settings = settingsStore.load()
        self.settings = settings
        self.appliedSettings = settings
        self.settingsSnapshot = SettingsSnapshot(settings)
        let calls = environment.callsDirectory
        self.library = LibraryStore(root: settings.libraryURL,
                                    callDataDirectory: { AppEnvironment.callDataDirectory(for: $0, in: calls) })
        self.now = environment.now()
    }

    // MARK: Lifecycle

    /// Called once from the app delegate after launch: reload library, start detection, resume queue,
    /// recover orphaned recordings, apply audio retention.
    func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            await self?.startUp()
        }
    }

    /// `start()`, awaiting the end of startup (used by the self-test).
    func startAndWait() async {
        start()
        await startupTask?.value
    }

    private func startUp() async {
        KanLog.info("Kan \(KanVersion.current) starting with \(services.isMock ? "mock" : "live") services; library \(library.root.path)")
        KanPaths.ensureDirectories()
        do {
            try FileManager.default.createDirectory(at: environment.callsDirectory, withIntermediateDirectories: true)
        } catch {
            KanLog.error("Couldn't create \(environment.callsDirectory.path): \(error.localizedDescription)")
        }

        // The library loads off the main thread (it decodes every call in parallel). `reconcile()`
        // is that same full rescan plus re-rendering the Markdown of calls whose JSON was edited
        // while Kan wasn't running (by an agent or an editor), so no transcript stays stale until
        // the library window opens. One scan: a reload first would decode every call twice.
        let library = self.library
        let loadError = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try library.reconcile()
                return nil
            } catch {
                let reason = library.isRootAccessDenied ? "access denied" : AppModel.logDescription(error)
                KanLog.error("Couldn't load the library: \(reason)", category: "library")
                return AppModel.describe(error)
            }
        }.value
        if let loadError { noteLibraryProblem(loadError) }
        library.onChange = { [weak self] change in
            // FIFO onto the main queue, so changes are applied in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.libraryDidChange(change) }
            }
        }
        refreshSummaries()

        let snapshot = settingsSnapshot
        let calls = environment.callsDirectory
        let queue = ProcessingQueue(library: library, transcriber: services.transcriber, archiver: services.archiver,
                                    voiceprints: voiceprints, settings: { snapshot.get() },
                                    callDataDirectory: { AppEnvironment.callDataDirectory(for: $0, in: calls) })
        queue.onUpdate = { [weak self] status in self?.processingDidUpdate(status) }
        self.queue = queue
        await Task.detached(priority: .utility) { queue.resumePersistedJobs() }.value
        for status in queue.statuses() where status.state != .done {
            processing[status.callID] = status
        }
        updateActivities()

        await recoverOrphanedRecordings()
        requeueStrandedCalls()

        services.detector.onEvent = { [weak self] event in self?.handleDetection(event) }
        services.detector.update(config: detectionConfig)
        services.detector.start()

        refreshPermissions()
        refreshLibraryCloudStatus()
        refreshModelReadiness()
        refreshLoginItemStatus()
        refreshRememberedVoices()
        startRetentionSweeps()
        scheduleModelWarmUp()
        applyHotkeys(enabled: settings.globalHotkeysEnabled)
        if !environment.isHeadless {
            let watcher = LibraryWatcher(root: library.root) { [weak self] in self?.reloadLibrary() }
            // It creates the library folder: the first access to ~/Documents, and macOS's prompt.
            if let error = watcher.start(), libraryProblem == nil { noteLibraryProblem(Self.describe(error)) }
            libraryWatcher = watcher
        }
        isStarted = true
        updateActivities()
        KanLog.info("Kan started: \(summaries.count) calls, \(processing.count) transcription job(s)")
        if !settings.onboardingCompleted { ui?.openOnboarding() }
    }

    /// Called on quit / SIGTERM: finalize any live recording (save it, queue it).
    func prepareForTermination() async {
        guard !isTerminating else { return }
        isTerminating = true
        KanLog.info("Preparing to quit")
        // Stop GPU work first, so saving the live call can't start a transcription on the way out
        // (`resumeQueueAfterCall` stays put while quitting). Interrupted and new jobs stay in
        // queue.json and run at the next launch.
        queue?.pause()
        if let recording = detachActive() {
            tellDetectorRecordingStopped(recording)
            finish(recording, reason: .termination)
        }
        // Unanswered "keep this recording?" questions: keep the audio (never lose a recording on quit).
        for id in Array(unconfirmed.keys) { keepUnconfirmed(id) }
        await waitForFinalizations()
        labelWaitTask?.cancel()
        labelWaitTask = nil
        warmUpTask?.cancel()
        warmUpTask = nil
        services.detector.stop()
        environment.hotkeys?.setEnabled(false) { _ in }
        libraryWatcher?.stop()
        retentionTask?.cancel()
        detectionPauseTask?.cancel()
        downloadTasks.values.forEach { $0.cancel() }
        noticeTimers.values.forEach { $0.cancel() }
        KanLog.info("Ready to quit")
    }

    /// Waits until every stopped recording has been saved (or discarded).
    func waitForFinalizations() async {
        while let (id, task) = finalizations.first {
            await task.value
            // Each task removes itself; make sure a finished one can't keep this loop going.
            if finalizations[id] == task { finalizations[id] = nil }
        }
    }

    // MARK: Library sync

    func libraryDidChange(_ change: LibraryChange) {
        switch change {
        case .saved(let id):
            recordRevisions[id, default: 0] += 1
        case .deleted(let id):
            recordRevisions[id] = nil
            pendingLabels.removeAll { $0 == id }
            if presentedLabel == id { presentedLabel = nil }
        case .reloaded:
            break
        }
        libraryRevision += 1
        scheduleSummariesRefresh()
    }

    private func scheduleSummariesRefresh() {
        guard !summariesRefreshPending else { return }
        summariesRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.summariesRefreshPending = false
                self.refreshSummaries()
            }
        }
    }

    func refreshSummaries() {
        let fresh = library.summaries()
        if fresh != summaries { summaries = fresh }
        updateLabelPresentation()
    }

    func processingDidUpdate(_ status: ProcessingStatus) {
        let id = status.callID
        switch status.state {
        case .done:
            processing[id] = nil
        case .failed, .cancelled:
            // Deleting a call (or its audio) cancels its job, and the news arrives after the
            // delete, as do the job's own last words: then there's nothing to show or retry. Jobs
            // are reported in order, so such a job's last status is always one of these.
            processing[id] = canRetryTranscription(id) ? status : nil
        case .queued, .running, .paused:
            processing[id] = status
        }
        updateActivities()
    }

    // MARK: App Nap

    static let recordingActivity = "Recording a call"
    static let transcribingActivity = "Transcribing a call"
    static let detectingActivity = "Detecting calls"

    /// Kan has no window open while it records or transcribes, so App Nap would coalesce its timers
    /// — the recorder's 50 ms pump drains a 10 s capture ring, the detector's end-of-call deadline
    /// and silence checks — and lower its priority. It holds a user-initiated activity (which also
    /// keeps the Mac from idle sleep) from the start of a recording until it is saved, and while a
    /// transcription runs. While call detection is on it also opts out of App Nap, idle sleep still
    /// allowed: a call is recorded once the detector's once-a-second tick confirms it, and a napping
    /// Kan would confirm late and miss more of the call's start.
    func updateActivities() {
        holdActivity(Self.recordingActivity, while: active != nil || !finalizations.isEmpty)
        holdActivity(Self.transcribingActivity, while: processing.values.contains { $0.state == .running })
        holdActivity(Self.detectingActivity, options: .userInitiatedAllowingIdleSystemSleep, while: isDetecting)
    }

    /// Call detection is running: started, on in Settings and not paused.
    var isDetecting: Bool {
        isStarted && settings.autoDetect && !detectionPausedIndefinitely && detectionPausedUntil == nil
    }

    /// Hands the detector the current settings and pause state.
    func applyDetectionConfig() {
        services.detector.update(config: detectionConfig)
        updateActivities()
    }

    private func holdActivity(_ reason: String, options: ProcessInfo.ActivityOptions = .userInitiated, while needed: Bool) {
        if needed, activityTokens[reason] == nil {
            activityTokens[reason] = environment.beginActivity(options, reason)
        } else if !needed, let token = activityTokens.removeValue(forKey: reason) {
            environment.endActivity(token)
        }
    }

    /// Forgets failed and cancelled jobs the queue no longer lists (it keeps them for a while,
    /// then drops them without telling anyone) and those that can't be retried. The menu calls
    /// this when it opens.
    func pruneFinishedProcessing() {
        guard let queue else { return }
        let finished = processing.values.filter { $0.state == .failed || $0.state == .cancelled }.map(\.callID)
        guard !finished.isEmpty else { return }
        let listed = Set(queue.statuses().map(\.callID))
        for id in finished where !listed.contains(id) || !canRetryTranscription(id) {
            processing[id] = nil
        }
    }

    /// The call is still in the library with audio to transcribe again.
    private func canRetryTranscription(_ id: CallID) -> Bool {
        library.contains(id) && record(id)?.audio?.isAvailable == true
    }

    /// A transcription is queued, running or waiting for the call to end.
    var isTranscribing: Bool {
        processing.values.contains { [.queued, .running, .paused].contains($0.state) }
    }

    // MARK: Derived state for the menu bar

    /// Unlabeled calls, newest first ("Needs labeling").
    var needsLabeling: [CallSummary] { summaries.filter { !$0.labeled } }

    var recentCalls: [CallSummary] { Array(summaries.prefix(5)) }

    /// Queued, running and paused jobs (oldest first), then failed ones.
    var activeProcessing: [ProcessingStatus] {
        let order: [ProcessingStatus.State: Int] = [.running: 0, .paused: 1, .queued: 2, .failed: 3, .cancelled: 4]
        return processing.values
            .filter { $0.state != .done }
            .sorted { a, b in
                let x = order[a.state] ?? 9, y = order[b.state] ?? 9
                return x != y ? x < y : a.callID < b.callID
            }
    }

    func summary(for id: CallID) -> CallSummary? {
        summaries.first { $0.id == id } ?? library.summary(id)
    }

    var menuBarIndicator: MenuBarIndicator {
        if let live = liveCall {
            let elapsed = max(0, now.timeIntervalSince(live.startedAt))
            switch phase {
            case .ending(let deadline): return .ending(remaining: max(0, deadline.timeIntervalSince(now)))
            case .stale: return .stale(elapsed: elapsed)
            case .idle, .recording: return live.isPaused ? .paused(elapsed: elapsed) : .recording(elapsed: elapsed)
            }
        }
        if !problems.isEmpty { return .problem }
        let running = processing.values.filter { $0.state == .running || $0.state == .queued }
        if !running.isEmpty {
            return .transcribing(fraction: running.first(where: { $0.state == .running })?.progress?.fraction)
        }
        let unlabeled = needsLabeling.count
        if unlabeled > 0 { return .needsLabeling(unlabeled) }
        return .idle
    }

    /// Things the user should fix, most important first.
    var problems: [AppProblem] {
        var out: [AppProblem] = []
        if permissionStatuses[.microphone] == .denied {
            out.append(AppProblem(id: "mic", title: "Microphone access is off",
                                  detail: "Kan can't record your side of calls.",
                                  actionTitle: "Open Settings", action: .openSystemSettings(.microphone)))
        }
        if let libraryProblem {
            let folder = (library.root.path as NSString).abbreviatingWithTildeInPath
            out.append(libraryProblem.accessDenied
                ? AppProblem(id: "library", title: "Kan can't open its library folder",
                             detail: "macOS denied Kan access to \(folder), so calls can't be saved. Allow Kan under Privacy & Security › Files & Folders, or choose another library folder in Settings.",
                             actionTitle: "Open Settings", action: .openFilesAndFoldersSettings)
                : AppProblem(id: "library", title: "Kan can't use its library folder", detail: libraryProblem.message,
                             actionTitle: "Settings…", action: .openSettings))
        }
        if permissionStatuses[.systemAudio] == .denied {
            out.append(AppProblem(id: "systemAudio", title: "System Audio Recording is off",
                                  detail: "Kan can't record the other side of calls.",
                                  actionTitle: "Open Settings", action: .openSystemSettings(.systemAudio)))
        }
        let systemAudioNeedsRelaunch = needsRelaunch(.systemAudio)
        if systemAudioNeedsRelaunch && !recordingIssues.contains(.systemAudioSilent) {
            out.append(AppProblem(id: "systemAudioRelaunch", title: "System Audio Recording: allowed — relaunch Kan to apply",
                                  detail: "Until then, Kan can't record the other side of calls.",
                                  actionTitle: "Relaunch", action: .relaunch))
        }
        if let readiness = modelReadiness, !readiness.canTranscribe {
            out.append(AppProblem(id: "models", title: "Transcription models are missing",
                                  detail: readiness.missing.first, actionTitle: "Settings…", action: .openSettings))
        }
        if recordingIssues.contains(.systemAudioSilent) {
            out.append(systemAudioNeedsRelaunch
                ? AppProblem(id: "silent", title: "Kan can't hear the other side",
                             detail: "System Audio Recording is allowed, but it applies only after Kan relaunches.",
                             actionTitle: "Relaunch", action: .relaunch)
                : AppProblem(id: "silent", title: "Kan can't hear the other side",
                             detail: "Grant System Audio Recording, then relaunch Kan.",
                             actionTitle: "Open Settings", action: .openSystemSettings(.systemAudio)))
        }
        if let lastError {
            out.append(AppProblem(id: "error", title: lastError, detail: nil, actionTitle: nil, action: nil))
        }
        return out
    }

    /// The Debug submenu: mock services, or KAN_DEBUG=1.
    var isDebugMenuAvailable: Bool {
        services.isMock || ProcessInfo.processInfo.environment["KAN_DEBUG"] == "1"
    }

    var mockDetector: MockCallDetector? { services.detector as? MockCallDetector }

    func clearLastError() { lastError = nil }

    /// Logs an error and shows it in the menu. The log outlives deleted calls, so it never gets
    /// call content: when `message` names a call, folder or person, pass `log`, the same news with
    /// ids and counts only. The error itself is logged as `logDescription` describes it.
    func report(_ message: String, error: Error? = nil, category: String = "app", log logMessage: String? = nil) {
        let detail = error.map { Self.describe($0) }
        let text = detail.map { "\(message): \($0)" } ?? message
        let logged = logMessage ?? message
        KanLog.error(error.map { "\(logged): \(Self.logDescription($0))" } ?? logged, category: category)
        lastError = text
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `describe(error)` for the log (`KanLog.describe`). Library errors and Cocoa file errors
    /// quote call titles, folder names and file names (which embed titles), so only their kind and
    /// code are logged; other errors (devices, downloads, models, voices) are described in full.
    nonisolated static func logDescription(_ error: Error) -> String {
        KanLog.describe(error)
    }

    // MARK: Notices

    @discardableResult
    func post(_ notice: AppNotice) -> UUID {
        // One notice per kind (a repeated problem replaces the old one instead of stacking).
        for old in notices where old.kind == notice.kind { cancelNoticeTimer(old.id) }
        notices.removeAll { $0.kind == notice.kind }
        notices.append(notice)
        scheduleAutoHide(notice.id, after: notice.autoHideAfter)
        return notice.id
    }

    func dismissNotice(_ id: UUID) {
        cancelNoticeTimer(id)
        notices.removeAll { $0.id == id }
    }

    func removeNotices(where predicate: (AppNotice) -> Bool) {
        for notice in notices where predicate(notice) { cancelNoticeTimer(notice.id) }
        notices.removeAll(where: predicate)
    }

    /// Hovering a toast pauses its auto-hide countdown; leaving restarts a short one.
    func noticeHoverChanged(_ id: UUID, hovering: Bool) {
        guard let notice = notices.first(where: { $0.id == id }), notice.autoHideAfter != nil else { return }
        if hovering {
            cancelNoticeTimer(id)
        } else {
            scheduleAutoHide(id, after: 3)
        }
    }

    /// A notice button (or the equivalent menu item) was pressed.
    func perform(_ command: NoticeCommand, on noticeID: UUID? = nil) {
        if let noticeID { dismissNotice(noticeID) }
        switch command {
        case .record: respondToAsk(.record)
        case .notNow: respondToAsk(.notNow)
        case .never: neverRecordLiveApp()
        case .keepRecording: keepRecording()
        case .stopAndSave: stopRecording()
        case .discardRecording: discardCurrentRecording()
        case .pauseRecording: pauseRecording()
        case .keepUnconfirmed(let id): keepUnconfirmed(id)
        case .discardUnconfirmed(let id): discardUnconfirmed(id, never: false)
        case .neverUnconfirmed(let id): discardUnconfirmed(id, never: true)
        case .openSystemSettings(let kind): openPermissionSettings(kind)
        case .openFilesAndFoldersSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                environment.openURL(url)
            }
        case .relaunch: environment.relaunch()
        case .label(let id): labelNow(id)
        case .showInLibrary(let id): showInLibrary(id)
        case .openLibrary: openLibrary()
        case .openSettings: openSettings()
        case .dismiss: break
        }
    }

    private func scheduleAutoHide(_ id: UUID, after seconds: TimeInterval?) {
        cancelNoticeTimer(id)
        guard let seconds else { return }
        noticeTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissNotice(id)
        }
    }

    private func cancelNoticeTimer(_ id: UUID) {
        noticeTimers[id]?.cancel()
        noticeTimers[id] = nil
    }

    func postInfo(_ title: String, message: String? = nil, buttons: [AppNotice.Button] = [], seconds: TimeInterval = 6) {
        post(AppNotice(kind: .info(title), style: .info, title: title, message: message, buttons: buttons,
                       autoHideAfter: seconds, createdAt: environment.now()))
    }

    func postProblem(_ title: String, message: String? = nil, buttons: [AppNotice.Button] = []) {
        post(AppNotice(kind: .problem(title), style: .warning, title: title, message: message, buttons: buttons,
                       createdAt: environment.now()))
    }

    // MARK: Label panel queue

    /// Shows the next pending label panel when nothing is live and no panel is open.
    ///
    /// The panel takes the keyboard when it appears, so it also waits while the user is in a call
    /// Kan isn't recording: they stopped or declined the recording mid-call ("Stop & Save",
    /// "Don't record", "Not now"), or a back-to-back call wasn't recorded. Otherwise typing meant
    /// for the meeting (chat, ⌘D, push-to-talk) would land in the panel. It appears once that app
    /// lets go of the microphone; "Label now" doesn't wait.
    func updateLabelPresentation() {
        if let shown = presentedLabel, !library.contains(shown) { presentedLabel = nil }
        guard presentedLabel == nil, active == nil, !isTerminating else { return }
        pendingLabels.removeAll { !library.contains($0) }
        guard let next = pendingLabels.first else { return }
        if let app = appInUnrecordedCall() {
            waitForUnrecordedCall(of: app)
            return
        }
        presentedLabel = next
    }

    /// "Label now" (menu / recovered-recording toast): queue this call first and show it. An
    /// explicit request, so only a live recording makes it wait.
    func labelNow(_ id: CallID) {
        guard library.contains(id) else { return }
        pendingLabels.removeAll { $0 == id }
        pendingLabels.insert(id, at: 0)
        guard active == nil, !isTerminating else { return }
        presentedLabel = id
    }

    /// An app (not Kan) holding the microphone for what Kan treats as a possible call — any app
    /// whose policy isn't "never" — while Kan isn't recording it. nil when there's none.
    func appInUnrecordedCall() -> AppIdentity? {
        let config = detectionConfig
        return services.detector.currentActivities().first { activity in
            activity.micActive && activity.app.bundleID != KanPaths.bundleIdentifier
                && config.policy(for: activity.app, category: activity.category) != .never
        }?.app
    }

    /// Re-checks every `labelWaitPollSeconds` until no unrecorded call holds the microphone (the
    /// detector has no event for apps it doesn't record), then shows the waiting panel.
    private func waitForUnrecordedCall(of app: AppIdentity) {
        guard labelWaitTask == nil else { return }
        KanLog.info("The label panel waits until \(app.name) stops using the microphone", category: "ui")
        let interval = environment.labelWaitPollSeconds
        labelWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
                guard let self else { return }
                // A new recording, "Label now" or an emptied queue end the wait as well.
                if self.isTerminating || self.active != nil || self.presentedLabel != nil || self.pendingLabels.isEmpty
                    || self.appInUnrecordedCall() == nil { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.labelWaitTask = nil
            self.updateLabelPresentation()
        }
    }

    /// The label panel for `id` closed (saved, later or discarded).
    func closeLabel(_ id: CallID) {
        pendingLabels.removeAll { $0 == id }
        if presentedLabel == id { presentedLabel = nil }
        updateLabelPresentation()
    }
}
