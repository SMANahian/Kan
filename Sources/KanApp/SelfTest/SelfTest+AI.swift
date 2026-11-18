import Foundation
import KanAI
import KanCore

/// The OpenAI flows of `KanApp --self-test`: the mock assistant answers (or fails, or holds a
/// request) and the API key lives in an `InMemoryAPIKeyStore`. Nothing reaches the network or the
/// Keychain.
extension SelfTestRunner {
    static let testKey = "sk-selftest-1234567890abcdefghij-WXYZ"
    static let typedTitle = "Thesis chapter 3 with Rahman"

    func openAIFlows(_ model: AppModel, _ detector: MockCallDetector) async {
        guard let assistant = model.services.assistant as? MockAssistant,
              let keys = model.services.apiKeys as? InMemoryAPIKeyStore,
              let transcriber = model.services.transcriber as? MockTranscriber else {
            check(false, "mock OpenAI assistant, in-memory key store and mock transcriber")
            return
        }
        model.clearLastError()
        openAIHelperFlow()
        await openAIOffFlow(model, detector, assistant)
        await openAIKeyFlow(model, assistant, keys)
        let titled = await titleIdeasFlow(model, detector, assistant, transcriber)
        let summarized = await summaryFlow(model, detector, assistant, transcriber)
        await openAIRetranscriptionFlow(model, assistant, applied: titled?.applied, typed: titled?.typed,
                                        summarized: summarized)
        await openAIFailureFlow(model, detector, assistant)
        await openAIDeleteFlow(model, detector, assistant)
        await openAIManualFlow(model, detector, assistant)
        await openAILibraryFlow(model, detector, assistant)
        await openAIPrivacyFlow(model)
        // Back to what the other flows expect: both off, no key, no notices.
        model.settings.aiSuggestTitles = false
        model.settings.aiSummarize = false
        model.saveSettings()
        _ = await model.removeAPIKey()
        model.removeNotices { $0.title == AppModel.openAIProblemTitle }
        model.removeNotices { if case .info = $0.kind { return true } else { return false } }
        model.clearLastError()
    }

    // MARK: Helpers

    func aiMarkdown(_ model: AppModel, _ id: CallID) -> String {
        model.library.files(for: id).flatMap { try? String(contentsOf: $0.markdown, encoding: .utf8) } ?? ""
    }

    func aiJSON(_ model: AppModel, _ id: CallID) -> String {
        model.library.files(for: id).flatMap { try? String(contentsOf: $0.json, encoding: .utf8) } ?? ""
    }

    /// A Zoom call recorded, transcribed and with its label panel still open (nothing else queued).
    func recordReadyCall(_ model: AppModel, _ detector: MockCallDetector) async -> CallID? {
        guard let id = await recordZoomCall(model, detector, seconds: 25), await waitUntilReady(model, id) else { return nil }
        return id
    }

    func discardCalls(_ model: AppModel, _ ids: [CallID?]) {
        for id in ids.compactMap({ $0 }) {
            model.closeLabel(id)
            model.deleteCall(id, deleteAudio: true)
        }
    }

