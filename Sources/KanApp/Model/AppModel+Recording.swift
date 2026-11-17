import AppKit
import Foundation
import KanCore

/// An app saved calls came from (Settings › Detection lists those outside the catalog).
struct RecordedApp: Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// Why a recording stopped.
enum StopReason: Equatable {
    /// The detector says the call ended (mic released at `endedAt`).
    case detected(endedAt: Date)
    /// Stop & Save (menu, hot key, "Save now", "Stop & save").
    case user
    /// Kan is quitting.
    case termination
    /// Another call started while this one was still recording.
    case superseded
    /// The recorder can't continue (disk full).
    case failure
}

// MARK: - Detection and recording

extension AppModel {
    /// Detection tuning for the current settings and pause state.
    var detectionConfig: DetectionConfig {
        var config = DetectionConfig(settings: settings, pausedUntil: detectionPausedUntil)
        if detectionPausedIndefinitely { config.enabled = false }
        return config
    }

    /// Entry point for `CallDetecting.onEvent` (main actor).
    func handleDetection(_ event: DetectionEvent) {
        guard !isTerminating else { return }
        switch event {
        case .started(let call):
            startDetectedRecording(call, tentative: false)
        case .ask(let call):
            startDetectedRecording(call, tentative: true)
        case .meetingInfo(let call):
            guard let recording = recording(for: call) else { return }
            recording.call = call
            recording.manifest.platform = call.platform
            recording.manifest.meetingTitle = call.meeting?.title?.kanNonEmpty ?? recording.manifest.meetingTitle
            recording.manifest.meetingURL = call.meeting?.url ?? recording.manifest.meetingURL
            recording.manifest.write(in: recording.directory)
            liveCall?.detected = call
            liveCall?.title = liveTitle(for: recording)
            refreshStartNotice(for: recording)
        case .activityChanged(let call, let activity):
            guard let recording = recording(for: call) else { return }
            if case .app = recording.target {
                KanLog.info("\(call.app.name)'s audio processes or devices changed; retargeting the recording", category: "recording")
                recording.handle.retarget(activity)
            }
        case .ending(let call, let deadline):
            guard let recording = recording(for: call) else { return }
            // The detector set the deadline to release + grace.
            recording.micReleasedAt = deadline.addingTimeInterval(-endGraceSeconds(for: call))
            phase = .ending(deadline: deadline)
            postEndingNotice(for: recording, deadline: deadline)
        case .resumed(let call):
            guard let recording = recording(for: call) else { return }
            recording.micReleasedAt = nil
            phase = .recording
            removeNotices { notice in
                if case .ending(let id, _) = notice.kind { return id == recording.callID }
                return false
            }
        case .ended(let call, let endedAt):
            guard recording(for: call) != nil, let recording = detachActive() else { return }
            finish(recording, reason: .detected(endedAt: endedAt))
        case .stale(let call):
            guard let recording = recording(for: call) else { return }
            phase = .stale
            postStaleNotice(for: recording)
        }
    }

    /// How long the detector waits after `call`'s app releases the microphone (its rule, from the
    /// same settings).
    func endGraceSeconds(for call: DetectedCall) -> TimeInterval {
        let config = detectionConfig
        return call.category == .browser ? config.endGraceBrowserSeconds : config.endGraceNativeSeconds
    }

    /// Audio kept after the call app releases the microphone (the last words, the goodbye).
    static let endTrimSeconds: TimeInterval = 2

    /// False for mic-only recordings (no "them" track, no "Them" meter).
    var liveRecordsRemoteTrack: Bool {
        guard let active else { return false }
        if case .micOnly = active.target { return false }
        return true
    }

    /// The live recording for a detected call, if it's the one being recorded.
    func recording(for call: DetectedCall) -> ActiveRecording? {
        guard let active, active.call.id == call.id else { return nil }
        return active
    }

    private func startDetectedRecording(_ call: DetectedCall, tentative: Bool) {
        if let current = active {
            guard current.call.id != call.id else { return }
            // The detector handles one call at a time, so this means a back-to-back call: save the first.
            KanLog.warning("\(call.app.name) started a call while \(current.call.app.name) was recording; saving the first",
                           category: "recording")
            if let previous = detachActive() { finish(previous, reason: .superseded) }
        }
        beginRecording(call: call, tentative: tentative, target: captureTarget(for: call))
    }

