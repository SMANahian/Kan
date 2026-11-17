import Foundation
import KanCore

/// `KanApp --self-test`: runs the app's flows headlessly against the real KanCore library and
/// processing queue, with mock services on a virtual clock. No windows, status items, hot keys,
/// login items, pasteboard or permission prompts. Prints ✓/✗ lines and exits 0 (all passed) or 1.
///
/// Everything happens in a fresh temporary KAN_HOME (set before anything touches KanPaths), so
/// the real ~/Documents/Kan and ~/Library/Application Support/Kan are never used.
/// KAN_KEEP_TEST_FILES=1 keeps the directory for inspection.
enum SelfTest {
    static func launch() -> Never {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("kan-selftest-app-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: home)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("KAN_HOME", home.path, 1)
        setenv("KAN_MOCK", "1", 1)
        setenv("KAN_MODELS", home.appendingPathComponent("Models", isDirectory: true).path, 1)
        KanLog.configure(fileName: "kan-selftest-app.log")

        Task { @MainActor in
            let code = await SelfTestRunner(home: home).run()
            if ProcessInfo.processInfo.environment["KAN_KEEP_TEST_FILES"] == nil {
                try? FileManager.default.removeItem(at: home)
            } else {
                print("Test files kept in \(home.path)")
            }
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }
}

/// Status of each call every time the library saved it (recorded on the saving thread).
final class StatusHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [CallID: [CallStatus]] = [:]

    func append(_ id: CallID, _ status: CallStatus) {
        lock.withLock {
            if statuses[id]?.last != status { statuses[id, default: []].append(status) }
        }
    }

    func of(_ id: CallID) -> [CallStatus] { lock.withLock { statuses[id] ?? [] } }
}

@MainActor
final class SelfTestRunner {
    let home: URL
    let clock = MockClock.virtual(start: KanDate.parse("2026-11-17T14:30:00-05:00") ?? Date())
    let history = StatusHistory()
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []

    init(home: URL) {
        self.home = home
    }

    // MARK: Harness