    /// Every .json, .md and .jsonl file in the library.
    nonisolated static func libraryFiles(in root: URL) -> [URL] {
        var files: [URL] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where ["json", "md", "jsonl"].contains(url.pathExtension) { files.append(url) }
        }
        return files
    }

    /// The whole self-test log (with its rotated part), once every line logged so far is in it.
    func wholeLog() async -> String {
        let marker = "self-test log flush \(UUID().uuidString)"
        KanLog.info(marker, category: "selftest")
        var text = ""
        _ = await eventually(timeout: 5) {
            text = ["kan-selftest-app.log.1", "kan-selftest-app.log"].compactMap { name in
                FileManager.default.contents(atPath: KanPaths.logs.appendingPathComponent(name).path)
                    .map { String(decoding: $0, as: UTF8.self) }
            }.joined()
            return text.contains(marker)
        }
        return text
    }

    // MARK: Flows

    /// The pure pieces: the title rule, the key hint, the summary's text in the library window.
    func openAIHelperFlow() {
        section("OpenAI: the title rule, the key hint, the summary's text")
        let start = clock.now()
        var record = CallRecord(id: CallID.generate(date: start), title: "Zoom call", startedAt: start,
                                endedAt: start.addingTimeInterval(600), source: CallSource(appName: "Zoom", platform: .zoom))
        record.speakers = [Speaker(id: Speaker.meID, name: "Nahian", isMe: true),
                           Speaker(id: "s1", name: "Prof. Rahman", isMe: false, nameSource: .voiceprint)]
        check(AppModel.isAutomaticTitle(record) && AppModel.titleFollowsIdeas(record),
              "“Zoom call” is still automatic after a recognized voice named a speaker")
        record.title = "Zoom call with Prof. Rahman"
        check(AppModel.isAutomaticTitle(record), "…and so is the title naming the speakers")
        record.title = "Advisor meeting"
        check(!AppModel.titleFollowsIdeas(record), "a title the user chose doesn't follow new ideas")
        record.ai = CallInsights(appliedTitle: "Advisor meeting")
        check(AppModel.titleFollowsIdeas(record), "…but the idea Kan applied does, while nobody changed it")
        check(AppModel.apiKeyHint(Self.testKey) == "sk-…WXYZ" && !AppModel.apiKeyHint(Self.testKey).contains("selftest")
              && AppModel.apiKeyHint("sk-short") == "sk-…",
              "the key's hint is “sk-…” and its last 4 characters (nothing of a short one)")
        check(AppModel.apiKeyProblem("sk-proj-abc def") != nil && AppModel.apiKeyProblem("sk-proj-abc…") != nil
              && AppModel.apiKeyProblem("  ") != nil && AppModel.apiKeyProblem(" \(Self.testKey)\n") == nil,
              "a key with spaces or an ellipsis inside (half copied) is refused; surrounding spaces aren't a problem")
        // A legacy key copied without its "sk-": 48 letters and digits.
        let bareKey = "T3BlbkFJ" + String(repeating: "q7Rt2xWm", count: 5)
        check([Self.testKey, "sk-proj-Ab3dEf", " SK-svcacct-x1 ", bareKey, "gpt 6.1 terra"].allSatisfy { AppModel.modelIDProblem($0) != nil },
              "Other…'s Model ID refuses an API key (or most of one) and text that can't be a model ID")
        check(["", "gpt-6.1-terra", " gpt-6-luna ", "o4-mini-2025-04-16", "ft:gpt-4o-mini-2024-07-18:personal:my-suffix:9tJ3abCD"]
                .allSatisfy { AppModel.modelIDProblem($0) == nil }
              && AppModel.loggableModelID("gpt-6.1-terra") == "gpt-6.1-terra" && AppModel.loggableModelID(Self.testKey) == "?",
              "…but takes model IDs, fine-tuned ones and an empty field (the default); the log never shows a key as the model")

        let stamps = LibrarySummaryText.timestamps(in: "Plan [00:12:34], data [1:02:03–1:02:10], [12:34] and not [12:99] or [x]")
        check(stamps.map(\.seconds) == [754, 3723, 754], "the summary's timestamps are found ([00:12:34], ranges, [12:34])",
              "\(stamps.map(\.seconds))")
        check(LibrarySummaryText.link(seconds: 754).flatMap(LibrarySummaryText.seconds(fromLink:)) == 754
              && LibrarySummaryText.seconds(fromLink: URL(fileURLWithPath: "/tmp")) == nil,
              "…as links to that moment of the call")
        check(LibrarySummaryText.paragraphs("First\nline.\n\n  \nSecond.") == ["First line.", "Second."],
              "the overview's paragraphs, each on one line")
        record.ai = CallInsights(summary: AISummary(overview: "What it was about.", keyPoints: ["One", " "], actionItems: ["Nahian: write it"],
                                                    language: .english, model: "gpt-6.1-terra", generatedAt: start,
                                                    fingerprint: CallInsights.fingerprint(of: record)))
        let lists = record.ai?.summary.map(LibrarySummaryText.lists) ?? []
        check(lists.map(\.heading) == ["Key points", "Action items"] && lists.first?.items == ["One"],
              "only the lists with items are shown, without blank items")
        let copied = LibrarySummaryText.clipboardText(record) ?? ""
        check(copied.hasPrefix("Summary of “Advisor meeting”\n\nWhat it was about.\n\nKey points:\n- One\n\nAction items:\n- Nahian: write it")
              && copied.contains("Written by OpenAI (GPT-6.1 Terra)"), "Copy puts plain, readable text on the clipboard", copied)
    }

    /// Off by default, and nothing is sent without a key.
    func openAIOffFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant) async {
        section("OpenAI: off by default; nothing without a key")
        let defaults = KanSettings()
        check(!defaults.aiSuggestTitles && !defaults.aiSummarize && defaults.effectiveAIModel == "gpt-6.1-terra"
              && defaults.aiLanguage == .english, "title ideas and summaries are off by default (GPT-6.1 Terra, English)")
        check(model.apiKeyState == .missing, "no key saved: the key state is “missing” once read", "\(model.apiKeyState)")
        let before = assistant.requests.count
        guard let off = await recordReadyCall(model, detector) else {
            check(false, "call recorded and transcribed")
            return
        }
        model.labelLater(off)
        await settle()
        check(assistant.requests.count == before && model.record(off)?.ai == nil && model.aiJobs.isEmpty,
              "settings off: a transcribed, labeled call sends nothing to OpenAI")
        model.settings.aiSuggestTitles = true
        model.settings.aiSummarize = true
        model.saveSettings()
        guard let keyless = await recordReadyCall(model, detector) else {
            check(false, "second call recorded and transcribed")
            return
        }
        model.labelLater(keyless)
        await settle()
        check(assistant.requests.count == before && model.record(keyless)?.ai == nil && model.aiJobs.isEmpty,
              "turned on without a key: still nothing is sent, and nothing waits")
        model.settings.aiSuggestTitles = false
        model.settings.aiSummarize = false
        model.saveSettings()
        discardCalls(model, [off, keyless])
    }

    /// Save (trimmed, refused when half copied), the hint, Test, reading it again, Remove.
    func openAIKeyFlow(_ model: AppModel, _ assistant: MockAssistant, _ keys: InMemoryAPIKeyStore) async {
        section("OpenAI: the API key")
        let refused = await model.saveAPIKey("sk-has a space")
        check(refused != nil && keys.loadKey() == nil && model.apiKeyState == .missing, "a key with a space inside isn't saved",
              refused ?? "-")
        let problem = await model.saveAPIKey("  \(Self.testKey)\n")
        check(problem == nil && keys.loadKey() == Self.testKey, "Save keeps the key, trimmed, in the key store", problem ?? "")
        check(model.apiKeyState == .saved(hint: "sk-…WXYZ"), "Settings shows only “sk-…WXYZ”", "\(model.apiKeyState)")
        model.saveSettings()
        let settingsFile = (try? String(contentsOf: KanPaths.settingsFile, encoding: .utf8)) ?? ""
        check(!settingsFile.isEmpty && !settingsFile.contains(Self.testKey) && !settingsFile.contains("selftest"),
              "settings.json never holds the key")

        await model.testAPIKey()
        check(model.apiKeyCheck == .passed(models: MockAssistant.defaultModels.sorted()) && model.keyCanUseChosenModel == true,
              "Test lists the key's models, the chosen one among them", "\(String(describing: model.apiKeyCheck))")
        check(assistant.requests(.models).last?.apiKey == Self.testKey, "…asking with the saved key")
        model.settings.aiModel = "gpt-4-retired"
        check(model.keyCanUseChosenModel == false, "…and tells when the chosen model isn't one of them")
        model.settings.aiModel = KanSettings.defaultAIModel
        model.saveSettings()

        // Other…: the key pasted into the Model ID field by mistake.
        let typed = model.setCustomModelID(" gpt-6-luna ")
        let pasted = model.setCustomModelID(Self.testKey)
        model.saveSettings()
        let afterPaste = (try? String(contentsOf: KanPaths.settingsFile, encoding: .utf8)) ?? ""
        check(typed == nil && pasted != nil && model.settings.aiModel == "gpt-6-luna" && afterPaste.contains("gpt-6-luna")
              && !afterPaste.contains(Self.testKey) && !afterPaste.contains("selftest"),
              "a key pasted into the Model ID field is refused with a message and never reaches settings.json",
              model.settings.aiModel)
        model.settings.aiModel = KanSettings.defaultAIModel
        model.saveSettings()
        assistant.failNext(.models, with: .invalidKey)
        await model.testAPIKey()
        check(model.apiKeyCheck == .failed(.invalidKey), "a key OpenAI doesn't accept: Test says so",
              "\(String(describing: model.apiKeyCheck))")

        // As at launch: read off the main thread.
        model.apiKey = nil
        model.apiKeyState = .loading
        await model.loadAPIKey()
        check(model.apiKeyState == .saved(hint: "sk-…WXYZ") && model.apiKey == Self.testKey, "the saved key is read (at launch)")

        model.settings.aiSuggestTitles = true
        model.settings.aiSummarize = true
        model.saveSettings()
        let removed = await model.removeAPIKey()
        check(removed == nil && keys.loadKey() == nil && model.apiKeyState == .missing && model.apiKeyCheck == nil,
              "Remove deletes the key")
        let saved = SettingsStore().load()
        check(!model.settings.aiSuggestTitles && !model.settings.aiSummarize && !saved.aiSuggestTitles && !saved.aiSummarize,
              "…and turns both features off, in settings.json too")
        _ = await model.saveAPIKey(Self.testKey)
        check(model.apiKeyState.isSaved, "saved again for the next flows")
        check(!model.settings.aiSuggestTitles && !model.settings.aiSummarize,
              "…which turns nothing back on: Kan doesn't start sending again by itself")
    }

    /// Title ideas: stored, the automatic title replaced (also in the open panel), a typed title
    /// kept, a title saved before the transcript kept, a key read late.
    func titleIdeasFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant,
                        _ transcriber: MockTranscriber) async -> (applied: CallID, typed: CallID)? {
        section("OpenAI: title ideas")
        model.settings.aiSuggestTitles = true
        model.saveSettings()
        let ideas = MockAssistant.defaultTitles
        assistant.setTitles(ideas)

        guard let id = await recordZoomCall(model, detector, seconds: 25), let opened = model.record(id) else {
            check(false, "call recorded")
            return nil
        }
        // The label panel as it opened: its title field takes focus and writes "Zoom call" back.
        var panel = LabelDraft(record: opened)
        echoFields(&panel, opened)
        check(model.presentedLabel == id, "the label panel is open")
        let ready = await waitUntilReady(model, id)
        let stored = await eventually { model.record(id)?.ai?.titleSuggestions != nil && model.aiJob(.titles, for: id) == nil }
        guard ready && stored, let record = model.record(id) else {
            check(false, "transcript ready → title ideas stored", "\(String(describing: model.aiJob(.titles, for: id)))")
            return nil
        }
        check(record.ai?.titleSuggestions?.titles == ideas, "transcript ready → three title ideas stored (ai.titleSuggestions)")
        check(record.title == ideas[0] && record.ai?.appliedTitle == ideas[0],
              "the automatic “Zoom call” became the first idea (kept as appliedTitle)", record.title)
        var shown = panel
        shown.refresh(from: record)
        echoFields(&shown, record)                  // the focused field writes the new title back, and on blur
        check(shown.title(for: record) == ideas[0] && !shown.isEdited(.title),
              "the open panel's untouched title field shows it (its chip selected), though it had focus all along",
              shown.title(for: record))
        check(record.ai?.titleSuggestions?.fingerprint == CallInsights.fingerprint(of: record)
              && record.ai?.titleSuggestions?.model == "gpt-6.1-terra" && record.ai?.titleSuggestions?.generatedAt == clock.now(),
              "…with the transcript's fingerprint, the model and the time")
        let request = assistant.requests(.titles, for: id)
        check(request.count == 1 && request.first?.apiKey == Self.testKey && request.first?.model == "gpt-6.1-terra"
              && request.first?.language == .english && request.first?.userName == "Nahian",
              "one request, with the key, the model, the language and the user's name")
        check(assistant.requests(.summary, for: id).isEmpty, "no summary (it's off)")
        check(aiMarkdown(model, id).contains("# \(ideas[0])"), "the call's .md has the new title")
        model.saveLabel(id, draft: shown)
        check(model.record(id)?.title == ideas[0] && model.record(id)?.ai?.appliedTitle == ideas[0] && model.presentedLabel == nil,
              "an untouched Save keeps it, still Kan's pick")
        if let retitled = model.record(id) {
            // Label now: the panel reopened on the call Kan retitled, saved untouched.
            var reopened = LabelDraft(record: retitled)
            echoFields(&reopened, retitled)
            model.saveLabel(id, draft: reopened)
            check(model.record(id).map { $0.title == ideas[0] && $0.ai?.appliedTitle == ideas[0] && AppModel.titleFollowsIdeas($0) } == true,
                  "reopened and saved untouched, it's still Kan's pick, which a new transcript may change")
        }

        // A title typed in the open panel while the ideas are on their way.
        assistant.hold(.titles)
        guard let typed = await recordZoomCall(model, detector, seconds: 25), let typedOpened = model.record(typed) else {
            check(false, "second call recorded")
            assistant.release(.titles)
            return nil
        }
        let typedReady = await waitUntilReady(model, typed)
        let asking = await eventually { assistant.inFlight(.titles) == 1 }
        check(typedReady && asking && model.aiJob(.titles, for: typed) == .running, "while OpenAI suggests titles, the panel says so")
        var typedDraft = LabelDraft(record: typedOpened)
        echoFields(&typedDraft, typedOpened)
        typedDraft.setText(Self.typedTitle, of: .title, in: typedOpened)
        assistant.release(.titles)
        _ = await eventually { model.record(typed)?.ai?.titleSuggestions != nil }
        if let current = model.record(typed) {
            typedDraft.refresh(from: current)
            echoFields(&typedDraft, current)
            check(typedDraft.title(for: current) == Self.typedTitle, "ideas arriving leave a title being typed in the panel alone")
        }
        model.saveLabel(typed, draft: typedDraft)
        let typedRecord = model.record(typed)
        check(typedRecord?.title == Self.typedTitle && typedRecord?.ai?.titleSuggestions?.titles == ideas,
              "Save writes the typed title; the ideas stay as suggestions", typedRecord?.title ?? "-")
        check(typedRecord.map { !AppModel.titleFollowsIdeas($0) } == true, "…and it's the user's title: new ideas won't replace it")

        // A title saved before the transcript is ready.
        transcriber.hold()
        guard let early = await recordZoomCall(model, detector, seconds: 25), let earlyOpened = model.record(early) else {
            check(false, "third call recorded")
            transcriber.release()
            return nil
        }
        var earlyDraft = LabelDraft(record: earlyOpened)
        earlyDraft.setTitle("Budget call")
        model.saveLabel(early, draft: earlyDraft)
        check(model.record(early)?.status != .ready && model.record(early)?.title == "Budget call",
              "a title saved in the panel before the transcript is ready")
        transcriber.release()
        let earlyReady = await waitUntilReady(model, early)
        let earlyIdeas = await eventually { model.record(early)?.ai?.titleSuggestions != nil }
        check(earlyReady && earlyIdeas && model.record(early)?.title == "Budget call" && model.record(early)?.ai?.appliedTitle == nil,
              "…stays when the ideas come", model.record(early)?.title ?? "-")

        // The key read after the transcript became ready (a slow keychain at launch).
        transcriber.hold()
        guard let late = await recordZoomCall(model, detector, seconds: 25) else {
            check(false, "fourth call recorded")
            transcriber.release()
            return nil
        }
        model.labelLater(late)
        model.apiKey = nil
        model.apiKeyState = .loading
        transcriber.release()
        _ = await waitUntilReady(model, late)
        await settle()
        check(assistant.requests(.titles, for: late).isEmpty, "a transcript ready while the key is still being read waits for it")
        await model.loadAPIKey()
        check(await eventually { model.record(late)?.ai?.titleSuggestions != nil }, "…and gets its ideas once the key is read")
        if let lateRecord = model.record(late) {
            check(lateRecord.title == ideas[0] && lateRecord.ai?.appliedTitle == ideas[0], "(Kan's pick)")
            var picked = LabelDraft(record: lateRecord)
            picked.setTitle(ideas[0])           // the selected chip clicked, or the same title typed
            model.saveLabel(late, draft: picked)
            check(model.record(late).map { $0.title == ideas[0] && $0.ai?.appliedTitle == nil && !AppModel.titleFollowsIdeas($0) } == true,
                  "picking Kan's own idea in the panel makes it the user's title")
        }
        discardCalls(model, [early, late])
        return (id, typed)
    }

    /// The summary waits for the label panel, uses the names given there, lands in the .md;
    /// Discard, Later, turning it off, no panel at all.
    func summaryFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant,
                     _ transcriber: MockTranscriber) async -> CallID? {
        section("OpenAI: summaries wait for the label panel")
        model.settings.aiSummarize = true
        model.saveSettings()
        guard let id = await recordReadyCall(model, detector) else {
            check(false, "call recorded and transcribed")
            return nil
        }
        _ = await eventually { model.record(id)?.ai?.titleSuggestions != nil }
        check(model.presentedLabel == id && model.aiJob(.summary, for: id) == .waiting && assistant.requests(.summary, for: id).isEmpty,
              "transcript ready with the panel open: the summary waits, nothing sent yet", "\(String(describing: model.aiJob(.summary, for: id)))")
        guard let current = model.record(id) else { return nil }
        var draft = LabelDraft(record: current)
        draft.setSpeakerName("Dr. Karim", for: "s2")
        draft.setRememberVoice(false, for: "s2")
        model.saveLabel(id, draft: draft)
        let stored = await eventually { model.record(id)?.ai?.summary != nil && model.aiJob(.summary, for: id) == nil }
        let saved = model.record(id)
        let requests = assistant.requests(.summary, for: id)
        check(stored && requests.count == 1, "Save → the summary is written and stored (ai.summary)")
        check(requests.first?.speakerNames.contains("Dr. Karim") == true
              && saved?.ai?.summary?.actionItems.contains { $0.hasPrefix("Dr. Karim:") } == true,
              "…from the transcript with the speaker names given in the panel", "\(requests.first?.speakerNames ?? [])")
        check(saved.map { $0.ai?.summary?.fingerprint == CallInsights.fingerprint(of: $0) && !$0.isSummaryOutdated } == true
              && saved?.ai?.summary?.model == "gpt-6.1-terra", "…for this transcript (its fingerprint), by the chosen model")
        let md = aiMarkdown(model, id)
        check(md.contains("## Summary") && md.contains("### Action items") && md.contains("Summary written by OpenAI"),
              "the call's .md has a “## Summary” section")
        check(await eventually { model.summaries.first { $0.id == id }?.hasSummary == true }, "the library list knows it has a summary")
        check(saved?.labeled == true && saved?.speaker("s2")?.name == "Dr. Karim", "the label and the names are saved as usual")

        // Renamed afterwards: outdated, and nothing is sent again.
        model.renameSpeaker(id, speakerID: "s1", to: "Prof. Rahman", rememberVoice: false)
        await settle()
        check(model.record(id)?.isSummaryOutdated == true && assistant.requests(.summary, for: id).count == 1,
              "renaming a speaker afterwards marks the summary outdated; nothing is sent again")
        check(aiMarkdown(model, id).contains("The transcript changed after this summary was written"), "…and the .md says so")

        // Discard while it waits.
        guard let discarded = await recordReadyCall(model, detector) else {
            check(false, "call recorded for Discard")
            return id
        }
        check(model.aiJob(.summary, for: discarded) == .waiting, "the next call's summary waits too")
        model.discardCall(discarded)
        await settle()
        check(assistant.requests(.summary, for: discarded).isEmpty && model.aiJob(.summary, for: discarded) == nil
              && !model.library.contains(discarded), "Discard while it waits: no summary is requested")

        // Later starts it as well.
        guard let later = await recordReadyCall(model, detector), let laterRecord = model.record(later) else {
            check(false, "call recorded for Later")
            return id
        }
        model.labelLater(later, draft: LabelDraft(record: laterRecord))
        check(await eventually { model.record(later)?.ai?.summary != nil }, "Later starts it as well")

        // The language is changed in the panel, which is closed before the new transcript is ready.
        guard let relabeled = await recordReadyCall(model, detector), let relabeledRecord = model.record(relabeled) else {
            check(false, "call recorded for a language change")
            return id
        }
        transcriber.hold()
        model.setLanguageMode(relabeled, .english)
        _ = await eventually { model.record(relabeled)?.status == .processing }
        model.labelLater(relabeled, draft: LabelDraft(record: relabeledRecord))
        await settle()
        check(assistant.requests(.summary, for: relabeled).isEmpty && model.aiJob(.summary, for: relabeled) == nil,
              "language changed in the panel, closed before the new transcript: the old one isn't summarized")
        transcriber.release()
        let relabeledDone = await eventually(timeout: 15) {
            model.record(relabeled)?.ai?.summary != nil && model.aiJob(.summary, for: relabeled) == nil
        }
        check(relabeledDone && assistant.requests(.summary, for: relabeled).count == 1
              && model.record(relabeled).map { !$0.isSummaryOutdated } == true,
              "…the new one is, once it's ready")

        // Turned off while one waits.
        guard let dropped = await recordReadyCall(model, detector) else {
            check(false, "call recorded for turning summaries off")
            return id
        }
        check(model.aiJob(.summary, for: dropped) == .waiting, "(waiting)")
        model.settings.aiSummarize = false
        model.saveSettings()
        check(model.aiJob(.summary, for: dropped) == nil, "turning summaries off drops one that waits")
        model.labelLater(dropped)
        await settle()
        check(assistant.requests(.summary, for: dropped).isEmpty, "…and nothing is sent when its panel closes")
        model.settings.aiSummarize = true

        // No label panel at all.
        model.settings.showLabelPrompt = false
        model.saveSettings()
        guard let unasked = await recordReadyCall(model, detector) else {
            check(false, "call recorded without a label panel")
            return id
        }
        check(!model.pendingLabels.contains(unasked)
              && (model.aiJob(.summary, for: unasked) == .running || model.record(unasked)?.ai?.summary != nil),
              "without a label panel (“Ask me to label the call” off), the summary is asked for as soon as the transcript is ready")
        check(await eventually { model.record(unasked)?.ai?.summary != nil }, "…and stored")
        model.settings.showLabelPrompt = true
        model.saveSettings()
        model.removeNotices { if case .info = $0.kind { return true } else { return false } }
        discardCalls(model, [later, relabeled, dropped, unasked])
        return id
    }

    /// A new transcript: an AI-applied title follows the new ideas, a typed one stays; a summary
    /// is written again for it.
    func openAIRetranscriptionFlow(_ model: AppModel, _ assistant: MockAssistant, applied: CallID?, typed: CallID?,
                                   summarized: CallID?) async {
        section("OpenAI: re-transcription")
        guard let applied, let typed, let summarized else {
            check(false, "calls from the title and summary flows")
            return
        }
        let next = ["Augmenting scarce Bangla speech data", "Pseudo-labels for Bangla ASR", "Dataset first, then training"]
        assistant.setTitles(next)
        check(model.record(summarized)?.isSummaryOutdated == true, "(the summary is outdated after the rename)")
        for id in [applied, typed, summarized] { model.retranscribe(id, languageMode: .english) }
        var ideas = true
        for id in [applied, typed, summarized] {
            let done = await eventually(timeout: 15) {
                model.record(id)?.ai?.titleSuggestions?.titles == next && model.aiJob(.titles, for: id) == nil
            }
            ideas = ideas && done
        }
        check(ideas, "re-transcription asks for new title ideas")
        check(model.record(applied)?.title == next[0] && model.record(applied)?.ai?.appliedTitle == next[0],
              "the title Kan applied follows the new ideas", model.record(applied)?.title ?? "-")
        check(model.record(typed)?.title == Self.typedTitle, "a title the user typed stays", model.record(typed)?.title ?? "-")
        let rewritten = await eventually(timeout: 15) {
            model.record(summarized).map { $0.ai?.summary != nil && !$0.isSummaryOutdated } == true
                && model.aiJob(.summary, for: summarized) == nil
        }
        check(rewritten && assistant.requests(.summary, for: summarized).count == 2,
              "the summary is written again for the new transcript (no longer outdated)")
        check(model.record(summarized)?.speaker("s2")?.name == "Dr. Karim", "…which kept the names the user gave")
        assistant.setTitles(MockAssistant.defaultTitles)
        discardCalls(model, [applied, typed, summarized])
    }

    /// Errors: shown with Retry, nothing stored, Retry works; account problems also get a notice.
    func openAIFailureFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant) async {
        section("OpenAI: failures and Retry")
        model.settings.aiSuggestTitles = true
        model.settings.aiSummarize = false
        model.saveSettings()
        assistant.failNext(.titles, with: .server(status: 503))
        guard let id = await recordReadyCall(model, detector) else {
            check(false, "call recorded and transcribed")
            return
        }
        check(await eventually { model.aiJob(.titles, for: id) == .failed(.server(status: 503)) },
              "a failed request shows its error, with Retry", "\(String(describing: model.aiJob(.titles, for: id)))")
        check(model.record(id)?.ai == nil && model.record(id)?.title == "Zoom call" && !aiJSON(model, id).contains("OpenAI had a problem"),
              "…nothing is stored (the error isn't kept in the call's files) and the title stays")
        check(!model.notices.contains { $0.title == AppModel.openAIProblemTitle } && model.lastError == nil,
              "a passing problem raises no notice and blocks nothing")
        model.suggestTitles(id)
        check(await eventually { model.record(id)?.ai?.titleSuggestions != nil && model.aiJob(.titles, for: id) == nil },
              "Retry works")
        model.closeLabel(id)

        // A passing problem in the background (a summary after a re-transcription): no notice either.
        model.settings.aiSummarize = true
        model.saveSettings()
        assistant.failNext(.summary, with: .timedOut)
        model.retranscribe(id, languageMode: nil)
        check(await eventually(timeout: 15) { model.aiJob(.summary, for: id) == .failed(.timedOut) }
              && !model.notices.contains { $0.title == AppModel.openAIProblemTitle },
              "a summary that timed out in the background: shown in the library, no notice",
              "\(String(describing: model.aiJob(.summary, for: id)))")

        // An account problem with the panel open: the panel shows it, no notice.
        assistant.failNext(.titles, with: .invalidKey)
        guard let panelOpen = await recordReadyCall(model, detector) else {
            check(false, "second call recorded")
            return
        }
        check(await eventually { model.aiJob(.titles, for: panelOpen) == .failed(.invalidKey) }
              && model.presentedLabel == panelOpen && !model.notices.contains { $0.title == AppModel.openAIProblemTitle },
              "a refused key while the label panel is open: the panel shows it (no notice)")

        // An account problem in the background (the summaries written after the panels close):
        // one notice, with Settings….
        assistant.failNext(.summary, with: .noCredit)
        assistant.failNext(.summary, with: .noCredit)
        model.labelLater(panelOpen)
        guard let other = await recordReadyCall(model, detector) else {
            check(false, "third call recorded")
            return
        }
        model.labelLater(other)
        let failedBoth = await eventually {
            model.aiJob(.summary, for: panelOpen) == .failed(.noCredit) && model.aiJob(.summary, for: other) == .failed(.noCredit)
        }
        let notices = model.notices.filter { $0.title == AppModel.openAIProblemTitle }
        check(failedBoth && notices.count == 1 && notices.first?.message == AIError.noCredit.message
              && notices.first?.buttons.first?.command == .openSettings,
              "out of credit: each call shows it, and one notice says so with Settings…", "\(notices.map(\.message))")
        model.summarize(other)
        check(await eventually { model.record(other)?.ai?.summary != nil && model.aiJob(.summary, for: other) == nil },
              "Retry writes the summary")

        // A spend or usage limit stops every later request too: the same notice.
        model.removeNotices { $0.title == AppModel.openAIProblemTitle }
        assistant.failNext(.summary, with: .spendLimit)
        model.transcriptDidBecomeReady(other)
        let limited = await eventually { model.aiJob(.summary, for: other) == .failed(.spendLimit) }
        let limitNotices = model.notices.filter { $0.title == AppModel.openAIProblemTitle }
        check(limited && limitNotices.count == 1 && limitNotices.first?.message == AIError.spendLimit.message
              && limitNotices.first?.buttons.first?.command == .openSettings,
              "a spend limit reached: an account problem like no credit, with the notice and Settings…",
              "\(String(describing: model.aiJob(.summary, for: other)))")
        _ = await eventually { model.aiJob(.titles, for: other) == nil }
        model.removeNotices { $0.title == AppModel.openAIProblemTitle }
        discardCalls(model, [id, panelOpen, other])
    }

    /// A call deleted while its request is in flight gets nothing written.
    func openAIDeleteFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant) async {
        section("OpenAI: deleting a call mid-request")
        model.settings.aiSuggestTitles = true
        model.settings.aiSummarize = false
        model.saveSettings()
        // The answers come even though Kan cancels the requests: Kan must drop them itself.
        assistant.answerWhenCancelled(true)
        defer { assistant.answerWhenCancelled(false) }
        for external in [false, true] {
            assistant.hold(.titles)
            guard let id = await recordReadyCall(model, detector) else {
                check(false, "call recorded")
                assistant.release(.titles)
                return
            }
            let files = model.library.files(for: id)
            let cancelledBefore = assistant.cancellations(.titles)
            let flying = await eventually { assistant.inFlight(.titles) == 1 }
            check(flying && model.aiJob(.titles, for: id) == .running, external ? "(another request in flight)" : "a request in flight")
            if external {
                // Behind Kan's back (Finder, another app): Kan doesn't know, so nothing is cancelled.
                for url in [files?.json, files?.markdown].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
            } else {
                model.discardCall(id)
                check(model.aiJob(.titles, for: id) == nil, "Discard stops the request at once (before the library's news)")
            }
            assistant.release(.titles)
            let answered = await eventually { assistant.inFlight(.titles) == 0 }
            await settle()
            check(answered && !model.library.contains(id) && !exists(files?.json) && !exists(files?.markdown),
                  external ? "deleted outside Kan mid-request: nothing is written either" : "discarding the call mid-request writes nothing")
            check(model.aiJob(.titles, for: id) == nil && model.lastError == nil, "…and reports nothing")
            if !external {
                check(assistant.cancellations(.titles) == cancelledBefore + 1, "…and the request is cancelled at once")
            }
            model.closeLabel(id)
            // The store has forgotten the call (it rescanned); its audio is what's left.
            if external { try? FileManager.default.removeItem(at: model.environment.callDataDirectory(for: id)) }
        }
    }

    /// The buttons work with a key alone: Suggest titles (once while it runs), apply an idea,
    /// Summarize, Remove, Cancel; removing the key stops a request.
    func openAIManualFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant) async {
        section("OpenAI: on request, with the settings off")
        model.settings.aiSuggestTitles = false
        model.settings.aiSummarize = false
        model.saveSettings()
        guard let id = await recordReadyCall(model, detector) else {
            check(false, "call recorded and transcribed")
            return
        }
        model.labelLater(id)
        await settle()
        check(assistant.requests(.titles, for: id).isEmpty && assistant.requests(.summary, for: id).isEmpty,
              "with the settings off nothing is sent by itself")
        check(model.record(id).map(AppModel.hasTranscriptForOpenAI) == true,
              "…but the transcript is ready: the panel offers Suggest titles, the library Summarize")
        assistant.hold(.titles)
        model.suggestTitles(id)
        model.suggestTitles(id)
        let flying = await eventually { assistant.inFlight(.titles) == 1 }
        check(flying && assistant.requests(.titles, for: id).count == 1, "Suggest titles pressed twice sends one request")
        assistant.release(.titles)
        check(await eventually { model.record(id)?.ai?.titleSuggestions != nil }, "Suggest titles works with a key alone")
        check(model.record(id)?.title == MockAssistant.defaultTitles[0], "…and the automatic title takes the first idea")
        model.applyTitleIdea(id, MockAssistant.defaultTitles[2])
        let picked = model.record(id)
        check(picked?.title == MockAssistant.defaultTitles[2] && picked?.ai?.appliedTitle == nil && picked?.labeled == true,
              "picking another idea in the library makes it the user's title")

        model.summarize(id)
        check(await eventually { model.record(id)?.ai?.summary != nil }, "Summarize works with a key alone")
        model.removeSummary(id)
        check(model.record(id)?.ai?.summary == nil && model.record(id)?.ai?.titleSuggestions != nil
              && !aiMarkdown(model, id).contains("## Summary"), "Remove summary deletes it (the ideas stay; the .md loses the section)")

        assistant.answerWhenCancelled(true)
        assistant.hold(.summary)
        model.summarize(id)
        _ = await eventually { assistant.inFlight(.summary) == 1 }
        model.cancelAIJob(.summary, for: id)
        assistant.release(.summary)
        _ = await eventually { assistant.inFlight(.summary) == 0 }
        await settle()
        check(model.record(id)?.ai?.summary == nil && model.aiJob(.summary, for: id) == nil,
              "Cancel drops the answer, even one already on its way")
        assistant.answerWhenCancelled(false)

        assistant.hold(.summary)
        model.summarize(id)
        _ = await eventually { assistant.inFlight(.summary) == 1 }
        _ = await model.removeAPIKey()
        assistant.release(.summary)
        _ = await eventually { assistant.inFlight(.summary) == 0 }
        await settle()
        check(model.record(id)?.ai?.summary == nil && model.aiJobs.isEmpty, "removing the key stops the requests in flight")
        model.suggestTitles(id)
        check(model.aiJob(.titles, for: id) == .failed(.missingKey), "without a key, a button says to add one")
        _ = await model.saveAPIKey(Self.testKey)

        // A call nobody spoke in.
        let start = clock.now()
        let silent = CallRecord(id: CallID.generate(date: start), title: "Silent call", startedAt: start,
                                endedAt: start.addingTimeInterval(60), source: CallSource(appName: "Zoom", platform: .zoom),
                                status: .ready)
        _ = try? model.library.save(silent)
        let before = assistant.requests.count
        model.suggestTitles(silent.id)
        check(await eventually { model.aiJob(.titles, for: silent.id) == .failed(.emptyTranscript) } && assistant.requests.count == before,
              "a call without a transcript: “This call has no transcript yet.”, nothing sent")
        model.settings.aiSuggestTitles = true
        model.cancelAIJobs(for: silent.id, reason: "self-test")
        model.transcriptDidBecomeReady(silent.id)
        check(model.aiJob(.titles, for: silent.id) == nil && assistant.requests.count == before,
              "…and a transcript without lines triggers nothing by itself")
        model.settings.aiSuggestTitles = false
        model.saveSettings()
        discardCalls(model, [id, silent.id])
    }

    /// The library window's own fields, driven through `LibraryCallDetailModel` as its views drive
    /// it (the header calls `beginEditingTitle` on focus and `commitTitle` when focus leaves; the
    /// window reloads the call on every save; SwiftUI writes a field's text back on focus and
    /// blur): an untouched title field follows the title Kan applies; a rename there is the user's
    /// for good, also one typed on from an idea picked with the field focused; a speaker renamed
    /// there makes the summary outdated at once.
    func openAILibraryFlow(_ model: AppModel, _ detector: MockCallDetector, _ assistant: MockAssistant) async {
        section("OpenAI in the library window: the title field, renames, an outdated summary")
        model.settings.aiSuggestTitles = false
        model.settings.aiSummarize = false
        model.saveSettings()
        guard let id = await recordReadyCall(model, detector) else {
            check(false, "call recorded and transcribed")
            return
        }
        model.labelLater(id)                        // unlabeled, in the Inbox
        let detail = LibraryCallDetailModel(callID: id, window: LibraryWindowModel(app: model))
        await detail.start()
        let ideas = MockAssistant.defaultTitles
        assistant.setTitles(ideas)

        // Clicked into the title, then ideas asked for (the sparkles menu next to it).
        detail.beginEditingTitle()
        detail.titleDraft = detail.titleDraft
        model.suggestTitles(id)
        _ = await eventually { model.record(id)?.ai?.titleSuggestions != nil && model.aiJob(.titles, for: id) == nil }
        await detail.start()
        detail.titleDraft = detail.titleDraft
        check(model.record(id)?.title == ideas[0] && detail.titleDraft == ideas[0],
              "the library's title field, focused but untouched, shows the title Kan just applied", detail.titleDraft)
        detail.commitTitle()
        await settle()
        let kept = model.record(id)
        check(kept?.title == ideas[0] && kept?.ai?.appliedTitle == ideas[0] && kept?.labeled == false,
              "…and leaving it writes nothing back: still Kan's pick, the call still unlabeled", kept?.title ?? "-")

        // Typed while new ideas arrive: the typed title wins, for good.
        let next = ["Augmenting scarce Bangla speech data", "Pseudo-labels for Bangla ASR", "Dataset first, then training"]
        assistant.setTitles(next)
        detail.beginEditingTitle()
        detail.titleDraft = "Speech data plan"
        model.suggestTitles(id)
        _ = await eventually { model.record(id)?.ai?.titleSuggestions?.titles == next && model.aiJob(.titles, for: id) == nil }
        await detail.start()
        check(model.record(id)?.title == next[0] && detail.titleDraft == "Speech data plan",
              "ideas arriving while a title is typed there leave the field alone", detail.titleDraft)
        detail.commitTitle()
        let renamed = model.record(id)
        check(renamed?.title == "Speech data plan" && renamed?.labeled == true && renamed?.ai?.appliedTitle == nil,
              "leaving it renames the call; Kan's pick no longer counts", renamed?.ai?.appliedTitle ?? "-")

        // Kan's earlier pick typed back later: the user's title, which new ideas leave alone.
        detail.beginEditingTitle()
        detail.titleDraft = next[0]
        detail.commitTitle()
        assistant.setTitles(ideas)
        model.suggestTitles(id)
        _ = await eventually { model.record(id)?.ai?.titleSuggestions?.titles == ideas && model.aiJob(.titles, for: id) == nil }
        check(model.record(id).map { $0.title == next[0] && !AppModel.titleFollowsIdeas($0) } == true,
              "Kan's earlier pick typed back in the library stays when new ideas come", model.record(id)?.title ?? "-")

        // An idea picked from the ✨ menu with the field focused (the menu leaves focus there), then
        // typed on: the typed title survives reloads and leaving the field saves it.
        await detail.start()
        detail.beginEditingTitle()
        detail.applyTitleIdea(ideas[1])
        let typed = ideas[1] + " – v2"
        detail.titleDraft = typed
        await detail.start()
        check(detail.titleDraft == typed, "typing on from an idea picked with the title field focused survives a reload",
              detail.titleDraft)
        if detail.isEditingTitle { detail.commitTitle() }   // the field loses focus, as in the header
        let typedOn = model.record(id)
        check(typedOn?.title == typed && typedOn?.ai?.appliedTitle == nil, "…and leaving the field saves it",
              typedOn?.title ?? "-")

        // A speaker renamed (or a line moved) in the window: the summary and the ideas are outdated at once.
        model.summarize(id)
        _ = await eventually { model.record(id)?.ai?.summary != nil && model.aiJob(.summary, for: id) == nil }
        await detail.start()
        check(!detail.summaryOutdated && !detail.titleIdeasOutdated, "(a summary for this transcript)")
        detail.renameSpeaker("s1", to: "Rahim", rememberVoice: false)
        check(detail.summaryOutdated && detail.titleIdeasOutdated,
              "renaming a speaker in the library window marks the summary and title ideas outdated at once")
        await detail.start()
        check(detail.summaryOutdated && model.record(id)?.isSummaryOutdated == true, "…and after the reload, as in the .md")
        model.summarize(id)
        _ = await eventually { model.record(id).map { $0.ai?.summary != nil && !$0.isSummaryOutdated } == true
            && model.aiJob(.summary, for: id) == nil }
        await detail.start()
        let moved = detail.record?.segments.first { $0.speakerID == "s1" }
        check(!detail.summaryOutdated && moved != nil, "(Regenerate: up to date again)")
        if let moved {
            detail.reassign(segmentID: moved.id, to: "s2")
            check(detail.summaryOutdated, "moving a line to another speaker there marks it outdated at once")
        }

        // Fields writing back what they show change nothing.
        detail.setFindQuery("the")
        _ = await eventually { detail.findState.ranges.count >= 2 }
        detail.findNext()
        detail.setFindQuery(detail.findQuery)       // the find field loses focus
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(detail.findState.ranges.count >= 2 && detail.findState.current == 1,
              "the find field writing its text back keeps the current match (no jump to the first)",
              "\(String(describing: detail.findState.current)) of \(detail.findState.ranges.count)")
        detail.editNotes(detail.notesDraft)
        model.update(id, markLabeled: false) { $0.notes = "Written in the label panel" }
        await detail.start()
        detail.saveNotes()
        check(detail.notesDraft == "Written in the label panel" && model.record(id)?.notes == "Written in the label panel",
              "a notes write that changes nothing saves nothing over notes written elsewhere", model.record(id)?.notes ?? "-")
        detail.stop()
        discardCalls(model, [id])
    }

    /// The key and what OpenAI wrote never reach the log, settings.json or the library files.
    func openAIPrivacyFlow(_ model: AppModel) async {
        section("OpenAI: logs, settings and the library never get the key")
        let log = await wholeLog()
        check(log.contains("[ai]") && log.contains("Saved 3 title idea(s) for") && log.contains("Saved the summary of"),
              "the log records OpenAI's jobs by call id")
        let secrets = [Self.testKey, "selftest-1234", MockAssistant.defaultTitles[0], "Augmenting scarce Bangla",
                       "multilingual model can be fine-tuned", Self.typedTitle, "Budget call", "Dr. Karim"]
        check(secrets.allSatisfy { !log.contains($0) }, "…never the key, the titles, the summary or the names",
              secrets.filter { log.contains($0) }.joined(separator: ", "))
        let settingsFile = (try? String(contentsOf: KanPaths.settingsFile, encoding: .utf8)) ?? ""
        check(!settingsFile.isEmpty && !settingsFile.contains(Self.testKey) && !settingsFile.contains("selftest"),
              "settings.json doesn't hold the key")
        let files = Self.libraryFiles(in: model.library.root)
        let leaked = files.filter { url in
            (try? String(contentsOf: url, encoding: .utf8))?.contains(Self.testKey) == true
        }
        check(!files.isEmpty && leaked.isEmpty, "no library file holds the key (\(files.count) files)")
    }
}