    /// The "them" track for a detected call: the call app's processes (recommended), or all
    /// system audio when the setting says so or the app's processes aren't known.
    func captureTarget(for call: DetectedCall) -> CaptureTarget {
        switch settings.captureScope {
        case .allSystemAudio:
            return .systemAudio
        case .callApp:
            if let activity = services.detector.currentActivities().first(where: { $0.app.bundleID == call.app.bundleID }),
               !activity.processObjectIDs.isEmpty {
                return .app(activity)
            }
            KanLog.info("No audio processes known for \(call.app.name); recording all system audio", category: "recording")
            return .systemAudio
        }
    }

    func beginRecording(call: DetectedCall, tentative: Bool, target: CaptureTarget) {
        let id = CallID.generate(date: call.startedAt)
        let directory = environment.callDataDirectory(for: id)
        var preferredInput: String?
        if case .app(let activity) = target { preferredInput = activity.inputDeviceUIDs.first }
        let request = RecordingRequest(callID: id, target: target, directory: directory, captureMic: true,
                                       preferredInputDeviceUID: preferredInput, callStartedAt: call.startedAt)
        let handle: RecordingHandle
        do {
            handle = try services.recorder.start(request)
        } catch {
            report("Couldn't start recording \(call.app.name)", error: error, category: "recording")
            postProblem("Kan couldn't start recording", message: Self.describe(error))
            if call.isManual { services.detector.endManualSession(call.id) }
            return
        }

        let manifest = RecordingManifest(
            callID: id, appName: call.app.name, bundleID: call.app.bundleID, category: call.category,
            platform: call.platform, meetingTitle: call.meeting?.title?.kanNonEmpty, meetingURL: call.meeting?.url,
            detectedAt: call.startedAt, recordingStartedAt: handle.startedAt, isManual: call.isManual,
            isTentative: tentative, calendarEventTitle: nil, attendees: [], bookmarks: [],
            timeZone: TimeZone.current.identifier)
        manifest.write(in: directory)
        let recording = ActiveRecording(callID: id, call: call, handle: handle, directory: directory, target: target,
                                        manifest: manifest)
        active = recording
        now = environment.now()
        liveCall = LiveCall(id: id, detected: call, startedAt: handle.startedAt, isTentative: tentative,
                            isPaused: false, title: liveTitle(for: recording), bookmarks: [])
        phase = .recording
        recordingIssues = []
        KanLog.info("Recording \(id): \(call.app.name) [\(call.app.bundleID)]\(call.isManual ? " (manual)" : "")"
                    + "\(tentative ? " (tentative)" : "") → \(Self.describe(target))", category: "recording")

        pauseQueueForCall()
        handle.onIssue = { [weak self] issue in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.recordingIssueRaised(issue, callID: id) }
            }
        }
        for issue in handle.issues { recordingIssueRaised(issue, callID: id) }
        startPolling(recording)
        if tentative {
            postAskNotice(for: recording)
        } else if !call.isManual {
            postStartNotice(for: recording)
        }
        lookUpCalendarEvent(for: recording)
    }

    static func describe(_ target: CaptureTarget) -> String {
        switch target {
        case .app(let activity): return "\(activity.app.name) (\(activity.processObjectIDs.count) processes) + mic"
        case .systemAudio: return "all system audio + mic"
        case .micOnly: return "mic only"
        }
    }

    /// Title shown while recording: calendar event > meeting title > "<App> call".
    func liveTitle(for recording: ActiveRecording) -> String {
        let draft = CallRecord(id: recording.callID, title: "", startedAt: recording.manifest.recordingStartedAt,
                               endedAt: recording.manifest.recordingStartedAt, source: recording.manifest.source,
                               calendarEventTitle: recording.manifest.calendarEventTitle)
        return TranscriptRenderer.suggestedTitle(for: draft)
    }

    /// Mirrors levels (~10 Hz), refreshes the clock (1 Hz) and reports silence to the detector.
    private func startPolling(_ recording: ActiveRecording) {
        recording.pollTask?.cancel()
        recording.pollTask = Task { [weak self, weak recording] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recording, self.active === recording else { return }
                let levels = recording.handle.levels
                if self.levels != levels { self.levels = levels }
                if tick % 10 == 0 { self.now = self.environment.now() }
                if tick % 30 == 29 { self.reportSilence(of: recording) }
                tick += 1
            }
        }
    }

    private func reportSilence(of recording: ActiveRecording) {
        services.detector.reportSilence(seconds: recording.handle.silenceSeconds, for: recording.call.id)
    }

    /// Reports the live recording's silence to the detector right away (Debug › stale silence).
    func reportSilenceNow() {
        guard let active else { return }
        reportSilence(of: active)
    }

    // MARK: Recording issues

    func recordingIssueRaised(_ issue: RecordingIssue, callID: CallID) {
        guard let recording = active, recording.callID == callID,
              recording.reportedIssues.insert(issue).inserted else { return }
        recordingIssues.append(issue)
        let app = recording.call.app.name
        KanLog.warning("Recording \(callID) reported \(issue.rawValue)", category: "recording")
        switch issue {
        case .systemAudioSilent:
            refreshPermissions()        // the menu's problem says the same
            if services.permissions.needsRelaunch(.systemAudio) {
                // Allowed in System Settings while Kan ran: there's nothing left to grant.
                postProblem("Relaunch Kan to hear the other side",
                            message: "System Audio Recording is allowed, but macOS applies it only after Kan relaunches. Your microphone is still being recorded, and relaunching saves what Kan has so far.",
                            buttons: [.init(title: "Relaunch Kan", command: .relaunch, role: .primary)])
            } else {
                postProblem("Kan can't hear the other side — grant System Audio Recording",
                            message: "Allow Kan under System Settings › Privacy & Security › System Audio Recording, then relaunch Kan. Your microphone is still being recorded.",
                            buttons: [.init(title: "Open Settings", command: .openSystemSettings(.systemAudio), role: .primary),
                                      .init(title: "Relaunch Kan", command: .relaunch)])
            }
        case .micPermissionDenied:
            postProblem("Kan can't record your microphone",
                        message: "Allow Kan under System Settings › Privacy & Security › Microphone. Only the other side is being recorded.",
                        buttons: [.init(title: "Open Settings", command: .openSystemSettings(.microphone), role: .primary)])
        case .micUnavailable:
            postProblem("No microphone available", message: "Only the other side of the call is being recorded.")
        case .tapFailed:
            // The call app's tap, or the all-system-audio one (a manual recording, Settings › Recording).
            let source: String
            if case .app = recording.target { source = "\(app)'s audio" } else { source = "system audio" }
            postProblem("Kan can't capture \(source) right now",
                        message: "Only your microphone is being recorded for now. Kan keeps trying to capture the other side.")
        case .systemAudioFallback:
            postProblem("Recording all system audio for this call",
                        message: "Kan couldn't capture only \(app), so other apps' sounds (music, notifications) may be included. Kan keeps trying to switch back.")
        case .diskFull:
            postProblem("Your disk is full", message: "Kan stopped the recording and saved what it had.")
            if let detached = detachActive() {
                tellDetectorRecordingStopped(detached)
                finish(detached, reason: .failure)
            }
        case .writeError:
            postProblem("Kan couldn't write the recording to disk", message: "See the log for details.")
        case .tapRebuilt, .deviceChanged:
            break   // handled by the recorder; logged above
        }
    }

    // MARK: Notices for the live call

    private func postStartNotice(for recording: ActiveRecording) {
        var buttons: [AppNotice.Button] = [.init(title: "Don't record", command: .discardRecording, role: .destructive),
                                           .init(title: "Pause", command: .pauseRecording)]
        if Self.offersNeverOnStart(recording.call) {
            buttons.append(.init(title: "Never record \(recording.call.app.name)", command: .never, role: .destructive))
        }
        post(AppNotice(kind: .recordingStarted(recording.callID), style: .recording,
                       title: "Recording \(recording.call.app.name) call",
                       message: startNoticeDetail(for: recording),
                       buttons: buttons,
                       autoHideAfter: environment.startToastSeconds, createdAt: environment.now()))
    }

    /// The start toast offers "Never record <App>" only for apps outside the catalog — a browser
    /// Kan guessed from its Info.plist, an unknown app the user set to Auto — whose mic use may not
    /// be a call at all. Cataloged apps (Zoom, Zen, Chrome…) are recorded on purpose, so a stray
    /// click must not turn their detection off; Settings › Detection still can.
    static func offersNeverOnStart(_ call: DetectedCall) -> Bool {
        !call.isManual && !call.app.bundleID.isEmpty && call.app.bundleID != KanPaths.bundleIdentifier
            && AppCatalog.lookup(bundleID: call.app.bundleID) == nil
    }

    private func startNoticeDetail(for recording: ActiveRecording) -> String? {
        var parts: [String] = []
        if let title = recording.manifest.calendarEventTitle ?? recording.manifest.meetingTitle { parts.append(title) }
        let attendees = recording.manifest.attendees.prefix(4)
        if !attendees.isEmpty { parts.append(attendees.joined(separator: ", ")) }
        return parts.isEmpty ? "Transcribed on this Mac when the call ends." : parts.joined(separator: " · ")
    }

    /// Updates the start toast in place when better meeting / calendar information arrives.
    private func refreshStartNotice(for recording: ActiveRecording) {
        guard let index = notices.firstIndex(where: { $0.kind == .recordingStarted(recording.callID) }) else { return }
        notices[index].message = startNoticeDetail(for: recording)
    }

    private func postAskNotice(for recording: ActiveRecording) {
        let app = recording.call.app.name
        post(AppNotice(kind: .ask(recording.callID), style: .question, title: "Record this call?",
                       message: "\(app) is using the microphone. Kan is recording tentatively until you decide.",
                       buttons: [.init(title: "Record", command: .record, role: .primary),
                                 .init(title: "Not now", command: .notNow),
                                 .init(title: "Never for \(app)", command: .never, role: .destructive)],
                       isDismissible: false, createdAt: environment.now()))
    }

    private func postEndingNotice(for recording: ActiveRecording, deadline: Date) {
        post(AppNotice(kind: .ending(recording.callID, deadline: deadline), style: .question,
                       title: "\(recording.call.app.name) call ended",
                       message: "Kan saves the recording when the countdown ends.",
                       buttons: [.init(title: "Keep recording", command: .keepRecording),
                                 .init(title: "Save now", command: .stopAndSave, role: .primary)],
                       isDismissible: false, createdAt: environment.now()))
    }

    private func postStaleNotice(for recording: ActiveRecording) {
        let minutes = Int(settings.staleSilenceMinutes.rounded())
        post(AppNotice(kind: .stale(recording.callID), style: .question, title: "Still in a call?",
                       message: "No sound on either side for \(minutes) minutes (\(recording.call.app.name)).",
                       buttons: [.init(title: "Still in a call", command: .keepRecording),
                                 .init(title: "Stop & save", command: .stopAndSave, role: .primary)],
                       isDismissible: false, createdAt: environment.now()))
    }

    // MARK: Recording control (menu bar)

    func startManualRecording(_ target: ManualTarget) {
        guard active == nil, !isTerminating else { return }
        let started = environment.now()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let call: DetectedCall
        let capture: CaptureTarget
        switch target {
        case .app(let activity):
            let platform = AppCatalog.platform(bundleID: activity.app.bundleID)
            call = DetectedCall(app: activity.app, category: activity.category, startedAt: started,
                                platform: activity.category == .browser ? .browser : (platform == .other ? .manual : platform),
                                isManual: true)
            capture = .app(activity)
        case .systemAudio:
            call = DetectedCall(app: AppIdentity(bundleID: KanPaths.bundleIdentifier, name: "System audio", pid: ownPID),
                                category: .unknown, startedAt: started, platform: .manual, isManual: true)
            capture = .systemAudio
        case .micOnly:
            call = DetectedCall(app: AppIdentity(bundleID: KanPaths.bundleIdentifier, name: "Microphone", pid: ownPID),
                                category: .unknown, startedAt: started, platform: .manual, isManual: true)
            capture = .micOnly
        }
        services.detector.beginManualSession(call)
        beginRecording(call: call, tentative: false, target: capture)
    }

    /// ⌃⌥⌘R: start an "all system audio + mic" recording, or stop the current one.
    func toggleManualRecording() {
        if active != nil {
            stopRecording()
        } else {
            startManualRecording(.systemAudio)
        }
    }

    /// Stop & save now.
    func stopRecording() {
        guard let recording = detachActive() else { return }
        tellDetectorRecordingStopped(recording)
        finish(recording, reason: .user)
    }

    func discardCurrentRecording() {
        guard let recording = detachActive() else { return }
        if recording.call.isManual {
            services.detector.endManualSession(recording.call.id)
        } else {
            services.detector.respond(.notNow, to: recording.call.id)
        }
        KanLog.info("Discarding recording \(recording.callID) (user)", category: "recording")
        discard(recording)
    }

    /// Deletes a detached recording and everything it wrote, in the background.
    private func discard(_ recording: ActiveRecording) {
        let task = Task { [weak self] in
            await recording.handle.discard()
            guard let self else { return }
            self.removeCallDirectory(recording.directory)
            self.finalizations[recording.callID] = nil
            self.resumeQueueAfterCall()
            self.updateLabelPresentation()
        }
        finalizations[recording.callID] = task
    }

    func pauseRecording() {
        guard let recording = active, liveCall?.isPaused == false else { return }
        recording.handle.pause()
        liveCall?.isPaused = true
    }

    func resumeRecording() {
        guard let recording = active, liveCall?.isPaused == true else { return }
        recording.handle.resume()
        liveCall?.isPaused = false
    }

    /// Answer to "Call ended?" / "Still in a call?": keep going.
    func keepRecording() {
        guard let recording = active else { return }
        services.detector.respond(.keepRecording, to: recording.call.id)
        // The call goes on: what follows the mic release is part of it.
        recording.micReleasedAt = nil
        phase = .recording
        removeNotices { notice in
            switch notice.kind {
            case .ending(let id, _), .stale(let id): return id == recording.callID
            default: return false
            }
        }
    }

    /// Answer to "Record this call?" for a tentative recording.
    func respondToAsk(_ response: UserCallResponse) {
        guard let recording = active else { return }
        switch response {
        case .record:
            guard recording.isTentative else { return }
            services.detector.respond(.record, to: recording.call.id)
            recording.manifest.isTentative = false
            recording.manifest.write(in: recording.directory)
            liveCall?.isTentative = false
            removeNotices { $0.kind == .ask(recording.callID) }
            KanLog.info("Recording \(recording.callID) confirmed by the user", category: "recording")
        case .notNow, .never:
            guard recording.isTentative, let detached = detachActive() else { return }
            services.detector.respond(response, to: detached.call.id)
            if response == .never { setNeverRecord(bundleID: detached.call.app.bundleID, name: detached.call.app.name) }
            KanLog.info("Tentative recording \(detached.callID) discarded (\(response == .never ? "never" : "not now"))",
                        category: "recording")
            discard(detached)
        case .keepRecording:
            keepRecording()
        case .endNow:
            stopRecording()
        }
    }

    /// `.never`: "Never for <App>" on the "Record this call?" prompt, or "Never record <App>" on the
    /// start toast of an app outside the catalog (`offersNeverOnStart`) that turned out not to be in
    /// a call. Either way the recording is discarded and the app's policy becomes Never.
    func neverRecordLiveApp() {
        guard let recording = active else { return }
        if recording.isTentative {
            respondToAsk(.never)
            return
        }
        guard !recording.call.isManual, let detached = detachActive() else { return }
        services.detector.respond(.never, to: detached.call.id)
        setNeverRecord(bundleID: detached.call.app.bundleID, name: detached.call.app.name)
        KanLog.info("Recording \(detached.callID) discarded (never record \(detached.call.app.name))", category: "recording")
        discard(detached)
    }

    /// "Never for <App>": remember the policy for this app.
    func setNeverRecord(bundleID: String, name: String) {
        guard !bundleID.isEmpty, bundleID != KanPaths.bundleIdentifier else { return }
        settings.appPolicies[bundleID] = .never
        saveSettings()
        KanLog.info("Kan will never record \(name) [\(bundleID)]", category: "recording")
    }

    /// Apps outside the catalog that saved calls came from — a browser Kan guessed, an unknown app
    /// the user answered "Record" for or set to Auto — by name, so Settings › Detection can change
    /// their policy (only apps with an explicit policy are listed otherwise). From the library's
    /// index (`LibraryStore.recordedApps()`: no call is read), off the main thread because the
    /// store's lock may be held by a rescan.
    func recordedAppsOutsideCatalog() async -> [RecordedApp] {
        let library = self.library
        return await Task.detached(priority: .utility) { () -> [RecordedApp] in
            library.recordedApps()
                .filter { bundleID, _ in bundleID != KanPaths.bundleIdentifier && AppCatalog.lookup(bundleID: bundleID) == nil }
                .map { RecordedApp(bundleID: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    /// The policy detection applies to the app with this bundle id now: its own, else its
    /// category's default (an app outside the catalog that opens web pages counts as a browser).
    func effectivePolicy(bundleID: String) -> AppPolicy {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return detectionConfig.policy(for: AppIdentity(bundleID: bundleID, name: bundleID, pid: 0),
                                      category: AppCatalog.category(bundleID: bundleID, appURL: appURL))
    }

    func addBookmark(note: String = "") {
        guard let recording = active, var live = liveCall else { return }
        let elapsed = max(0, environment.now().timeIntervalSince(live.startedAt))
        // Retroactive: a bookmark usually means "what was just said", so it covers the last 30 s.
        let bookmark = Bookmark(time: max(0, elapsed - 30), endTime: elapsed, note: note.kanSingleLine,
                                createdAt: environment.now())
        live.bookmarks.append(bookmark)
        liveCall = live
        recording.manifest.bookmarks = live.bookmarks
        recording.manifest.write(in: recording.directory)
        postInfo("Bookmarked \(KanTime.hms(elapsed))", message: note.kanNonEmpty, seconds: 2.5)
    }

    /// nil = until resumed.
    func pauseDetection(for duration: TimeInterval?) {
        detectionPauseTask?.cancel()
        detectionPauseTask = nil
        if let duration {
            let until = environment.now().addingTimeInterval(max(60, duration))
            detectionPausedUntil = until
            detectionPausedIndefinitely = false
            let seconds = until.timeIntervalSince(environment.now())
            detectionPauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.detectionPausedUntil == until else { return }
                self.detectionPausedUntil = nil
                self.applyDetectionConfig()
                KanLog.info("Call detection resumed (pause ended)", category: "detect")
            }
            KanLog.info("Call detection paused until \(KanDate.iso8601(until))", category: "detect")
        } else {
            detectionPausedUntil = nil
            detectionPausedIndefinitely = true
            KanLog.info("Call detection paused until resumed", category: "detect")
        }
        applyDetectionConfig()
    }

    func resumeDetection() {
        detectionPauseTask?.cancel()
        detectionPauseTask = nil
        detectionPausedUntil = nil
        detectionPausedIndefinitely = false
        if !settings.autoDetect {
            settings.autoDetect = true
            saveSettings()
        }
        applyDetectionConfig()
        KanLog.info("Call detection resumed", category: "detect")
    }

    /// The start of tomorrow (for "Pause until tomorrow").
    func secondsUntilTomorrow() -> TimeInterval {
        let calendar = Calendar.current
        let current = environment.now()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)) else {
            return 12 * 3600
        }
        return tomorrow.timeIntervalSince(current)
    }

    /// Apps currently using audio, for "Start recording ▸".
    func activeAudioApps() -> [AppActivity] {
        services.detector.currentActivities()
            .filter { $0.app.bundleID != KanPaths.bundleIdentifier && $0.category != .ignored && ($0.micActive || $0.outputActive) }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    // MARK: Stopping and saving

    /// Takes the live recording out of the UI state synchronously (the caller then finalizes or
    /// discards it), so late detector events can't stop it twice.
    func detachActive() -> ActiveRecording? {
        guard let recording = active else { return nil }
        active = nil
        recording.pollTask?.cancel()
        recording.pollTask = nil
        recording.handle.onIssue = nil
        liveCall = nil
        phase = .idle
        levels = .zero
        recordingIssues = []
        removeNotices { $0.isAboutLiveCall && $0.callID == recording.callID }
        return recording
    }

    /// Tells the detector a recording it knows about was stopped by the user.
    func tellDetectorRecordingStopped(_ recording: ActiveRecording) {
        if recording.call.isManual {
            services.detector.endManualSession(recording.call.id)
        } else {
            services.detector.respond(.endNow, to: recording.call.id)
        }
    }

    /// Stops the recorder and saves (or discards) the call in the background.
    func finish(_ recording: ActiveRecording, reason: StopReason) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finalize(recording, reason: reason)
        }
        finalizations[recording.callID] = task
    }

    private func finalize(_ recording: ActiveRecording, reason: StopReason) async {
        defer {
            finalizations[recording.callID] = nil
            resumeQueueAfterCall()
            updateLabelPresentation()
        }
        let trim: Date?
        switch reason {
        case .detected(let endedAt):
            trim = endedAt.addingTimeInterval(Self.endTrimSeconds)
        case .user, .termination, .superseded, .failure:
            // Stopped during the end-of-call countdown ("Save now", quitting): the call app had
            // already let go of the mic, so cut where the countdown would have. What came after
            // (another tab's video, the room) isn't the call.
            trim = recording.micReleasedAt?.addingTimeInterval(Self.endTrimSeconds)
        }
        let result = await recording.handle.stop(trimEndAt: trim)
        var manifest = recording.manifest
        manifest.recordingStartedAt = result.startedAt
        let duration = result.duration
        KanLog.info("Recording \(recording.callID) stopped (\(Self.describe(reason))): \(String(format: "%.1f", duration)) s"
                    + "\(trim == nil ? "" : ", trimmed after the mic release"), "
                    + "me \(result.meFile != nil), them \(result.themFile != nil)", category: "recording")

        guard result.meFile != nil || result.themFile != nil else {
            removeCallDirectory(recording.directory)
            KanLog.warning("Recording \(recording.callID) captured no audio; nothing saved", category: "recording")
            // Permissions or devices are broken; stay quiet only about short automatic captures.
            if manifest.isManual || duration >= settings.minCallSeconds {
                postProblem("Nothing was recorded", message: "Check Kan's Microphone and System Audio Recording permissions.",
                            buttons: [.init(title: "Settings…", command: .openSettings)])
            }
            return
        }
        let ruledShort = !manifest.isManual && duration < settings.minCallSeconds
        switch reason {
        case .detected, .termination, .superseded:
            if ruledShort {
                KanLog.info("Discarding \(recording.callID): \(String(format: "%.1f", duration)) s is shorter than "
                            + "\(Int(settings.minCallSeconds)) s", category: "recording")
                removeCallDirectory(recording.directory)
                return
            }
        case .user, .failure:
            break
        }
        if manifest.isTentative && reason != .termination && reason != .user {
            askToKeepUnconfirmed(manifest: manifest, result: result)
            return
        }
        await saveRecording(manifest: manifest, result: result, showLabel: settings.showLabelPrompt)
    }

    static func describe(_ reason: StopReason) -> String {
        switch reason {
        case .detected: return "call ended"
        case .user: return "stopped by the user"
        case .termination: return "Kan is quitting"
        case .superseded: return "another call started"
        case .failure: return "recording failure"
        }
    }

    /// Creates the call in the Inbox (status queued), queues transcription and the label panel.
    @discardableResult
    func saveRecording(manifest: RecordingManifest, result: RecordingResult, showLabel: Bool,
                       recovered: Bool = false) async -> CallID? {
        let id = manifest.callID
        var record = CallRecord(
            id: id, title: "", folder: "", startedAt: result.startedAt, endedAt: max(result.endedAt, result.startedAt),
            timeZone: manifest.timeZone, source: manifest.source, status: .queued, languageMode: settings.languageMode,
            calendarEventTitle: manifest.calendarEventTitle, attendees: manifest.attendees,
            bookmarks: manifest.bookmarks, audio: Self.rawAudioAssets(result), createdAt: environment.now())
        record.title = TranscriptRenderer.suggestedTitle(for: record)
        let library = self.library
        let toSave = record
        do {
            try await Task.detached(priority: .userInitiated) { _ = try library.save(toSave) }.value
        } catch {
            // The audio and live.json stay in the call data directory: the next launch retries.
            report("Couldn't save the recording “\(record.title)”", error: error, category: "library",
                   log: "Couldn't save recording \(id)")
            postProblem("Kan couldn't save the recording", message: Self.describe(error))
            return nil
        }
        RecordingManifest.remove(in: result.directory)
        queue?.enqueue(TranscriptionRequest(recording: result, settings: settings))
        KanLog.info("Saved \(recovered ? "recovered " : "")call \(id) (\(KanTime.hms(record.duration)))", category: "recording")
        if showLabel {
            pendingLabels.removeAll { $0 == id }
            pendingLabels.append(id)
        } else if !recovered {
            postInfo("Saved “\(record.title)”", message: "Transcribing on this Mac…",
                     buttons: [.init(title: "Label", command: .label(id)), .init(title: "Show", command: .showInLibrary(id))])
        }
        refreshSummaries()
        return id
    }

    /// The WAVs a finished recording left, as the call's (temporary) audio assets.
    static func rawAudioAssets(_ result: RecordingResult) -> AudioAssets? {
        guard result.meFile != nil || result.themFile != nil else { return nil }
        var size: Int64 = 0
        for url in [result.meFile, result.themFile].compactMap({ $0 }) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            size += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return AudioAssets(meFile: result.meFile?.lastPathComponent, themFile: result.themFile?.lastPathComponent,
                           format: "wav", sizeBytes: size)
    }

    /// Deletes a recording's working directory (discarded / too-short calls).
    func removeCallDirectory(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            KanLog.error("Couldn't delete \(directory.path): \(error.localizedDescription)", category: "recording")
        }
    }

    // MARK: Tentative recordings that ended unanswered

    private func askToKeepUnconfirmed(manifest: RecordingManifest, result: RecordingResult) {
        let id = manifest.callID
        let app = manifest.appName
        let noticeID = post(AppNotice(
            kind: .keepUnconfirmed(id), style: .question, title: "Keep the recording of \(app)?",
            message: "The call ended before you answered (\(KanTime.humanDuration(result.duration))).",
            buttons: [.init(title: "Keep", command: .keepUnconfirmed(id), role: .primary),
                      .init(title: "Discard", command: .discardUnconfirmed(id)),
                      .init(title: "Never for \(app)", command: .neverUnconfirmed(id), role: .destructive)],
            isDismissible: false, createdAt: environment.now()))
        unconfirmed[id] = UnconfirmedRecording(manifest: manifest, result: result, noticeID: noticeID)
        KanLog.info("Tentative recording \(id) ended unanswered; asking whether to keep it", category: "recording")
    }

    func keepUnconfirmed(_ id: CallID) {
        guard var pending = unconfirmed.removeValue(forKey: id) else { return }
        if let noticeID = pending.noticeID { dismissNotice(noticeID) }
        pending.manifest.isTentative = false
        let manifest = pending.manifest
        let result = pending.result
        let showLabel = settings.showLabelPrompt && !isTerminating
        let task = Task { [weak self] in
            guard let self else { return }
            await self.saveRecording(manifest: manifest, result: result, showLabel: showLabel)
            self.finalizations[id] = nil
            self.updateLabelPresentation()
        }
        finalizations[id] = task
    }

    func discardUnconfirmed(_ id: CallID, never: Bool) {
        guard let pending = unconfirmed.removeValue(forKey: id) else { return }
        if let noticeID = pending.noticeID { dismissNotice(noticeID) }
        if never { setNeverRecord(bundleID: pending.manifest.bundleID, name: pending.manifest.appName) }
        removeCallDirectory(pending.result.directory)
        KanLog.info("Unconfirmed recording \(id) discarded", category: "recording")
    }

    // MARK: Transcription while recording

    /// Transcription is GPU-heavy: hold the queue while a call is being recorded (if enabled).
    private func pauseQueueForCall() {
        guard settings.pauseTranscriptionDuringCalls, let queue, !queuePausedForCall else { return }
        queuePausedForCall = true
        queue.pause()
    }

    /// Not while quitting: the queue stays paused, and its jobs run at the next launch.
    func resumeQueueAfterCall() {
        guard queuePausedForCall, active == nil, !isTerminating else { return }
        queuePausedForCall = false
        queue?.resume()
    }

    // MARK: Calendar

    private func lookUpCalendarEvent(for recording: ActiveRecording) {
        guard settings.useCalendar else { return }
        let calendar = environment.calendar
        guard calendar.authorizationStatus() == .granted else { return }
        let start = recording.call.startedAt
        let id = recording.callID
        Task { [weak self] in
            let match = await Task.detached(priority: .utility) { calendar.event(around: start) }.value
            guard let self, let match, let current = self.active, current.callID == id else { return }
            current.manifest.calendarEventTitle = match.title.kanNonEmpty
            current.manifest.attendees = match.attendees
            current.manifest.write(in: current.directory)
            self.liveCall?.title = self.liveTitle(for: current)
            self.refreshStartNotice(for: current)
            KanLog.info("Matched a calendar event (\(match.attendees.count) attendees) to \(id)", category: "calendar")
        }
    }
}