    func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            let extra = detail()
            let line = "  ✗ \(name)" + (extra.isEmpty ? "" : " — \(extra)")
            print(line)
            failures.append(line)
        }
        fflush(stdout)
    }

    /// Polls `condition` (letting main-queue work run) until it holds or `timeout` passes.
    func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Lets queued main-queue work (detector events, library notifications) run.
    func settle() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func section(_ title: String) {
        print("\n▸ \(title)")
    }

    func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Setup

    func makeModel() -> (AppModel, HeadlessEffects) {
        let effects = HeadlessEffects()
        let clock = self.clock
        let services = MockServices.make(clock: clock, transcriptionStepSeconds: 0.005, modelDownloadSeconds: 0.02)
        let model = AppModel(services: services, settingsStore: SettingsStore(), voiceprints: VoiceprintStore(),
                             environment: .headless(now: { clock.now() }, effects: effects))
        return (model, effects)
    }

    /// Records every saved status (synchronously, before the app's own handler runs).
    func tapStatuses(_ model: AppModel) {
        let library = model.library
        let previous = library.onChange
        let history = self.history
        library.onChange = { change in
            if case .saved(let id) = change, let status = library.summary(id)?.status { history.append(id, status) }
            previous?(change)
        }
    }

    func writeSettings() {
        var settings = KanSettings()
        settings.userName = "Nahian"
        settings.onboardingCompleted = true
        settings.rememberVoices = true
        settings.askedAboutVoices = true
        settings.minCallSeconds = 20
        settings.startConfirmSeconds = 3
        settings.endGraceNativeSeconds = 15
        settings.endGraceBrowserSeconds = 30
        settings.keepAudio = true
        settings.showLabelPrompt = true
        do {
            try SettingsStore().save(settings)
        } catch {
            check(false, "write test settings", "\(error)")
        }
    }

    // MARK: Run

    func run() async -> Int32 {
        print("Kan app self-test — KAN_HOME=\(home.path)")
        print("Mock audio: \(MockAudioLibrary.shared.directory?.path ?? "not found (silent recordings)")")
        writeSettings()
        let (model, effects) = makeModel()
        await model.startAndWait()
        tapStatuses(model)
        check(model.isStarted && model.services.isMock, "app model started with mock services")
        check(model.library.root.path.hasPrefix(home.path), "library lives in the test KAN_HOME", model.library.root.path)
        guard let detector = model.mockDetector else {
            check(false, "mock detector available")
            return finish()
        }
        check(detector.isRunning, "detection started")

        let first = await zoomCallFlow(model, detector)
        if let first {
            await labelAndSearchFlow(model, first)
            await speakerFlow(model, detector, first)
            await languageFlow(model, first)
            await exportFlow(model, effects, first)
            await deleteFlow(model, first)
        }
        await appNapFlow(model, effects, detector)
        await voiceNoteFlow(model, detector)
        await unknownAppFlow(model, detector)
        await shortCallFlow(model, detector)
        await endingAndStaleFlow(model, detector)
        await saveNowFlow(model, detector)
        await manualFlow(model)
        await labelQueueFlow(model, detector)
        await labelWaitFlow(model, detector)
        await labelPanelSaveFlow(model, detector)
        await processingCleanupFlow(model, detector)
        await modelsWaitingFlow(model, detector)
        await voiceSamplesFlow(model, detector)
        await neverRecordFlow(model, detector)
        await detectionPauseFlow(model, detector)
        await hotkeyAndIssueFlow(model, effects)
        await issueNoticeFlow(model, detector)
        await relaunchPermissionFlow(model, effects)
        await noticeFlow(model)
        await retentionFlow(model)
        defensiveIDFlow(model)
        libraryLocationFlow(model)
        await cloudLibraryFlow(model, effects)
        await logPrivacyFlow(model, detector)
        warmUpBookkeepingFlow()
        await recoveryAndQuitFlow(previous: model)
        await libraryAccessFlow()
        return finish()
    }

    func finish() -> Int32 {
        print("\n\(passed) passed, \(failed) failed")
        if !failures.isEmpty {
            print("Failures:")
            failures.forEach { print($0) }
        }
        fflush(stdout)
        return failed == 0 ? 0 : 1
    }

    // MARK: Helpers

    /// A detected Zoom call recorded for `seconds` (from recording start to mic release), ended by detection.
    func recordZoomCall(_ model: AppModel, _ detector: MockCallDetector, seconds: Double) async -> CallID? {
        await recordCall(MockApps.zoom, model, detector, seconds: seconds)
    }

    /// A detected call of `activity`'s app (recorded automatically: its policy must be auto) for
    /// `seconds`, ended by detection.
    func recordCall(_ activity: AppActivity, _ model: AppModel, _ detector: MockCallDetector, seconds: Double) async -> CallID? {
        detector.simulateMicAcquired(activity)
        clock.advance(by: model.settings.startConfirmSeconds)
        guard await eventually({ model.phase == .recording && model.liveCall?.appName == activity.app.name }),
              let id = model.liveCall?.id else { return nil }
        clock.advance(by: seconds)
        detector.simulateMicReleased(bundleID: activity.app.bundleID)
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        clock.advance(by: activity.category == .browser ? model.settings.endGraceBrowserSeconds : model.settings.endGraceNativeSeconds)
        _ = await eventually { model.phase == .idle }
        await model.waitForFinalizations()
        return id
    }

    /// The log lines written while `body` runs. The file is appended asynchronously (in order), so
    /// this starts after a line of its own has arrived — lines logged earlier can't slip in — and
    /// waits until `marker` shows up.
    func logText(until marker: String, _ body: () -> Void) async -> String {
        let file = KanPaths.logs.appendingPathComponent("kan-selftest-app.log")
        let start = Data("self-test log check \(UUID().uuidString)".utf8)
        KanLog.info(String(decoding: start, as: UTF8.self), category: "selftest")
        var offset: Int?
        _ = await eventually(timeout: 5) {
            offset = FileManager.default.contents(atPath: file.path)?.range(of: start)?.upperBound
            return offset != nil
        }
        guard let offset else { return "" }
        body()
        var text = ""
        _ = await eventually(timeout: 5) {
            guard let data = FileManager.default.contents(atPath: file.path), data.count > offset else { return false }
            text = String(decoding: data[offset...], as: UTF8.self)
            return text.contains(marker)
        }
        return text
    }

    /// Every call's voice samples (embeddings.json) in the Calls directory.
    func voiceSampleFiles(_ model: AppModel) -> [URL] {
        let calls = model.environment.callsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: calls.path)) ?? []
        return names.map { SpeakerEmbeddingsFile.url(in: calls.appendingPathComponent($0, isDirectory: true)) }
            .filter { exists($0) }
    }

    func waitUntilReady(_ model: AppModel, _ id: CallID) async -> Bool {
        await eventually(timeout: 15) { model.record(id)?.status == .ready && model.processing[id] == nil }
    }

    // MARK: Flows

    /// (1) A scripted 25 s Zoom call: recording → saved in the Inbox (queued) → processing → ready.
    func zoomCallFlow(_ model: AppModel, _ detector: MockCallDetector) async -> CallID? {
        section("1. Scripted Zoom call (25 s)")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        check(await eventually { model.phase == .recording && model.liveCall?.appName == "Zoom" },
              "Zoom holding the mic for 3 s starts a recording", "phase \(model.phase)")
        guard let id = model.liveCall?.id else { return nil }
        let directory = model.environment.callDataDirectory(for: id)
        check(model.liveCall?.isTentative == false, "Zoom is recorded automatically (not tentative)")
        check(exists(RecordingManifest.url(in: directory)), "live.json marks the recording in progress")
        check(model.queue?.isPaused == true, "transcription is paused during the call")
        check(model.notices.contains { $0.kind == .recordingStarted(id) }, "start toast shown")
        check(model.presentedLabel == nil, "no label panel during a live call")

        clock.advance(by: 10)
        model.addBookmark(note: "augmentation idea")
        let bookmark = model.liveCall?.bookmarks.first
        check(bookmark != nil && abs((bookmark?.endTime ?? -1) - 10) < 0.01 && bookmark?.time == 0,
              "bookmark covers the last 30 s (here 0–10 s)", "\(String(describing: bookmark))")

        clock.advance(by: 15)
        detector.simulateMicReleased()
        check(await eventually { if case .ending = model.phase { return true } else { return false } },
              "mic released → ending countdown")
        check(model.notices.contains { if case .ending(id, _) = $0.kind { return true } else { return false } },
              "ending panel shown with Keep recording / Save now")
        check(!model.summaries.contains { $0.id == id }, "nothing saved before the grace period ends")

        clock.advance(by: 15)
        check(await eventually { model.phase == .idle && model.summaries.contains { $0.id == id } },
              "grace period over → call saved to the library")
        await model.waitForFinalizations()
        guard let record = model.record(id) else {
            check(false, "record readable")
            return nil
        }
        check(record.folder == "" && model.library.files(for: id)?.json.path.contains("/Inbox/") == true,
              "saved in the Inbox", model.library.files(for: id)?.json.path ?? "-")
        check(history.of(id).first == .queued, "saved with status queued", "\(history.of(id))")
        check(abs(record.duration - 27) < 0.5, "trimmed 2 s after the mic release (27 s)", "\(record.duration)")
        check(record.title == "Zoom call" && record.source.platform == .zoom && record.source.bundleID == "us.zoom.xos",
              "title and source from the detected app", "\(record.title) \(record.source)")
        check(record.bookmarks.count == 1 && record.bookmarks.first?.note == "augmentation idea", "bookmark saved")
        check(record.labeled == false && record.languageMode == .auto, "unlabeled, language from settings")
        check(model.pendingLabels == [id] && model.presentedLabel == id, "label panel queued and shown after the call")
        check(!model.notices.contains { $0.callID == id && $0.isAboutLiveCall }, "live-call toasts removed")

        check(await waitUntilReady(model, id), "transcription finishes", "\(String(describing: model.record(id)?.status))")
        let statuses = history.of(id)
        let order = [CallStatus.queued, .processing, .ready].compactMap { statuses.firstIndex(of: $0) }
        check(order.count == 3 && order == order.sorted(), "status queued → processing → ready", "\(statuses)")
        let ready = model.record(id)
        check((ready?.segments.count ?? 0) >= 3, "transcript has segments", "\(ready?.segments.count ?? 0)")
        check(ready?.speakers.contains { $0.isMe && $0.name == "Nahian" } == true, "mic track is the user (Nahian)")
        check(ready?.speakers.contains { $0.id == "s1" && $0.name == "Speaker 1" } == true, "remote speakers diarized")
        check(Set(ready?.languages ?? []) == ["en", "bn"], "bilingual transcript (en + bn)", "\(ready?.languages ?? [])")
        check(model.queue?.isPaused == false, "transcription resumed after the call")
        check(ready?.audio?.format == "m4a" && exists(directory.appendingPathComponent("them.m4a"))
              && !exists(directory.appendingPathComponent("them.wav")), "audio archived to m4a (WAVs removed)")
        check(!exists(RecordingManifest.url(in: directory)), "live.json removed once saved")
        let audio = model.audioFiles(for: id)
        check(audio.me?.lastPathComponent == "me.m4a" && audio.them?.lastPathComponent == "them.m4a",
              "audioFiles(for:) returns the kept audio")
        check(exists(SpeakerEmbeddingsFile.url(in: directory)), "speaker embeddings written")
        return id
    }

    /// (2) The label panel moves the call to Research/Thesis with tags; search finds a transcript word.
    func labelAndSearchFlow(_ model: AppModel, _ id: CallID) async {
        section("2. Label the call, search the transcript")
        let inboxFiles = model.library.files(for: id)
        model.saveLabel(id, title: "Advisor meeting – augmentation", folder: "Research/Thesis",
                        tags: ["research", "#thesis", "Research", "  "], notes: "Data augmentation for Bangla ASR",
                        starred: true, languageMode: .auto)
        let record = model.record(id)
        check(record?.folder == "Research/Thesis", "moved to Research/Thesis", record?.folder ?? "-")
        check(record?.tags == ["research", "thesis"], "tags cleaned (no #, no duplicates)", "\(record?.tags ?? [])")
        check(record?.labeled == true && record?.starred == true && record?.title == "Advisor meeting – augmentation",
              "labeled, starred, titled")
        let files = model.library.files(for: id)
        check(files?.json.path.contains("/Research/Thesis/") == true && exists(files?.markdown), "files moved",
              files?.json.path ?? "-")
        check(exists(files?.json) && !exists(inboxFiles?.json) && !exists(inboxFiles?.markdown), "no stale Inbox copy")
        check(model.pendingLabels.isEmpty && model.presentedLabel == nil, "label panel closed")
        let hits = model.library.search(SearchQuery(text: "multilingual"))
        check(hits.contains { $0.callID == id && $0.field == .transcript && $0.speakerName == "Speaker 1" },
              "search finds “multilingual” in the transcript", "\(hits.map(\.field))")
        let bangla = model.library.search(SearchQuery(text: "গবেষণার"))
        check(bangla.contains { $0.callID == id && $0.field == .transcript }, "search finds a Bangla word (গবেষণার)")
        let scoped = model.library.search(SearchQuery(text: "multilingual", folder: "Research", tag: "thesis"))
        check(scoped.contains { $0.callID == id }, "folder and tag filters match")
        check(model.recentFolders().first == "Research/Thesis", "recent folders lead with the new folder",
              "\(model.recentFolders())")
        check(model.tagSuggestions(matching: "th", excluding: []) == ["thesis"], "tag suggestions from the library")
    }

    /// (6) Rename (remembering the voice) and merge speakers; the next call recognizes the voice.
    func speakerFlow(_ model: AppModel, _ detector: MockCallDetector, _ id: CallID) async {
        section("6. Rename and merge speakers")
        model.renameSpeaker(id, speakerID: "s1", to: "Prof. Rahman", rememberVoice: true)
        let renamed = model.record(id)
        let s1 = renamed?.speaker("s1")
        check(s1?.name == "Prof. Rahman" && s1?.nameSource == .user, "speaker renamed")
        check(s1?.personID != nil && model.voiceprints.people().contains { $0.name == "Prof. Rahman" },
              "voice remembered (rememberVoices on)")
        check(renamed?.labeled == true, "renaming keeps the label state")
        let s2Segments = renamed?.segments.filter { $0.speakerID == "s2" }.map(\.id) ?? []
        check(!s2Segments.isEmpty, "the transcript has a second remote speaker")

        model.mergeSpeakers(id, from: "s2", into: "s1")
        let merged = model.record(id)
        check(merged?.speaker("s2") == nil, "merged speaker removed")
        check(s2Segments.allSatisfy { sid in merged?.segments.first { $0.id == sid }?.speakerID == "s1" },
              "its segments now belong to Prof. Rahman")
        let talk = merged?.segments.filter { $0.speakerID == "s1" }.reduce(0) { $0 + $1.end - $1.start } ?? -1
        check(abs((merged?.speaker("s1")?.talkTime ?? 0) - talk) < 0.01, "talk time recomputed", "\(talk)")

        if let segment = merged?.segments.first(where: { $0.speakerID == "s1" }) {
            model.reassignSegment(id, segmentID: segment.id, to: Speaker.meID)
            check(model.record(id)?.segments.first { $0.id == segment.id }?.speakerID == Speaker.meID,
                  "a segment can be reassigned to another speaker")
            model.reassignSegment(id, segmentID: segment.id, to: "s1")
        }
        model.renameSpeaker(id, speakerID: "s1", to: "", rememberVoice: false)
        check(model.record(id)?.speaker("s1")?.name == "Speaker 1", "an empty name restores the automatic name")
        model.renameSpeaker(id, speakerID: "s1", to: "Prof. Rahman", rememberVoice: false)

        // The next call: the remembered voice names its speaker automatically.
        guard let next = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "second Zoom call recorded")
            return
        }
        check(await waitUntilReady(model, next), "second call transcribed")
        let recognized = model.record(next)?.speaker("s1")
        check(recognized?.name == "Prof. Rahman" && recognized?.nameSource == .voiceprint,
              "remembered voice names the speaker in the next call",
              "\(recognized?.name ?? "-") \(recognized?.nameSource.rawValue ?? "-")")
        check(model.presentedLabel == next, "the new call's label panel is shown")

        // The panel's Later (Esc) and an untouched Save must not confirm the recognized name or
        // add this call's sample to the voiceprint: a wrong match would teach it the wrong person.
        guard let opened = model.record(next) else { return }
        let voice = { model.voiceprints.people().first { $0.name == "Prof. Rahman" } }
        let voiceBefore = voice()
        model.labelLater(next, draft: LabelDraft(record: opened))
        check(model.presentedLabel == nil && model.record(next)?.labeled == false
              && model.needsLabeling.contains { $0.id == next }, "Later keeps it unlabeled in the Inbox (needs labeling)")
        check(model.record(next)?.speaker("s1")?.nameSource == .voiceprint, "Later doesn't confirm a recognized voice")
        check(voice() == voiceBefore, "Later doesn't add a voice sample")
        var typed = LabelDraft(record: opened)
        typed.setSpeakerName("Dr. Karim", for: "s2")
        model.labelLater(next, draft: typed)
        check(model.record(next)?.speaker("s2")?.name == "Dr. Karim"
              && !model.voiceprints.people().contains { $0.name == "Dr. Karim" },
              "Later keeps a typed name but remembers no voice")
        model.saveLabel(next, draft: LabelDraft(record: model.record(next) ?? opened))
        check(model.record(next)?.speaker("s1")?.nameSource == .voiceprint && voice() == voiceBefore,
              "Save leaves a recognized name it wasn't asked to confirm alone")
        var confirmed = LabelDraft(record: model.record(next) ?? opened)
        confirmed.confirmSpeaker("s1")
        model.saveLabel(next, draft: confirmed)
        let confirmedSpeaker = model.record(next)?.speaker("s1")
        check(confirmedSpeaker?.name == "Prof. Rahman" && confirmedSpeaker?.nameSource == .user
              && voice()?.updatedAt != voiceBefore?.updatedAt,
              "Confirm + Save makes the name the user's and remembers the sample")
    }

    /// The label panel's language picker re-queues transcription.
    func languageFlow(_ model: AppModel, _ id: CallID) async {
        section("Language change re-transcribes")
        model.setLanguageMode(id, .bangla)
        check(model.record(id)?.languageMode == .bangla, "language stored")
        check(await eventually { model.processing[id] != nil || model.record(id)?.segments.allSatisfy { $0.language == "bn" } == true },
              "re-transcription queued")
        check(await waitUntilReady(model, id), "re-transcription finished")
        let record = model.record(id)
        check(record?.segments.allSatisfy { $0.language == "bn" } == true, "new transcript in Bangla mode")
        check(record?.speaker("s1")?.name == "Prof. Rahman", "user-given speaker names survive re-transcription")
        check(record?.folder == "Research/Thesis" && record?.labeled == true, "labels survive re-transcription")
    }

    func exportFlow(_ model: AppModel, _ effects: HeadlessEffects, _ id: CallID) async {
        section("Copy for AI and export")
        if let template = PromptTemplate.defaults.first {
            model.copyForAI(id, template: template)
            check(effects.pasteboard?.contains("Prof. Rahman") == true && effects.pasteboard?.contains("Nahian") == true,
                  "Copy for AI puts the filled prompt on the pasteboard")
        }
        let srt = (try? model.exportData(id, format: .srt)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(srt.contains("-->") && srt.contains("Prof. Rahman:"), "SRT export")
        let markdown = (try? model.exportData(id, format: .markdown)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(markdown.hasPrefix("---\nkan_id: ") && markdown.contains("## Bookmarks"), "Markdown export")
        model.revealInFinder(id)
        check(effects.revealed.first?.pathExtension == "md", "Reveal in Finder selects the transcript")
        model.showInLibrary(id, at: 12)
        check(model.libraryFocus?.callID == id && model.libraryFocus?.time == 12, "showInLibrary sets the focus request")
    }

    /// (7) Deleting a call removes its files and audio.
    func deleteFlow(_ model: AppModel, _ id: CallID) async {
        section("7. Delete a call")
        let files = model.library.files(for: id)
        let directory = model.environment.callDataDirectory(for: id)
        check(exists(files?.json) && exists(directory), "files exist before deleting")
        model.deleteCall(id, deleteAudio: true)
        check(!model.library.contains(id), "removed from the library")
        check(!exists(files?.json) && !exists(files?.markdown), "Markdown and JSON deleted")
        check(!exists(directory), "audio deleted")
        check(await eventually { !model.summaries.contains { $0.id == id } }, "list updated")
    }

    /// (3) A Telegram voice note uses the mic without sound: not a call.
    func voiceNoteFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("3. Telegram voice note")
        let before = model.library.summaries().count
        detector.simulateTelegramVoiceNote()
        clock.advance(by: 5)
        await settle()
        check(model.phase == .idle && model.liveCall == nil, "no recording for a voice note")
        check(detector.lastDecision?.contains("voice note") == true, "detector classified it as a voice note",
              detector.lastDecision ?? "-")
        clock.advance(by: 5)
        await settle()
        check(model.library.summaries().count == before, "nothing saved")
    }

    /// (4) An unknown app asks first; "Not now" discards; "Never" remembers the policy.
    func unknownAppFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("4. Unknown app → ask")
        let before = model.library.summaries().count
        let bundleID = MockApps.unknown.app.bundleID
        detector.simulateUnknownApp()
        clock.advance(by: 3)
        check(await eventually { model.liveCall?.isTentative == true }, "tentative recording while asking")
        guard let id = model.liveCall?.id else { return }
        check(model.notices.contains { $0.kind == .ask(id) }, "ask panel shown")
        check(model.presentedLabel == nil, "label panel not shown over a live call")
        let directory = model.environment.callDataDirectory(for: id)
        model.respondToAsk(.notNow)
        await model.waitForFinalizations()
        check(model.liveCall == nil && model.phase == .idle, "Not now stops the recording")
        check(!exists(directory), "tentative audio deleted")
        check(!model.notices.contains { $0.kind == .ask(id) }, "ask panel closed")
        check(model.library.summaries().count == before, "nothing saved")

        detector.simulateMicReleased(bundleID: bundleID)
        detector.simulateUnknownApp()
        clock.advance(by: 3)
        check(await eventually { model.liveCall?.isTentative == true }, "asked again next time")
        model.perform(.never, on: model.notices.first { if case .ask = $0.kind { return true } else { return false } }?.id)
        await model.waitForFinalizations()
        check(model.settings.appPolicies[bundleID] == .never && model.liveCall == nil,
              "Never for Voice Lounge saves the policy and discards")
        check(SettingsStore().load().appPolicies[bundleID] == .never, "policy persisted to settings.json")
        detector.simulateMicReleased(bundleID: bundleID)
        detector.simulateUnknownApp()
        clock.advance(by: 3)
        await settle()
        check(model.liveCall == nil && detector.lastDecision?.contains("never") == true, "never recorded again",
              detector.lastDecision ?? "-")
        detector.simulateMicReleased(bundleID: bundleID)
        check(model.library.summaries().count == before, "nothing saved")

        // A tentative call that ends unanswered: keep or discard the audio.
        model.settings.appPolicies[bundleID] = .ask
        model.saveSettings()
        detector.simulateUnknownApp()
        clock.advance(by: 3)
        guard await eventually({ model.liveCall?.isTentative == true }), let unanswered = model.liveCall?.id else {
            check(false, "tentative recording for the unanswered case")
            return
        }
        clock.advance(by: 30)
        detector.simulateMicReleased(bundleID: bundleID)
        clock.advance(by: 15)
        _ = await eventually { model.phase == .idle }
        await model.waitForFinalizations()
        check(model.notices.contains { $0.kind == .keepUnconfirmed(unanswered) } && !model.library.contains(unanswered),
              "unanswered call: asks whether to keep the recording")
        model.perform(.keepUnconfirmed(unanswered),
                      on: model.notices.first { $0.kind == .keepUnconfirmed(unanswered) }?.id)
        await model.waitForFinalizations()
        check(model.library.contains(unanswered) && model.record(unanswered)?.source.appName == "Voice Lounge",
              "Keep saves it as a call")
        _ = await waitUntilReady(model, unanswered)
        model.labelLater(unanswered)
        model.deleteCall(unanswered, deleteAudio: true)
    }

    /// (5) An automatically detected call shorter than minCallSeconds is discarded silently.
    func shortCallFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("5. Short automatic call")
        let before = model.library.summaries().count
        let labelsBefore = model.pendingLabels
        let problemsBefore = model.notices.filter { $0.style == .warning }.count
        guard let id = await recordZoomCall(model, detector, seconds: 5) else {
            check(false, "short call recorded")
            return
        }
        check(!model.library.contains(id) && model.library.summaries().count == before, "7 s call (< 20 s) not saved")
        check(!exists(model.environment.callDataDirectory(for: id)), "its audio was deleted")
        check(model.pendingLabels == labelsBefore, "no label panel for it")
        check(model.notices.filter { $0.style == .warning }.count == problemsBefore, "discarded silently")
        check(model.queue?.isPaused == false, "transcription resumed")
    }

    /// Ending → resumed, Keep recording, stale silence → Stop & save, Don't record.
    func endingAndStaleFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Ending, resume, stale silence, Don't record")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let id = model.liveCall?.id else {
            check(false, "call recorded")
            return
        }
        clock.advance(by: 30)
        detector.simulateMicReleased()
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        detector.simulateMicAcquired(MockApps.zoom)
        check(await eventually { model.phase == .recording }, "mic back before the deadline → resumed")
        check(!model.notices.contains { if case .ending = $0.kind { return true } else { return false } },
              "ending panel hidden")
        detector.simulateMicReleased()
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        model.perform(.keepRecording, on: model.notices.first { if case .ending = $0.kind { return true } else { return false } }?.id)
        check(model.phase == .recording, "Keep recording cancels the countdown")
        clock.advance(by: 60)
        await settle()
        check(model.phase == .recording && model.liveCall?.id == id, "still recording after the grace period")

        (model.services.recorder as? MockRecorder)?.currentHandle?.forceSilence(16 * 60)
        model.reportSilenceNow()
        check(await eventually { model.phase == .stale }, "long silence → Still in a call?")
        check(model.notices.contains { $0.kind == .stale(id) }, "stale panel shown")
        model.perform(.stopAndSave, on: model.notices.first { $0.kind == .stale(id) }?.id)
        await model.waitForFinalizations()
        check(model.phase == .idle && model.library.contains(id), "Stop & save saves the call")
        check(abs((model.record(id)?.duration ?? 0) - 90) < 1, "user stop isn't trimmed", "\(model.record(id)?.duration ?? 0)")
        _ = await waitUntilReady(model, id)

        // Don't record (start toast): discards everything.
        detector.simulateMicReleased()
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let discarded = model.liveCall?.id else {
            check(false, "call recorded for Don't record")
            return
        }
        model.perform(.discardRecording, on: model.notices.first { $0.kind == .recordingStarted(discarded) }?.id)
        await model.waitForFinalizations()
        check(model.liveCall == nil && !model.library.contains(discarded)
              && !exists(model.environment.callDataDirectory(for: discarded)), "Don't record deletes the recording")
        clock.advance(by: 5)
        await settle()
        check(model.liveCall == nil, "the same call isn't picked up again")
        detector.simulateMicReleased()
        model.closeLabel(id)
    }

    /// "Save now" during the end-of-call countdown keeps what waiting would have kept.
    func saveNowFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Save now during the countdown")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let id = model.liveCall?.id else {
            check(false, "call recorded")
            return
        }
        clock.advance(by: 25)
        detector.simulateMicReleased()
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        // 10 s into the 15 s countdown: another tab's video, someone in the room…
        clock.advance(by: 10)
        model.perform(.stopAndSave, on: model.notices.first { if case .ending = $0.kind { return true } else { return false } }?.id)
        await model.waitForFinalizations()
        let duration = model.record(id)?.duration ?? 0
        check(abs(duration - 27) < 0.5, "Save now trims 2 s after the mic release (27 s, not 35 s)", "\(duration)")
        _ = await waitUntilReady(model, id)
        model.closeLabel(id)
        model.deleteCall(id, deleteAudio: true)
    }

    /// Manual mic-only recording (in person), pause/resume.
    func manualFlow(_ model: AppModel) async {
        section("Manual recording (mic only)")
        model.startManualRecording(.micOnly)
        check(model.phase == .recording && model.liveCall?.detected.isManual == true, "manual recording started")
        guard let id = model.liveCall?.id else { return }
        check(!model.notices.contains { $0.kind == .recordingStarted(id) }, "no start toast for a manual recording")
        clock.advance(by: 10)
        model.pauseRecording()
        let pausedIndicator: Bool
        if case .paused = model.menuBarIndicator { pausedIndicator = true } else { pausedIndicator = false }
        check(model.liveCall?.isPaused == true && pausedIndicator, "paused (menu bar shows it)")
        clock.advance(by: 5)
        model.resumeRecording()
        check(model.liveCall?.isPaused == false, "resumed")
        clock.advance(by: 3)
        model.stopRecording()
        await model.waitForFinalizations()
        let record = model.record(id)
        check(record != nil && record?.source.platform == .manual && record?.title == "Recording",
              "saved even though it's shorter than 20 s (manual)", "\(record?.title ?? "-")")
        check(record?.audio?.themFile == nil && record?.audio?.meFile == "me.wav", "mic only: no them track")
        check(await waitUntilReady(model, id), "transcribed")
        check(model.record(id)?.segments.allSatisfy { $0.channel == .me } == true, "only the user's segments")
        model.closeLabel(id)
    }

    /// Label panels wait for a live call to end; an open panel isn't yanked away by a new call.
    func labelQueueFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Label panel queue")
        guard let first = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "first call recorded")
            return
        }
        check(model.presentedLabel == first, "label panel shown after the call")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let second = model.liveCall?.id else {
            check(false, "second call recorded")
            return
        }
        check(model.presentedLabel == first, "an open label panel stays while the next call records")
        model.labelLater(first)
        check(model.presentedLabel == nil, "no new label panel during a live call")
        clock.advance(by: 25)
        detector.simulateMicReleased()
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        clock.advance(by: 15)
        _ = await eventually { model.phase == .idle }
        await model.waitForFinalizations()
        check(model.presentedLabel == second, "the next label panel appears once the call ends")
        _ = await waitUntilReady(model, first)
        _ = await waitUntilReady(model, second)
        model.saveLabel(second, title: "", folder: "..", tags: [], notes: "", starred: false, languageMode: .auto)
        check(model.lastError?.contains("folder") == true && model.record(second)?.folder == "",
              "an invalid folder is refused (the call stays in the Inbox)")
        model.clearLastError()
        let directory = model.environment.callDataDirectory(for: second)
        model.deleteCall(second, deleteAudio: false)
        check(!model.library.contains(second) && exists(directory)
              && exists(directory.appendingPathComponent(RecordingManifest.detachedMarkerName)),
              "deleting a call but keeping its audio marks the audio as detached")
        check(model.presentedLabel == nil, "deleted call's label panel closed")
        model.deleteCall(first, deleteAudio: true)
    }

    /// The label panel takes the keyboard, so it waits while the user is still in a call Kan
    /// stopped or declined recording.
    func labelWaitFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Label panel waits for an unrecorded call")
        let zoom = MockApps.zoom.app.bundleID
        let zen = MockApps.zen.app.bundleID

        // Stop & Save part-way through a meeting: Zoom keeps the microphone.
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let partial = model.liveCall?.id else {
            check(false, "call recorded")
            return
        }
        clock.advance(by: 30)
        model.stopRecording()
        await model.waitForFinalizations()
        try? await Task.sleep(nanoseconds: 120_000_000)     // several polls
        check(model.library.contains(partial) && model.pendingLabels.contains(partial) && model.presentedLabel == nil,
              "Stop & Save mid-meeting: saved, but no label panel while Zoom has the microphone")
        detector.simulateMicReleased(bundleID: zoom)
        check(await eventually { model.presentedLabel == partial }, "the panel appears once Zoom lets go of the microphone")
        _ = await waitUntilReady(model, partial)
        model.labelLater(partial)

        // Back to back: call A in Zoom ends into a Meet call in Zen (B); "Don't record" on B.
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let a = model.liveCall?.id else {
            check(false, "first call recorded")
            return
        }
        clock.advance(by: 25)
        detector.simulateMicReleased()
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        clock.advance(by: 2)
        detector.simulateMicAcquired(MockApps.zen)
        clock.advance(by: 3)
        guard await eventually({ model.liveCall?.appName == "Zen" }), let b = model.liveCall?.id else {
            check(false, "the Zen call takes over")
            return
        }
        await model.waitForFinalizations()
        check(model.library.contains(a) && model.presentedLabel == nil, "A is saved; its panel waits behind the live call")
        model.perform(.discardRecording, on: model.notices.first { $0.kind == .recordingStarted(b) }?.id)
        await model.waitForFinalizations()
        try? await Task.sleep(nanoseconds: 120_000_000)
        check(model.liveCall == nil && model.presentedLabel == nil,
              "Don't record: still no panel while the user is in the Zen call", "\(String(describing: model.presentedLabel))")
        model.labelNow(a)
        check(model.presentedLabel == a, "Label now shows it anyway (an explicit request)")
        detector.simulateMicReleased(bundleID: zen)
        _ = await waitUntilReady(model, a)
        model.labelLater(a)
        model.deleteCall(a, deleteAudio: true)
        model.deleteCall(partial, deleteAudio: true)
    }

    /// Save in the label panel writes only what was changed there: edits made to the same call in
    /// the library window meanwhile survive.
    func labelPanelSaveFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Label panel saves only its own changes")
        // The automatic title follows a typed speaker name; an untouched panel changes nothing.
        let start = clock.now()
        var plain = CallRecord(id: CallID.generate(date: start), title: "", startedAt: start,
                               endedAt: start.addingTimeInterval(60), source: CallSource(appName: "Zoom", platform: .zoom))
        plain.speakers = [Speaker(id: Speaker.meID, name: "Nahian", isMe: true),
                          Speaker(id: "s1", name: Speaker.defaultName(number: 1), isMe: false)]
        plain.title = TranscriptRenderer.suggestedTitle(for: plain)
        var titled = LabelDraft(record: plain)
        titled.setSpeakerName("Prof. Karim", for: "s1")
        check(titled.title(for: plain) == "Zoom call with Prof. Karim" && titled.edits(for: plain).title == "Zoom call with Prof. Karim",
              "the automatic title follows a typed speaker name", titled.title(for: plain))
        check(LabelDraft(record: plain).edits(for: plain) == LabelEdits(), "an untouched panel saves nothing but the label")

        guard let id = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, id),
              let opened = model.record(id) else {
            check(false, "call recorded and transcribed")
            return
        }
        check(model.presentedLabel == id, "label panel open")
        var draft = LabelDraft(record: opened)          // the panel as it opened
        // Meanwhile, in the library window:
        model.renameSpeaker(id, speakerID: "s2", to: "Rahman", rememberVoice: false)
        model.update(id) { record in
            record.starred = true
            record.notes = "Edited in the library"
            record.tags = ["library"]
        }
        model.update(id) { $0.folder = "Research" }
        guard let edited = model.record(id) else { return }
        var refreshed = draft
        refreshed.setNotes("Typed in the panel")
        refreshed.refresh(from: edited)
        check(refreshed.starred && refreshed.folder == "Research" && refreshed.speakerNames["s2"] == "Rahman"
              && refreshed.notes == "Typed in the panel", "untouched fields follow the library's edits; typed ones stay")

        // Only a title was typed in the panel (its stale copy of the rest must not win).
        draft.setTitle("Panel title")
        model.saveLabel(id, draft: draft)
        let saved = model.record(id)
        check(saved?.title == "Panel title" && saved?.labeled == true && model.presentedLabel == nil,
              "Save writes the panel's title, labels the call and closes the panel")
        check(saved?.speaker("s2")?.name == "Rahman" && saved?.speaker("s2")?.nameSource == .user,
              "a speaker named in the library keeps the name", saved?.speaker("s2")?.name ?? "-")
        check(saved?.starred == true && saved?.notes == "Edited in the library" && saved?.tags == ["library"]
              && saved?.folder == "Research", "star, notes, tags and folder set in the library survive")

        // What the panel did change is written.
        guard let current = saved else { return }
        var second = LabelDraft(record: current)
        second.setFolder("Research/Thesis")
        second.setStarred(false)
        second.addTag("#panel")
        model.saveLabel(id, draft: second)
        let resaved = model.record(id)
        check(resaved?.folder == "Research/Thesis" && resaved?.starred == false && resaved?.tags == ["library", "panel"]
              && resaved?.notes == "Edited in the library" && resaved?.title == "Panel title",
              "the panel's own changes are saved, the rest kept", "\(resaved?.tags ?? [])")
        model.deleteCall(id, deleteAudio: true)
    }

    /// Deleting a call that is queued or being transcribed leaves no stale job behind; failed jobs
    /// stay (with Retry) only while the queue lists them.
    func processingCleanupFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Processing list after deletes and failures")
        // Discard from the label panel right after the call, while the job runs.
        guard let running = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "call recorded")
            return
        }
        model.discardCall(running)
        _ = await eventually { model.queue?.runningCallID != running }
        await settle()
        check(!model.library.contains(running) && model.processing[running] == nil
              && !model.activeProcessing.contains { $0.callID == running },
              "discarding during transcription leaves no stale “Cancelled” job", "\(String(describing: model.processing[running]))")

        // While the job waits in the queue.
        guard let queued = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "second call recorded")
            return
        }
        model.queue?.pause()
        _ = await eventually { model.queue?.runningCallID == nil }
        model.deleteCall(queued, deleteAudio: true)
        await settle()
        check(model.processing[queued] == nil && !model.activeProcessing.contains { $0.callID == queued },
              "…and while it waits in the queue", "\(String(describing: model.processing[queued]))")
        model.queue?.resume()

        // Deleting only the audio cancels the job too, and there's nothing left to retry.
        guard let audioless = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "call recorded for Delete Audio")
            return
        }
        model.deleteAudio(audioless)
        _ = await eventually { model.queue?.runningCallID != audioless }
        await settle()
        check(model.library.contains(audioless) && model.processing[audioless] == nil,
              "deleting the audio during transcription leaves no Retry that can't work",
              "\(String(describing: model.processing[audioless]))")
        model.closeLabel(audioless)
        model.deleteCall(audioless, deleteAudio: true)

        // A failed transcription is listed with Retry while the queue keeps it.
        (model.services.transcriber as? MockTranscriber)?.failNext(with: TranscriptionError.engineFailed("test failure"))
        guard let failing = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "third call recorded")
            return
        }
        check(await eventually { model.processing[failing]?.state == .failed }, "a failed job is listed")
        model.pruneFinishedProcessing()
        check(model.processing[failing]?.state == .failed && !model.isTranscribing,
              "…while the queue lists it, and doesn't count as busy")
        model.retranscribe(failing, languageMode: nil)
        check(await waitUntilReady(model, failing), "Retry transcribes it")
        // An entry the queue has forgotten (it drops finished jobs after a while) goes too.
        model.processing[failing] = ProcessingStatus(callID: failing, state: .failed, error: "old")
        model.pruneFinishedProcessing()
        check(model.processing[failing] == nil, "finished jobs the queue no longer lists are pruned")
        model.closeLabel(failing)
        model.deleteCall(failing, deleteAudio: true)
    }

    /// A call recorded before its models are installed waits for them and is transcribed once a
    /// download brings them; it's retried once per change of the installed models, never in a loop.
    func modelsWaitingFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Calls waiting for a model")
        guard let store = model.services.models as? MockModelStore, let queue = model.queue else {
            check(false, "mock model store and queue")
            return
        }
        for id in ["large-v3-turbo", "large-v3-q5_0"] { try? store.delete(id) }
        await model.updateModelReadiness()
        check(model.modelReadiness?.canTranscribe == false && model.problems.contains { $0.id == "models" },
              "no Whisper model installed: the menu says models are missing")
        guard let waiting = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "call recorded without models")
            return
        }
        check(await eventually { queue.callsWaitingForModels == [waiting] && model.record(waiting)?.status == .failed
                  && model.processing[waiting]?.state == .failed },
              "a call recorded meanwhile fails and waits for the model", "\(queue.callsWaitingForModels)")
        check(model.record(waiting)?.processing?.error?.contains("once the model is installed") == true
              && model.processing[waiting]?.state == .failed,
              "…and says it's transcribed once the model is installed", model.record(waiting)?.processing?.error ?? "-")
        await model.updateModelReadiness()
        await settle()
        check(queue.callsWaitingForModels == [waiting] && model.record(waiting)?.processing?.attempts == 1,
              "no retry while Kan still can't transcribe")

        model.downloadModel("large-v3-turbo")
        check(await waitUntilReady(model, waiting), "downloading the model transcribes the waiting call",
              "\(String(describing: model.record(waiting)?.status))")
        check(model.record(waiting)?.processing?.attempts == 2 && queue.callsWaitingForModels.isEmpty,
              "…in one more attempt", "attempts \(model.record(waiting)?.processing?.attempts ?? 0)")
        check(!model.problems.contains { $0.id == "models" }, "the missing-models problem is gone")

        // Kan can transcribe, but this call needs a model that isn't installed (Bangla).
        (model.services.transcriber as? MockTranscriber)?.failNext(with: TranscriptionError.modelMissing("bengali-medium-q8_0"))
        guard let bangla = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "call recorded without the Bangla model")
            return
        }
        check(await eventually { queue.callsWaitingForModels == [bangla] }, "a call missing one model waits for it too")
        await model.updateModelReadiness()      // Settings › Transcription opened: nothing new installed
        await settle()
        check(queue.callsWaitingForModels == [bangla] && model.record(bangla)?.processing?.attempts == 1,
              "a refresh with the same models installed doesn't retry it (no loop)")
        model.downloadModel("bengali-medium-q8_0")
        check(await waitUntilReady(model, bangla) && model.record(bangla)?.processing?.attempts == 2,
              "installing a model retries it, once", "attempts \(model.record(bangla)?.processing?.attempts ?? 0)")

        // Onboarding's one-click download covers only what no installed model does.
        try? store.delete("bengali-medium-q8_0")
        await model.updateModelReadiness()
        check(Set(model.missingRecommendedModels.map(\.id)) == ["large-v3-q5_0", "bengali-medium-q8_0"],
              "onboarding offers the recommended general and Bangla models when neither kind is installed",
              "\(model.missingRecommendedModels.map(\.id))")
        model.downloadModel("large-v3")
        _ = await eventually { model.modelDownloads.isEmpty && model.availableModels.contains { $0.id == "large-v3" && $0.installed } }
        check(model.missingRecommendedModels.map(\.id) == ["bengali-medium-q8_0"],
              "…but not the 1 GB large-v3 q5_0 next to an installed full large-v3", "\(model.missingRecommendedModels.map(\.id))")

        // Back to the models the other flows expect.
        try? store.delete("large-v3")
        model.downloadModel("large-v3-q5_0")
        _ = await eventually { model.modelDownloads.isEmpty && model.availableModels.contains { $0.id == "large-v3-q5_0" && $0.installed } }
        for id in [waiting, bangla] {
            model.closeLabel(id)
            model.deleteCall(id, deleteAudio: true)
        }
        model.removeNotices { if case .info = $0.kind { return true } else { return false } }
    }

    /// A call's voice samples (to remember a voice when a speaker is named) go when its audio goes,
    /// and every call's when Remember voices is turned off.
    func voiceSamplesFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Voice samples follow the audio and the setting")
        guard let first = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, first),
              let second = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, second) else {
            check(false, "calls recorded and transcribed")
            return
        }
        let samples = { (id: CallID) in SpeakerEmbeddingsFile.url(in: model.environment.callDataDirectory(for: id)) }
        check(exists(samples(first)) && exists(samples(second)), "calls keep voice samples while Remember voices is on")
        model.deleteAudio(first)
        check(!exists(samples(first)) && model.record(first)?.audio?.deletedAt != nil, "Delete Audio deletes the call's voice samples too")
        check(exists(samples(second)), "…only that call's")

        let people = model.voiceprints.people().count
        model.settings.rememberVoices = false
        model.saveSettings()
        check(await eventually { self.voiceSampleFiles(model).isEmpty },
              "turning Remember voices off deletes every call's voice samples", "\(voiceSampleFiles(model).map(\.path))")
        check(people > 0 && model.voiceprints.people().count == people, "remembered people stay until they're forgotten")
        guard let third = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, third) else {
            check(false, "call recorded with Remember voices off")
            return
        }
        check(!exists(samples(third)), "while it's off, new calls keep none")
        model.settings.rememberVoices = true
        model.saveSettings()

        // Keep call audio off: the queue deletes the audio, the samples stay (the speakers can still
        // be named), and Forget All Voices can delete them before anyone is remembered.
        model.forgetAllVoices()
        model.settings.keepAudio = false
        model.saveSettings()
        guard let unkept = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, unkept) else {
            check(false, "call recorded with Keep call audio off")
            return
        }
        check(model.record(unkept)?.audio?.deletedAt != nil && exists(samples(unkept)),
              "with Keep call audio off the audio is deleted and the voice samples stay (as Settings says)")
        model.refreshRememberedVoices()
        check(await eventually { model.voiceSampleCallCount == 1 } && model.rememberedVoiceCount == 0 && model.canForgetVoices,
              "Forget All Voices is available for samples alone", "samples \(model.voiceSampleCallCount)")
        model.forgetAllVoices()
        let cleared = await eventually { model.voiceSampleCallCount == 0 }
        check(!exists(samples(unkept)) && cleared && !model.canForgetVoices, "…and deletes them")
        model.settings.keepAudio = true
        model.saveSettings()
        for id in [first, second, third, unkept] {
            model.closeLabel(id)
            model.deleteCall(id, deleteAudio: true)
        }
    }

    /// The start toast offers "Never record <App>" only for apps outside the catalog (a guessed
    /// browser, an unknown app set to Auto): it discards the recording and keeps the app from being
    /// recorded again. Settings › Detection lists such apps from saved calls.
    func neverRecordFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Never record an app Kan doesn't know")
        func startToast(_ id: CallID) -> AppNotice? { model.notices.first { $0.kind == .recordingStarted(id) } }

        // Cataloged apps are recorded on purpose: no one-click Never for Zoom or Zen.
        for activity in [MockApps.zoom, MockApps.zen] {
            detector.simulateMicAcquired(activity)
            clock.advance(by: 3)
            guard await eventually({ model.liveCall?.appName == activity.app.name }), let id = model.liveCall?.id else {
                check(false, "\(activity.app.name) call recorded")
                return
            }
            check(startToast(id) != nil && startToast(id)?.buttons.contains { $0.command == .never } == false,
                  "\(activity.app.name)'s start toast has no “Never record” button", "\(startToast(id)?.buttons.map(\.title) ?? [])")
            model.perform(.discardRecording, on: startToast(id)?.id)
            await model.waitForFinalizations()
            detector.simulateMicReleased(bundleID: activity.app.bundleID)
        }

        // A browser outside the catalog (recognized by its Info.plist) is recorded automatically.
        let lumen = MockApps.unlistedBrowser
        detector.simulateMicAcquired(lumen)
        clock.advance(by: 3)
        guard await eventually({ model.liveCall?.appName == "Lumen" }), let id = model.liveCall?.id else {
            check(false, "Lumen call recorded")
            return
        }
        check(model.liveCall?.isTentative == false, "an unlisted browser is recorded automatically (the browser policy)")
        check(startToast(id)?.buttons.map(\.title) == ["Don't record", "Pause", "Never record Lumen"]
              && startToast(id)?.buttons.last?.command == .never,
              "its start toast offers “Never record Lumen”", "\(startToast(id)?.buttons.map(\.title) ?? [])")
        let directory = model.environment.callDataDirectory(for: id)
        model.perform(.never, on: startToast(id)?.id)
        await model.waitForFinalizations()
        check(model.liveCall == nil && !exists(directory) && !model.library.contains(id), "Never record discards the recording")
        check(model.settings.appPolicies[lumen.app.bundleID] == .never
              && SettingsStore().load().appPolicies[lumen.app.bundleID] == .never, "…and saves Never as the app's policy")
        detector.simulateMicReleased(bundleID: lumen.app.bundleID)
        detector.simulateMicAcquired(lumen)
        clock.advance(by: 3)
        await settle()
        check(model.liveCall == nil && detector.lastDecision?.contains("never") == true, "Lumen isn't recorded again",
              detector.lastDecision ?? "-")
        detector.simulateMicReleased(bundleID: lumen.app.bundleID)

        // An unknown app the user set to Auto gets the button too; its saved call lists it in Settings.
        let lounge = MockApps.unknown.app.bundleID
        let policy = model.settings.appPolicies[lounge]
        model.settings.appPolicies[lounge] = .auto
        model.saveSettings()
        detector.simulateUnknownApp()
        clock.advance(by: 3)
        guard await eventually({ model.liveCall?.appName == "Voice Lounge" }), let live = model.liveCall?.id else {
            check(false, "Voice Lounge call recorded")
            return
        }
        check(model.liveCall?.isTentative == false && startToast(live)?.buttons.contains { $0.title == "Never record Voice Lounge" } == true,
              "an unknown app set to Auto: recorded, with “Never record Voice Lounge”")
        clock.advance(by: 25)
        detector.simulateMicReleased(bundleID: lounge)
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        clock.advance(by: model.settings.endGraceNativeSeconds)
        _ = await eventually { model.phase == .idle }
        await model.waitForFinalizations()
        let apps = await model.recordedAppsOutsideCatalog()
        check(model.library.contains(live) && apps.contains(RecordedApp(bundleID: lounge, name: "Voice Lounge")),
              "Settings › Detection lists Voice Lounge from its saved call", "\(apps)")
        check(!model.summaries.isEmpty
              && !apps.contains { AppCatalog.lookup(bundleID: $0.bundleID) != nil || $0.bundleID == KanPaths.bundleIdentifier },
              "…but no cataloged app, nor Kan's own recordings", "\(apps.map(\.bundleID))")
        check(model.effectivePolicy(bundleID: lounge) == .auto, "…showing its policy (Auto)")
        model.settings.appPolicies[lounge] = nil
        check(model.effectivePolicy(bundleID: lounge) == model.settings.unknownAppPolicy,
              "…or, without one, the default for apps Kan doesn't know")
        model.settings.appPolicies[lounge] = policy
        model.saveSettings()
        _ = await waitUntilReady(model, live)
        model.closeLabel(live)
        model.deleteCall(live, deleteAudio: true)
    }

    /// Pausing detection; turning it off; resuming.
    func detectionPauseFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Pause and resume detection")
        model.pauseDetection(for: 3600)
        check(detector.currentConfig.pausedUntil != nil && model.detectionPausedUntil != nil, "paused for an hour")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        await settle()
        check(model.liveCall == nil && detector.lastDecision?.contains("paused") == true, "no recording while paused",
              detector.lastDecision ?? "-")
        detector.simulateMicReleased(bundleID: MockApps.zoom.app.bundleID)
        model.pauseDetection(for: nil)
        check(detector.currentConfig.enabled == false && model.detectionPausedIndefinitely, "paused until resumed")
        model.resumeDetection()
        check(detector.currentConfig.enabled && detector.currentConfig.pausedUntil == nil
              && model.detectionPausedUntil == nil && !model.detectionPausedIndefinitely, "resumed")
        model.settings.autoDetect = false
        model.saveSettings()
        check(detector.currentConfig.enabled == false, "turning auto-detect off reaches the detector")
        model.resumeDetection()
        check(model.settings.autoDetect && detector.currentConfig.enabled, "Resume turns auto-detect back on")
        model.settings.startConfirmSeconds = 5
        model.saveSettings()
        check(detector.currentConfig.startConfirmSeconds == 5, "detection settings apply at once")
        model.settings.startConfirmSeconds = 3
        model.saveSettings()
    }

    /// Hot keys, recording issues, onboarding.
    func hotkeyAndIssueFlow(_ model: AppModel, _ effects: HeadlessEffects) async {
        section("Hot keys, recording issues, onboarding")
        model.handleHotkey(.toggleRecording)
        check(model.liveCall?.detected.isManual == true && model.liveCall?.appName == "System audio",
              "⌃⌥⌘R starts an all-system-audio recording")
        guard let id = model.liveCall?.id else { return }
        clock.advance(by: 40)
        model.handleHotkey(.addBookmark)
        check(model.liveCall?.bookmarks.count == 1 && model.liveCall?.bookmarks.first?.endTime == 40, "⌃⌥⌘B bookmarks")
        let handle = (model.services.recorder as? MockRecorder)?.currentHandle
        handle?.raise(.systemAudioSilent)
        check(await eventually { model.recordingIssues.contains(.systemAudioSilent) }, "issue reported by the recorder")
        check(model.notices.contains { $0.style == .warning && $0.title.contains("can't hear the other side") }
              && model.notices.contains { $0.buttons.contains { $0.command == .openSystemSettings(.systemAudio) } },
              "“Kan can't hear the other side” toast with Open Settings")
        check(model.problems.contains { $0.id == "silent" }, "listed as a problem in the menu")
        if case .recording = model.menuBarIndicator {
            check(true, "menu bar keeps showing the recording")
        } else {
            check(false, "menu bar keeps showing the recording", "\(model.menuBarIndicator)")
        }
        model.handleHotkey(.toggleRecording)
        await model.waitForFinalizations()
        check(model.liveCall == nil && model.record(id)?.source.platform == .manual, "⌃⌥⌘R again stops and saves")
        check(model.recordingIssues.isEmpty && !model.problems.contains { $0.id == "silent" }, "issues cleared after the call")
        model.removeNotices { $0.style == .warning }
        _ = await waitUntilReady(model, id)
        model.closeLabel(id)

        // Disk full stops the recording and keeps what was recorded.
        model.startManualRecording(.systemAudio)
        guard let full = model.liveCall?.id else { return }
        clock.advance(by: 30)
        (model.services.recorder as? MockRecorder)?.currentHandle?.raise(.diskFull)
        check(await eventually { model.liveCall == nil }, "disk full stops the recording")
        await model.waitForFinalizations()
        check(model.library.contains(full), "…and saves what it had")
        model.removeNotices { $0.style == .warning }
        _ = await waitUntilReady(model, full)
        model.closeLabel(full)
        model.deleteCall(full, deleteAudio: true)
        model.deleteCall(id, deleteAudio: true)

        model.settings.onboardingCompleted = false
        model.completeOnboarding(launchAtLogin: true)
        check(model.settings.onboardingCompleted && SettingsStore().load().onboardingCompleted, "onboarding completion saved")
        check(effects.status == .enabled && model.loginItemStatus == .enabled, "launch at login enabled from onboarding")
        model.setLaunchAtLogin(false)
        check(model.loginItemStatus == .disabled, "launch at login can be turned off")
    }

    /// The tap issues post their notice once, with what's being recorded instead and no settings
    /// to change; the menu doesn't list them (the recorder can't retract an issue once it recovers).
    func issueNoticeFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Recording issue notices")
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.liveCall?.appName == "Zoom" }), let id = model.liveCall?.id,
              let handle = (model.services.recorder as? MockRecorder)?.currentHandle else {
            check(false, "Zoom call recorded")
            return
        }
        func warnings(_ prefix: String) -> [AppNotice] {
            model.notices.filter { $0.style == .warning && $0.title.hasPrefix(prefix) }
        }
        clock.advance(by: 30)
        handle.raise(.tapFailed)
        check(await eventually { model.recordingIssues.contains(.tapFailed) }, "tapFailed reported by the recorder")
        let tapFailed = warnings("Kan can't capture Zoom's audio right now")
        check(tapFailed.count == 1 && tapFailed.first?.message?.contains("Only your microphone is being recorded for now") == true
              && tapFailed.first?.message?.contains("Kan keeps trying") == true && tapFailed.first?.buttons.isEmpty == true,
              "tapFailed: only the microphone for now, Kan keeps trying (nothing to open)", "\(tapFailed.map(\.title))")
        model.recordingIssueRaised(.tapFailed, callID: id)
        check(warnings("Kan can't capture Zoom's audio").count == 1 && model.recordingIssues == [.tapFailed],
              "…posted once, however often it's reported")

        handle.raise(.systemAudioFallback)
        check(await eventually { model.recordingIssues.contains(.systemAudioFallback) }, "systemAudioFallback reported by the recorder")
        let fallback = warnings("Recording all system audio for this call")
        check(fallback.count == 1 && fallback.first?.message?.contains("Kan couldn't capture only Zoom") == true
              && fallback.first?.message?.contains("keeps trying to switch back") == true && fallback.first?.buttons.isEmpty == true,
              "systemAudioFallback: all system audio stands in, Kan keeps trying to switch back", fallback.first?.message ?? "-")
        model.recordingIssueRaised(.systemAudioFallback, callID: id)
        check(warnings("Recording all system audio").count == 1 && warnings("Kan can't capture Zoom's audio").count == 1
              && model.recordingIssues == [.tapFailed, .systemAudioFallback], "…posted once, next to the tapFailed notice")
        check(!model.problems.contains { ["silent", "systemAudio", "systemAudioRelaunch"].contains($0.id) },
              "the menu's problems don't list either", model.problems.map(\.id).joined(separator: ", "))
        if case .recording = model.menuBarIndicator {
            check(true, "the menu bar keeps showing the recording")
        } else {
            check(false, "the menu bar keeps showing the recording", "\(model.menuBarIndicator)")
        }
        model.stopRecording()
        await model.waitForFinalizations()
        detector.simulateMicReleased(bundleID: MockApps.zoom.app.bundleID)
        check(model.recordingIssues.isEmpty, "issues are cleared when the recording stops")
        model.removeNotices { $0.style == .warning }
        check(await waitUntilReady(model, id), "the call is saved and transcribed")
        model.closeLabel(id)
        model.deleteCall(id, deleteAudio: true)

        // Recording all system audio (no call app): the notice names what Kan can't capture.
        model.startManualRecording(.systemAudio)
        guard let manual = model.liveCall?.id else {
            check(false, "manual recording started")
            return
        }
        clock.advance(by: 30)
        (model.services.recorder as? MockRecorder)?.currentHandle?.raise(.tapFailed)
        check(await eventually { model.recordingIssues.contains(.tapFailed) }
              && warnings("Kan can't capture system audio right now").count == 1,
              "an all-system-audio recording: “Kan can't capture system audio right now”", model.notices.map(\.title).joined(separator: " | "))
        model.stopRecording()
        await model.waitForFinalizations()
        model.removeNotices { $0.style == .warning }
        _ = await waitUntilReady(model, manual)
        model.closeLabel(manual)
        model.deleteCall(manual, deleteAudio: true)
    }

    /// System Audio Recording turned on in System Settings while Kan runs applies only after a
    /// relaunch: the menu, the toast and the permission rows say so and offer Relaunch.
    func relaunchPermissionFlow(_ model: AppModel, _ effects: HeadlessEffects) async {
        section("System Audio Recording allowed, relaunch pending")
        guard let permissions = model.services.permissions as? MockPermissions else {
            check(false, "mock permissions")
            return
        }
        check(!model.needsRelaunch(.systemAudio) && !model.problems.contains { $0.id == "systemAudioRelaunch" },
              "a grant that applies needs nothing")
        permissions.simulate(.systemAudio, .granted, pendingRelaunch: true)
        model.refreshPermissions()
        check(await eventually { model.needsRelaunch(.systemAudio) }, "a grant made in System Settings while Kan runs is noticed")
        check(model.permissionStatuses[.systemAudio] == .granted && !model.needsRelaunch(.microphone),
              "…as granted, and only for System Audio Recording")
        let problem = model.problems.first { $0.id == "systemAudioRelaunch" }
        check(problem?.title == "System Audio Recording: allowed — relaunch Kan to apply" && problem?.action == .relaunch
              && problem?.actionTitle == "Relaunch", "the menu lists it with Relaunch", problem?.title ?? "-")
        let relaunches = effects.relaunchRequests
        if let action = problem?.action { model.perform(action) }
        check(effects.relaunchRequests == relaunches + 1, "Relaunch relaunches Kan")

        // A recording meanwhile hears only zeros: the toast and the menu say relaunch, not grant.
        model.startManualRecording(.systemAudio)
        guard let id = model.liveCall?.id else {
            check(false, "manual recording started")
            return
        }
        clock.advance(by: 30)
        (model.services.recorder as? MockRecorder)?.currentHandle?.raise(.systemAudioSilent)
        check(await eventually { model.recordingIssues.contains(.systemAudioSilent) }, "silence on the other side reported")
        let toast = model.notices.first { $0.style == .warning && $0.title == "Relaunch Kan to hear the other side" }
        check(toast?.buttons.map(\.command) == [.relaunch] && toast?.buttons.first?.role == .primary,
              "the toast offers Relaunch Kan, nothing to grant", model.notices.map(\.title).joined(separator: " | "))
        check(model.problems.first { $0.id == "silent" }?.action == .relaunch
              && !model.problems.contains { $0.id == "systemAudioRelaunch" }, "the menu's “can't hear” problem relaunches too (listed once)")
        model.stopRecording()
        await model.waitForFinalizations()
        model.removeNotices { $0.style == .warning }
        _ = await waitUntilReady(model, id)
        model.closeLabel(id)
        model.deleteCall(id, deleteAudio: true)

        permissions.simulate(.systemAudio, .granted)
        model.refreshPermissions()
        check(await eventually { !model.needsRelaunch(.systemAudio) } && !model.problems.contains { $0.id == "systemAudioRelaunch" },
              "once the grant applies, the problem is gone")
    }

    /// Toasts hide by themselves (hovering pauses that); prompts stay.
    func noticeFlow(_ model: AppModel) async {
        section("Toasts")
        model.postInfo("Short toast", seconds: 0.05)
        check(await eventually(timeout: 2) { !model.notices.contains { $0.title == "Short toast" } }, "info toast hides by itself")
        model.postInfo("Hovered toast", seconds: 0.1)
        if let id = model.notices.first(where: { $0.title == "Hovered toast" })?.id {
            model.noticeHoverChanged(id, hovering: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(model.notices.contains { $0.id == id }, "hovering keeps it open")
            model.dismissNotice(id)
        }
        model.postProblem("Persistent problem")
        model.postProblem("Persistent problem")
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(model.notices.filter { $0.title == "Persistent problem" }.count == 1, "problems stay and don't stack")
        model.removeNotices { $0.title == "Persistent problem" }
        // A toast's content is 302 pt wide; small buttons are ~50–170 pt.
        check(NoticeButtonRow.lines(widths: [60, 65, 140], width: 302, spacing: 6) == [[0, 1, 2]],
              "three toast buttons share a line when they fit")
        check(NoticeButtonRow.lines(widths: [88, 52, 176], width: 302, spacing: 6) == [[0, 1], [2]],
              "a third button that doesn't fit (“Never record <long name>”) wraps onto its own line")
        check(NoticeButtonRow.lines(widths: [88, 420, 52], width: 302, spacing: 6) == [[0], [1], [2]],
              "a button wider than the toast gets a line of its own")
    }

    /// Audio older than the retention period is deleted (starred calls kept).
    func retentionFlow(_ model: AppModel) async {
        section("Audio retention")
        let old = clock.now().addingTimeInterval(-40 * 86_400)
        var ids: [CallID] = []
        for starred in [false, true] {
            let id = CallID.generate(date: old)
            let directory = model.environment.callDataDirectory(for: id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("them.m4a").path, contents: Data(repeating: 1, count: 64))
            try? SpeakerEmbeddingsFile.write(["s1": MockTranscriber.embedding(for: "s1")], in: directory)
            let record = CallRecord(id: id, title: starred ? "Old starred call" : "Old call", starred: starred, labeled: true,
                                    startedAt: old, endedAt: old.addingTimeInterval(600),
                                    source: CallSource(appName: "Zoom", platform: .zoom), status: .ready,
                                    audio: AudioAssets(meFile: nil, themFile: "them.m4a", format: "m4a", sizeBytes: 64))
            _ = try? model.library.save(record)
            ids.append(id)
        }
        model.settings.audioRetentionDays = 30
        model.saveSettings()
        let deleted = await model.sweepAudioRetention()
        check(deleted == [ids[0]], "audio of the 40-day-old call deleted", "\(deleted)")
        check(model.record(ids[0])?.audio?.deletedAt != nil
              && !exists(model.environment.callDataDirectory(for: ids[0]).appendingPathComponent("them.m4a")),
              "record marks the audio deleted")
        check(model.record(ids[1])?.audio?.isAvailable == true, "starred call keeps its audio")
        let samples = ids.map { SpeakerEmbeddingsFile.url(in: model.environment.callDataDirectory(for: $0)) }
        check(!exists(samples[0]) && exists(samples[1]), "the expired audio's voice samples are deleted with it (the starred call's stay)")
        model.settings.audioRetentionDays = nil
        model.saveSettings()
        for id in ids { model.deleteCall(id, deleteAudio: true) }
    }

    /// An id that isn't a ULID never names the Calls directory itself or a path outside it.
    func defensiveIDFlow(_ model: AppModel) {
        section("Malformed call ids")
        let calls = model.environment.callsDirectory.standardizedFileURL
        for raw in ["", ".", "..", "../victim", "../../..", "/", "01jcz8x3k7v2m9q4r5s6t7w8y0"] {
            let id = CallID(rawValue: raw)
            let resolved = [model.environment.callDataDirectory(for: id), model.library.callDataDirectory(for: id)]
                .map(\.standardizedFileURL)
            check(resolved.allSatisfy { $0 != calls && $0.deletingLastPathComponent() == calls && !exists($0) },
                  "“\(raw)” resolves to a placeholder inside Calls, never Calls itself or outside it", "\(resolved.map(\.path))")
        }
        let good = CallID.generate(date: clock.now())
        check(model.environment.callDataDirectory(for: good).standardizedFileURL.path == calls.appendingPathComponent(good.rawValue).path,
              "a ULID resolves to Calls/<id>")
        model.deleteCall(CallID(rawValue: ""), deleteAudio: false)
        check(exists(calls) && !exists(calls.appendingPathComponent(RecordingManifest.detachedMarkerName)),
              "deleting a call with an empty id leaves the Calls directory alone")
        model.clearLastError()
    }

    /// Choosing the library folder: an empty folder or a Kan library is used as it is; a folder
    /// with other files (a vault) gets a "Kan" folder inside it.
    func libraryLocationFlow(_ model: AppModel) {
        section("Choosing the library folder")
        let fm = FileManager.default
        let base = home.appendingPathComponent("library-locations", isDirectory: true)
        func folder(_ path: String, _ files: [String: String] = [:]) -> URL {
            let url = base.appendingPathComponent(path, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, text) in files {
                let file = url.appendingPathComponent(name)
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
            return url
        }
        check(LibraryLocation.contents(of: base.appendingPathComponent("New")) == .empty, "a folder that doesn't exist yet is used as it is")
        check(LibraryLocation.contents(of: folder("Empty", [".DS_Store": ""])) == .empty, "…and so is an empty one (Finder's .DS_Store aside)")
        check(LibraryLocation.contents(of: model.library.root) == .kanLibrary, "Kan's own library is recognized (its index.md)")
        check(LibraryLocation.contents(of: folder("Guide", ["AGENTS.md": AgentsGuide.text, "Inbox/a.md": "a"])) == .kanLibrary,
              "…by Kan's AGENTS.md")
        check(LibraryLocation.contents(of: folder("Legacy", ["index.md": "# Kan call library\n\nOld rows"])) == .kanLibrary,
              "…by an older version's index.md")
        let vault = folder("Vault", [".obsidian/app.json": "{}", "Home.md": "# Home", "index.md": "# My index",
                                     "AGENTS.md": "# My own agent notes"])
        check(LibraryLocation.contents(of: vault) == .other, "an Obsidian vault with its own index.md and AGENTS.md isn't a Kan library")
        check(LibraryLocation.contents(of: folder("New vault", [".obsidian/app.json": "{}"])) == .other,
              "…nor is a new vault holding only .obsidian")
        check(LibraryLocation.suggestedSubfolder(in: vault).lastPathComponent == "Kan", "Kan offers a “Kan” folder inside it")
        _ = folder("Vault/Kan", ["notes.md": "my own"])
        check(LibraryLocation.suggestedSubfolder(in: vault).lastPathComponent == "Kan 2", "…“Kan 2” when “Kan” holds other files")
        let second = folder("Vault/Kan 2")
        try? fm.copyItem(at: model.library.indexMarkdownURL, to: second.appendingPathComponent("index.md"))
        _ = folder("Vault/Kan 2", ["Inbox/b.md": "b"])
        check(LibraryLocation.suggestedSubfolder(in: vault).lastPathComponent == "Kan 2", "…and a Kan library there is reused")
        try? fm.removeItem(at: base)
    }

    /// App Nap: Kan holds a user-initiated activity while it records (until the call is saved) and
    /// while a transcription runs — it has no window open then — and, while call detection is on,
    /// one that keeps the detector's tick from being napped; none otherwise.
    func appNapFlow(_ model: AppModel, _ effects: HeadlessEffects, _ detector: MockCallDetector) async {
        section("App Nap")
        check(await eventually { effects.activities == [AppModel.detectingActivity] },
              "idle: only call detection holds an activity", "\(effects.activities)")
        model.pauseDetection(for: nil)
        check(effects.activities.isEmpty, "…none while detection is paused", "\(effects.activities)")
        model.resumeDetection()
        check(effects.activities == [AppModel.detectingActivity], "…back when it resumes", "\(effects.activities)")
        model.settings.autoDetect = false
        model.saveSettings()
        check(effects.activities.isEmpty, "…none while automatic detection is off in Settings", "\(effects.activities)")
        model.settings.autoDetect = true
        model.saveSettings()
        check(effects.activities == [AppModel.detectingActivity], "…back when it's on again", "\(effects.activities)")
        let before = effects.activityHistory.count
        detector.simulateMicAcquired(MockApps.zoom)
        clock.advance(by: model.settings.startConfirmSeconds)
        guard await eventually({ model.phase == .recording }), let id = model.liveCall?.id else {
            check(false, "Zoom call recording")
            return
        }
        check(Set(effects.activities) == [AppModel.recordingActivity, AppModel.detectingActivity],
              "recording: Kan opts out of App Nap", "\(effects.activities)")
        clock.advance(by: 25)
        detector.simulateMicReleased(bundleID: MockApps.zoom.app.bundleID)
        _ = await eventually { if case .ending = model.phase { return true } else { return false } }
        check(effects.activities.contains(AppModel.recordingActivity), "…through the end-of-call countdown")
        clock.advance(by: model.settings.endGraceNativeSeconds)
        _ = await eventually { model.phase == .idle }
        await model.waitForFinalizations()
        check(await waitUntilReady(model, id), "call transcribed")
        let begun = Array(effects.activityHistory.dropFirst(before))
        check(begun.contains(AppModel.transcribingActivity), "transcribing: so does the transcription", "\(begun)")
        check(await eventually { effects.activities == [AppModel.detectingActivity] },
              "…and only detection's is held once the call is saved and transcribed", "\(effects.activities)")
        model.closeLabel(id)
        model.deleteCall(id, deleteAudio: true)
    }

    /// iCloud Drive syncs the library folder (Desktop & Documents in iCloud): onboarding and
    /// Settings say so and offer a folder on this Mac, which applies after a relaunch.
    func cloudLibraryFlow(_ model: AppModel, _ effects: HeadlessEffects) async {
        section("A library folder iCloud Drive syncs")
        model.refreshLibraryCloudStatus()
        await settle()
        check(!model.libraryInICloud, "a library outside iCloud Drive: no notice")
        effects.cloudDrive.setSynced([home])        // as if KAN_HOME were Documents in iCloud
        model.refreshLibraryCloudStatus()
        check(await eventually { model.libraryInICloud }, "a library iCloud Drive syncs is noticed (onboarding and Settings show it)")
        let local = model.localLibrarySuggestion
        check(local.path == home.appendingPathComponent("Kan", isDirectory: true).path, "Kan offers a “Kan” folder in the home folder",
              local.path)
        model.useLocalLibrary()
        check(model.settings.libraryPath == local.path && model.libraryRelocationPending && model.libraryInICloud,
              "choosing it applies after a relaunch; until then the notice stays (calls still go to the synced folder)")
        check(!FileManager.default.fileExists(atPath: local.path), "…and nothing is created or moved before that")
        model.settings.libraryPath = ""
        model.saveSettings()
        effects.cloudDrive.setSynced([])
        model.refreshLibraryCloudStatus()
        check(await eventually { !model.libraryInICloud } && !model.libraryRelocationPending, "back to the default library")
    }

    /// The log outlives deleted calls: errors are logged by kind, and messages that name a title,
    /// folder or person are logged with ids instead (the menu still shows them).
    func logPrivacyFlow(_ model: AppModel, _ detector: MockCallDetector) async {
        section("Log privacy")
        check(AppModel.logDescription(LibraryError.io("Couldn't save “Advisor meeting”: The disk is full.")) == "library file error",
              "a library error is logged by its kind, not its message")
        check(!AppModel.logDescription(LibraryError.invalidFolderName("Research/Secret")).contains("Secret"),
              "…and an invalid folder name isn't logged")
        let cocoa = CocoaError(.fileWriteNoPermission, userInfo: [
            NSFilePathErrorKey: "/Users/me/Documents/Kan/Research/2026-11-17 1430 Advisor meeting.md",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])
        let logged = AppModel.logDescription(cocoa)
        check(!logged.contains("Advisor") && logged == "NSCocoaErrorDomain 513 (NSPOSIXErrorDomain 13)",
              "a Cocoa file error is logged by domain and code (its message quotes the file name)", logged)
        check(AppModel.logDescription(TranscriptionError.modelMissing("large-v3")).contains("large-v3"),
              "errors that name no call keep their description")

        guard let id = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, id) else {
            check(false, "call recorded and transcribed")
            return
        }
        let text = await logText(until: "Remembered a voice") {
            model.saveLabel(id, title: "", folder: "Secret Project/..", tags: [], notes: "", starred: false, languageMode: .auto)
            model.renameSpeaker(id, speakerID: "s2", to: "Dr. Secretname", rememberVoice: true)
        }
        check(model.lastError?.contains("“Secret Project/..” can't be used as a folder name") == true,
              "the menu shows the folder name the user typed", model.lastError ?? "-")
        check(text.contains("Labeling \(id): the folder name can't be used") && text.contains("Remembered a voice (from \(id) s2)"),
              "the log says what happened, by call id", text)
        check(!text.contains("Secret") && !text.contains("Zoom call with"), "…without the folder, the person's name or the title", text)
        model.clearLastError()
        if let person = model.voiceprints.people().first(where: { $0.name == "Dr. Secretname" }) {
            try? model.voiceprints.forget(personID: person.id)
        }
        model.closeLabel(id)
        model.deleteCall(id, deleteAudio: true)

        // A label that files the call: the library moves and renames its files (their names are
        // the title, which now names the person typed for a speaker) and logs it by call id.
        guard let filed = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, filed),
              let opened = model.record(filed) else {
            check(false, "second call recorded and transcribed")
            return
        }
        var draft = LabelDraft(record: opened)
        draft.setFolder("Secret Project/Thesis")
        draft.setSpeakerName("Prof. Secretly", for: "s1")
        let moved = await logText(until: "Labeled \(filed)") { model.saveLabel(filed, draft: draft) }
        let saved = model.record(filed)
        check(saved?.folder == "Secret Project/Thesis" && saved?.title == "Zoom call with Prof. Secretly",
              "the label files the call under a title naming the person", saved?.title ?? "-")
        check(moved.contains("Moved call \(filed) to another folder") && moved.contains("Labeled \(filed) (a folder"),
              "the move is logged by call id", moved)
        check(!moved.contains("Secret") && !moved.contains("Thesis") && !moved.contains("Zoom call with"),
              "…without the folder, the new file name or the person's name", moved)
        if let person = model.voiceprints.people().first(where: { $0.name == "Prof. Secretly" }) {
            try? model.voiceprints.forget(personID: person.id)
        }
        model.deleteCall(filed, deleteAudio: true)
    }

    /// The model warm-up runs once per build for the models that are installed, and again for
    /// models installed later.
    func warmUpBookkeepingFlow() {
        section("Model warm-up bookkeeping")
        let nothing = ModelReadiness(canTranscribe: false, missing: ["No Whisper model is installed"])
        check(AppModel.warmableModels(nothing, diarize: true).isEmpty, "nothing installed: nothing to warm up or record")
        let installed = ModelReadiness(canTranscribe: true, resolved: [
            .general: "large-v3", .english: "large-v3-turbo", .bangla: "bengali-medium-q8_0",
            .vad: "silero-v6.2.0", .diarization: "fluidaudio-diarization",
        ])
        check(AppModel.warmableModels(installed, diarize: true)
              == ["large-v3", "large-v3-turbo", "bengali-medium-q8_0", "fluidaudio-diarization"],
              "the Whisper and speaker models are warmed up (VAD needs none)")
        check(!AppModel.warmableModels(installed, diarize: false).contains("fluidaudio-diarization"),
              "no speaker models without speaker separation")
        let both: Set<String> = ["large-v3", "fluidaudio-diarization"]
        let earlier = WarmUpRecord(build: "20261117.1", models: ["large-v3"])
        check(AppModel.modelsNeedingWarmUp(both, warmed: earlier, build: "20261117.1") == ["fluidaudio-diarization"],
              "a model installed after the warm-up gets one too")
        check(AppModel.modelsNeedingWarmUp(both, warmed: earlier, build: "20261118.1") == both, "a new build warms everything")
        check(AppModel.modelsNeedingWarmUp(["large-v3"], warmed: earlier, build: "20261117.1").isEmpty,
              "nothing new: no warm-up")
        guard let defaults = UserDefaults(suiteName: home.appendingPathComponent("warm-up-defaults").path) else { return }
        defaults.set("20261117.1", forKey: "KanWarmedUpBuild")      // recorded by an older version
        check(WarmUpRecord.load(from: defaults) == WarmUpRecord(build: "20261117.1", models: []),
              "an older record without its models counts as none warmed")
        WarmUpRecord(build: "20261117.1", models: both).save(to: defaults)
        WarmUpRecord.forget("fluidaudio-diarization", in: defaults)
        check(WarmUpRecord.load(from: defaults)?.models == ["large-v3"], "deleting a model forgets its warm-up")
    }

    /// Quitting saves a live call; the next launch recovers recordings that never reached the library.
    func recoveryAndQuitFlow(previous model: AppModel) async {
        section("Quit while recording; recover orphaned recordings")
        guard let detector = model.mockDetector else { return }
        detector.simulateMicReleased()
        detector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ model.phase == .recording }), let live = model.liveCall?.id else {
            check(false, "call recorded before quitting")
            return
        }
        clock.advance(by: 40)
        await model.prepareForTermination()
        check(model.library.contains(live) && model.record(live)?.status != .recording,
              "quitting saves the live recording")
        check(!detector.isRunning, "detection stopped on quit")
        check(model.queue?.isPaused == true, "transcription stopped on quit")
        // The old process is gone: wait until its interrupted job has been put back in the queue file.
        _ = await eventually { model.queue?.runningCallID == nil }
        await settle()
        check(!history.of(live).contains(.processing), "saving it doesn't start a transcription on the way out",
              "\(history.of(live))")

        // Orphans left by a crash: one with live.json, one deleted call (must stay deleted), and a
        // record stuck in .recording.
        let calls = model.environment.callsDirectory
        let orphanStart = clock.now().addingTimeInterval(-3600)
        let orphan = CallID.generate(date: orphanStart)
        let orphanDirectory = calls.appendingPathComponent(orphan.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        writeTone(orphanDirectory.appendingPathComponent("me.wav"), seconds: 30)
        writeTone(orphanDirectory.appendingPathComponent("them.wav"), seconds: 30)
        RecordingManifest(callID: orphan, appName: "Zoom", bundleID: "us.zoom.xos", category: .meeting, platform: .zoom,
                          detectedAt: orphanStart, recordingStartedAt: orphanStart, isManual: false, isTentative: false,
                          attendees: [], bookmarks: [Bookmark(time: 5, note: "before the crash")],
                          timeZone: TimeZone.current.identifier).write(in: orphanDirectory)

        let deletedCall = CallID.generate(date: orphanStart)
        let deletedDirectory = calls.appendingPathComponent(deletedCall.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        writeTone(deletedDirectory.appendingPathComponent("them.wav"), seconds: 30)
        FileManager.default.createFile(atPath: deletedDirectory.appendingPathComponent(RecordingManifest.detachedMarkerName).path,
                                       contents: Data())

        let stuck = CallID.generate(date: orphanStart.addingTimeInterval(60))
        let stuckDirectory = calls.appendingPathComponent(stuck.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: stuckDirectory, withIntermediateDirectories: true)
        writeTone(stuckDirectory.appendingPathComponent("them.wav"), seconds: 25)
        _ = try? model.library.save(CallRecord(id: stuck, title: "Stuck call", startedAt: orphanStart.addingTimeInterval(60),
                                               endedAt: orphanStart.addingTimeInterval(60),
                                               source: CallSource(appName: "Teams", platform: .teams), status: .recording))

        // An agent edits a call's JSON while Kan is quit: its Markdown is now older than the JSON.
        let editedStart = orphanStart.addingTimeInterval(120)
        let edited = CallRecord(id: CallID.generate(date: editedStart), title: "Offline edit", notes: "Notes before the edit",
                                labeled: true, startedAt: editedStart, endedAt: editedStart.addingTimeInterval(600),
                                source: CallSource(appName: "Zoom", platform: .zoom), status: .ready)
        let editedFiles = try? model.library.save(edited)
        if let files = editedFiles, let json = try? String(contentsOf: files.json, encoding: .utf8) {
            try? json.replacingOccurrences(of: "Notes before the edit", with: "Notes an agent edited while Kan was quit")
                .write(to: files.json, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                                   ofItemAtPath: files.markdown.path)
        }

        let (relaunched, _) = makeModel()
        await relaunched.startAndWait()
        let markdown = editedFiles.flatMap { try? String(contentsOf: $0.markdown, encoding: .utf8) } ?? ""
        check(markdown.contains("Notes an agent edited while Kan was quit") && !markdown.contains("Notes before the edit"),
              "a call's JSON edited while Kan was quit is rendered to Markdown again at launch")
        check(relaunched.library.contains(orphan), "orphaned recording recovered as a call")
        let recovered = relaunched.record(orphan)
        check(recovered?.source.appName == "Zoom" && recovered?.bookmarks.first?.note == "before the crash"
              && abs((recovered?.duration ?? 0) - 30) < 0.5, "recovered with its app, bookmarks and duration")
        check(relaunched.notices.contains { $0.title.hasPrefix("Recovered") }, "“Recovered …” toast shown",
              relaunched.notices.map(\.title).joined(separator: " | "))
        check(!relaunched.library.contains(deletedCall), "a deleted call's kept audio isn't resurrected")
        check(relaunched.record(stuck)?.status != .recording && abs((relaunched.record(stuck)?.duration ?? 0) - 25) < 0.5,
              "a record stuck in .recording is finished")
        check(await waitUntilReady(relaunched, orphan), "recovered recording transcribed")
        check(await waitUntilReady(relaunched, stuck), "stuck call transcribed")
        check(!exists(RecordingManifest.url(in: orphanDirectory)), "recovery is done once (live.json removed)")
        check(relaunched.library.contains(live) && relaunched.record(live)?.status == .ready,
              "the call saved on quit is transcribed after relaunch")
        check(relaunched.record(live)?.processing?.attempts == 1, "…in its first attempt",
              "attempts \(relaunched.record(live)?.processing?.attempts ?? 0)")

        // Quitting during the end-of-call countdown trims like the countdown would have.
        guard let nextDetector = relaunched.mockDetector else { return }
        nextDetector.simulateZoomCall()
        clock.advance(by: 3)
        guard await eventually({ relaunched.phase == .recording }), let last = relaunched.liveCall?.id else {
            check(false, "call recorded before quitting again")
            return
        }
        clock.advance(by: 30)
        nextDetector.simulateMicReleased()
        _ = await eventually { if case .ending = relaunched.phase { return true } else { return false } }
        clock.advance(by: 8)
        await relaunched.prepareForTermination()
        let duration = relaunched.record(last)?.duration ?? 0
        check(abs(duration - 32) < 0.5, "quitting during the countdown trims 2 s after the mic release (32 s)", "\(duration)")
    }

    /// macOS denied access to the library folder (Don't Allow on the Documents prompt): the menu
    /// says so at launch — calls can't be saved — and the problem goes once access is allowed.
    func libraryAccessFlow() async {
        section("A library folder macOS won't let Kan open")
        let fm = FileManager.default
        let documents = home.appendingPathComponent("Denied Documents", isDirectory: true)
        let root = documents.appendingPathComponent("Kan", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SettingsStore()
        var settings = store.load()
        let previousPath = settings.libraryPath
        settings.libraryPath = root.path
        try? store.save(settings)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path)
            settings.libraryPath = previousPath
            try? store.save(settings)
        }

        let (model, effects) = makeModel()
        await model.startAndWait()
        let problem = model.problems.first { $0.id == "library" }
        check(model.libraryProblem?.accessDenied == true && problem?.action == .openFilesAndFoldersSettings
              && problem?.title == "Kan can't open its library folder",
              "launching with access denied: the menu says Kan can't open its library folder", problem?.detail ?? "-")
        check(model.menuBarIndicator == .problem, "…and the menu-bar icon shows a problem")
        model.perform(.openFilesAndFoldersSettings)
        check(effects.openedURLs.last?.absoluteString.hasSuffix("Privacy_FilesAndFolders") == true,
              "“Open Settings” opens Privacy & Security › Files & Folders", "\(effects.openedURLs)")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path)
        model.refreshPermissions()          // Kan becomes active again, or the menu opens
        check(await eventually { model.libraryProblem == nil && !model.problems.contains { $0.id == "library" } },
              "once access is allowed, the problem goes")
        await model.prepareForTermination()
    }

    /// 16 kHz mono PCM16 with a quiet tone.
    func writeTone(_ url: URL, seconds: Double) {
        do {
            let writer = try WAV.Writer(url: url)
            let count = Int(seconds * Double(WAV.sampleRate))
            let samples = (0..<count).map { Int16(2000 * sin(Double($0) * 2 * .pi * 220 / Double(WAV.sampleRate))) }
            try writer.write(samples)
            try writer.finish()
        } catch {
            check(false, "write test WAV", "\(error)")
        }
    }
}
