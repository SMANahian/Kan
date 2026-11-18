import Foundation
import KanAI
import KanCore

// MARK: - OpenAI: the API key, title ideas and summaries
//
// Off by default: nothing is sent until the user saves a key and turns a feature on in Settings ›
// OpenAI, or presses a button (the library's Summarize and Suggest titles, the label panel's
// Suggest titles chip). Title ideas are asked for when a transcript is ready; the summary once the
// transcript is ready and the label panel is done with (Save, Later, or no panel), so it uses the
// speaker names given there. An answer is written with `LibraryStore.update` onto the call as it
// is stored then — only `ai`, plus the title rule — so edits made meanwhile in the label panel, the
// library window or by an agent are never lost. Jobs live in memory: a relaunch forgets them.
//
// The "ai" log gets call ids, counts, the model id, durations and `AIError.logDescription` only:
// never the key, titles, the summary, the transcript or anything else OpenAI wrote.

/// What the UI may know of the OpenAI API key: whether there is one, never the key.
enum APIKeyState: Equatable {
    /// Being read from the Keychain (at startup, off the main thread).
    case loading
    case missing
    /// "sk-…" and the key's last 4 characters.
    case saved(hint: String)

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

/// Settings › OpenAI › Test.
enum APIKeyCheck: Equatable {
    case checking
    /// The key works; the ids of the models it can use (`GET /v1/models`).
    case passed(models: [String])
    case failed(AIError)
}

/// What Kan asks OpenAI for.
enum AIJobKind: String, CaseIterable, Sendable {
    case titles, summary

    /// "title ideas", "summary" (log lines).
    var logName: String {
        switch self {
        case .titles: return "title ideas"
        case .summary: return "summary"
        }
    }
}

struct AIJobKey: Hashable, Sendable {
    var callID: CallID
    var kind: AIJobKind
}

/// One OpenAI job of a call, as the label panel and the library window show it.
enum AIJobState: Equatable {
    /// The summary waits until the call's label panel is closed.
    case waiting
    case running
    /// Shown with Retry until it is retried (or the call is deleted).
    case failed(AIError)
}

/// A request in flight. Its `token` tells its answer from a newer request's.
struct AIRequest {
    let token: UUID
    let task: Task<Void, Never>
    /// Started by a setting rather than a button.
    let automatic: Bool
}

private enum AIAnswer: Sendable {
    case titles(AITitleSuggestions)
    case summary(AISummary)
}

extension AppModel {
    /// The notice for failures every later request would hit too (the key, credit, the model).
    static let openAIProblemTitle = "Kan couldn't use OpenAI"

    // MARK: The API key

    /// Starts reading the saved key (`apiKeyState` is `.loading` until it's done).
    func loadAPIKeyInBackground() {
        guard apiKeyLoadTask == nil else { return }
        apiKeyLoadTask = Task { [weak self] in await self?.loadAPIKey() }
    }

    /// Reads the saved key off the main thread — the Keychain can wait for the user to allow Kan to
    /// use the item — then handles the calls whose transcript became ready meanwhile.
    func loadAPIKey() async {
        let store = services.apiKeys
        let loaded = await Task.detached(priority: .utility) { store.loadKey() }.value
        let key = loaded?.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = key?.isEmpty == false ? key : nil
        apiKeyState = apiKey.map { .saved(hint: Self.apiKeyHint($0)) } ?? .missing
        if apiKey != nil { KanLog.info("An OpenAI API key is saved", category: "ai") }
        let waiting = aiReadyBeforeKey
        aiReadyBeforeKey = []
        for id in waiting { transcriptDidBecomeReady(id) }
    }

    /// "sk-…" and the last 4 characters: all of the key the UI ever shows.
    nonisolated static func apiKeyHint(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // A key too short to be a real one would be shown almost whole.
        guard trimmed.count >= 12 else { return "sk-…" }
        return "sk-…" + trimmed.suffix(4)
    }

    /// Why `key` can't be an OpenAI API key, or nil: Kan refuses it before saving.
    nonisolated static func apiKeyProblem(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Paste your OpenAI API key first." }
        // A key is printable ASCII without spaces; one copied with a line break or an ellipsis inside
        // isn't the whole key (and couldn't go into a request header).
        guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            return "That isn't a whole API key: it has spaces or characters a key doesn't have. Copy it again from platform.openai.com."
        }
        return nil
    }

    /// Settings › OpenAI › Save: keeps the key in the Keychain (replacing an older one), off the
    /// main thread. Returns what went wrong, or nil.
    func saveAPIKey(_ input: String) async -> String? {
        if let problem = Self.apiKeyProblem(input) { return problem }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = services.apiKeys
        let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
            do {
                try store.saveKey(key)
                return nil
            } catch {
                return error
            }
        }.value
        if let failure {
            KanLog.error("Couldn't save the OpenAI API key: \(Self.logDescription(failure))", category: "ai")
            return Self.describe(failure)
        }
        apiKey = key
        apiKeyState = .saved(hint: Self.apiKeyHint(key))
        apiKeyCheck = nil
        KanLog.info("Saved an OpenAI API key", category: "ai")
        return nil
    }

    /// Settings › OpenAI › Remove: deletes the key from the Keychain, stops every OpenAI job and
    /// turns both features off — a key saved later starts nothing by itself. Returns what went
    /// wrong, or nil.
    func removeAPIKey() async -> String? {
        let store = services.apiKeys
        let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
            do {
                try store.deleteKey()
                return nil
            } catch {
                return error
            }
        }.value
        if let failure {
            KanLog.error("Couldn't remove the OpenAI API key: \(Self.logDescription(failure))", category: "ai")
            return Self.describe(failure)
        }
        apiKey = nil
        apiKeyState = .missing
        apiKeyCheck = nil
        cancelAllAIJobs(reason: "the API key was removed")
        // Without a key the switches show off and can't be changed: make it so.
        if settings.aiSuggestTitles || settings.aiSummarize {
            settings.aiSuggestTitles = false
            settings.aiSummarize = false
            saveSettings()
        }
        KanLog.info("Removed the OpenAI API key", category: "ai")
        return nil
    }

    /// Settings › OpenAI › Test: asks OpenAI which models the key can use (`apiKeyCheck`).
    func testAPIKey() async {
        guard let key = apiKey else {
            apiKeyCheck = .failed(.missingKey)
            return
        }
        apiKeyCheck = .checking
        let assistant = services.assistant
        let started = Date()
        do {
            let models = try await assistant.availableModels(apiKey: key)
            guard apiKey == key else { return }         // replaced or removed meanwhile
            apiKeyCheck = .passed(models: models)
            let model = settings.effectiveAIModel
            KanLog.info("OpenAI key check passed in \(Self.seconds(since: started)) s: \(models.count) model(s), "
                        + "\(Self.loggableModelID(model)) \(Self.models(models, include: model) ? "among them" : "not among them")",
                        category: "ai")
        } catch {
            guard apiKey == key else { return }
            if error is CancellationError {
                apiKeyCheck = nil
                return
            }
            let failure = Self.aiError(error)
            apiKeyCheck = .failed(failure)
            KanLog.warning("OpenAI key check failed: \(failure.logDescription)", category: "ai")
        }
    }

    /// After a passed Test: whether the key can use the model chosen in Settings (nil before a Test).
    var keyCanUseChosenModel: Bool? {
        guard case .passed(let models)? = apiKeyCheck else { return nil }
        return Self.models(models, include: settings.effectiveAIModel)
    }

    nonisolated static func models(_ models: [String], include model: String) -> Bool {
        let wanted = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    // MARK: The model

    /// Settings › OpenAI › Other…: the typed id becomes the model unless it can't be one
    /// (`modelIDProblem`), so an API key pasted there never reaches settings.json, `kan info` or
    /// the log. Returns the problem to show, or nil.
    @discardableResult
    func setCustomModelID(_ text: String) -> String? {
        if let problem = Self.modelIDProblem(text) { return problem }
        settings.aiModel = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return nil
    }

    /// Why `text` can't be saved as the model id, or nil (empty means the default model).
    nonisolated static func modelIDProblem(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if looksLikeAPIKey(id) {
            return "That looks like an API key, not a model ID, so Kan doesn't save it here. Keys go under API key above."
        }
        guard OpenAIModels.isWellFormedID(id) else {
            return "A model ID has only letters, digits and “.”, “_”, “:” or “-”, like \(KanSettings.defaultAIModel)."
        }
        return nil
    }

    /// An OpenAI API key, or most of one: "sk-…", or a run of 32 letters and digits, which a model
    /// id ("gpt-6.1-terra", "o4-mini-2025-04-16", "ft:gpt-4o-mini:org::abc123") never has.
    nonisolated static func looksLikeAPIKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sk-") { return true }
        return trimmed.split(whereSeparator: { "-_.:".contains($0) }).contains { $0.count >= 32 }
    }

    /// The model id as the log may show it: "?" for text that can't be one (a hand-edited
    /// settings.json), as KanAI does.
    nonisolated static func loggableModelID(_ id: String) -> String {
        OpenAIModels.isWellFormedID(id) && !looksLikeAPIKey(id) ? id : "?"
    }

    // MARK: Triggers

    /// A transcription job finished (`processingDidUpdate`): the call has a new transcript — the
    /// first one, a Retry, or another language. With a key saved and the settings on: title ideas
    /// now, the summary once the label panel is done with. Edits and renames trigger nothing.
    func transcriptDidBecomeReady(_ id: CallID) {
        guard settings.aiSuggestTitles || settings.aiSummarize else { return }
        if apiKeyState == .loading {
            if !aiReadyBeforeKey.contains(id) { aiReadyBeforeKey.append(id) }
            return
        }
        guard apiKey != nil, let record = record(id), record.status == .ready else { return }
        // Nobody spoke: nothing to send, and nothing to complain about.
        guard OpenAIPrompts.hasTranscript(record) else {
            KanLog.info("Call \(id) has no transcript lines; nothing to ask OpenAI", category: "ai")
            return
        }
        if settings.aiSuggestTitles { startAIJob(.titles, for: id, automatic: true, replacing: true) }
        guard settings.aiSummarize else { return }
        if pendingLabels.contains(id) {
            // Its label panel is open or next in line: the summary uses the names given there.
            let key = AIJobKey(callID: id, kind: .summary)
            stopRequest(key)
            aiJobs[key] = .waiting
            KanLog.info("The summary of \(id) waits until its label panel is closed", category: "ai")
        } else {
            startAIJob(.summary, for: id, automatic: true, replacing: true)
        }
    }

    /// Starts the summaries that waited for a label panel that has been closed (or won't be shown:
    /// the call was labeled in the library window).
    func startWaitingSummaries() {
        let ready = aiJobs.compactMap { key, state -> CallID? in
            key.kind == .summary && state == .waiting && !pendingLabels.contains(key.callID) ? key.callID : nil
        }
        for id in ready.sorted() {
            // A new transcript on its way (the language was changed in the panel) is summarized
            // when it's ready; the one it replaces isn't worth a request.
            guard settings.aiSummarize, apiKey != nil, let record = record(id),
                  record.status != .queued && record.status != .processing else {
                aiJobs[AIJobKey(callID: id, kind: .summary)] = nil
                continue
            }
            startAIJob(.summary, for: id, automatic: true, replacing: true)
        }
    }

    /// Summaries turned off in Settings: those waiting for a label panel aren't written.
    func dropWaitingSummaries() {
        let waiting = aiJobs.filter { $0.key.kind == .summary && $0.value == .waiting }.keys
        for key in waiting { aiJobs[key] = nil }
        if !waiting.isEmpty {
            KanLog.info("Summaries turned off: dropped \(waiting.count) that waited for a label panel", category: "ai")
        }
    }

    // MARK: Buttons

    /// The label panel's Suggest titles chip, the library's title menu, Retry. A saved key is
    /// enough; the setting needn't be on. A request already running isn't sent twice.
    func suggestTitles(_ id: CallID) {
        startAIJob(.titles, for: id, automatic: false, replacing: false)
    }

    /// The library's Summarize / Regenerate / Retry: now, even while the label panel is open.
    func summarize(_ id: CallID) {
        startAIJob(.summary, for: id, automatic: false, replacing: false)
    }

    /// The library's Remove summary (title ideas stay).
    func removeSummary(_ id: CallID) {
        cancelAIJob(.summary, for: id)
        guard record(id)?.ai?.summary != nil else { return }
        applyUpdate(id, markLabeled: false) { $0.ai?.summary = nil }
        KanLog.info("Removed the summary of \(id)", category: "ai")
    }

    /// The library's title menu: an idea becomes the title as if the user typed it, so new ideas
    /// never replace it.
    func applyTitleIdea(_ id: CallID, _ idea: String) {
        guard let title = idea.kanNonEmpty else { return }
        applyUpdate(id, markLabeled: true) { Self.setUserTitle(title, of: &$0) }
        KanLog.info("Applied a title idea to \(id)", category: "ai")
    }

    /// The library's Cancel: stops the request; its answer, if one still comes, is dropped.
    func cancelAIJob(_ kind: AIJobKind, for id: CallID) {
        let key = AIJobKey(callID: id, kind: kind)
        guard aiRequests[key] != nil || aiJobs[key] != nil else { return }
        let wasRunning = aiRequests[key] != nil
        stopRequest(key)
        aiJobs[key] = nil
        if wasRunning { KanLog.info("Cancelled the OpenAI \(kind.logName) request for \(id)", category: "ai") }
    }

    /// The call is discarded or deleted: nothing more is sent for it and no answer is saved.
    func cancelAIJobs(for id: CallID, reason: String) {
        var stopped = 0
        for kind in AIJobKind.allCases {
            let key = AIJobKey(callID: id, kind: kind)
            if aiRequests[key] != nil || aiJobs[key] == .waiting { stopped += 1 }
            stopRequest(key)
            aiJobs[key] = nil
        }
        aiReadyBeforeKey.removeAll { $0 == id }
        if stopped > 0 { KanLog.info("Stopped \(stopped) OpenAI job(s) for \(id): \(reason)", category: "ai") }
    }

    /// Quitting, or the key was removed.
    func cancelAllAIJobs(reason: String) {
        let stopped = aiRequests.count + aiJobs.values.filter { $0 == .waiting }.count
        for key in Array(aiRequests.keys) { stopRequest(key) }
        aiJobs = [:]
        aiReadyBeforeKey = []
        if stopped > 0 { KanLog.info("Stopped \(stopped) OpenAI job(s): \(reason)", category: "ai") }
    }

    func aiJob(_ kind: AIJobKind, for id: CallID) -> AIJobState? {
        aiJobs[AIJobKey(callID: id, kind: kind)]
    }

    /// A transcript OpenAI can be asked about: transcribed (a failed re-transcription keeps the
    /// previous transcript), with lines somebody said.
    nonisolated static func hasTranscriptForOpenAI(_ record: CallRecord) -> Bool {
        (record.status == .ready || record.status == .failed) && OpenAIPrompts.hasTranscript(record)
    }

    // MARK: Title rule

    /// New title ideas may retitle the call: its title is still the automatic one, or the idea Kan
    /// applied before that nobody changed since. A title the user typed never changes.
    nonisolated static func titleFollowsIdeas(_ record: CallRecord) -> Bool {
        if let applied = record.ai?.appliedTitle, !applied.isEmpty, record.title == applied { return true }
        return isAutomaticTitle(record)
    }

    /// The title nobody chose: the automatic one for the call as it is, or as it was saved — before
    /// its speakers had names (a recognized voice names a speaker without retitling the call).
    nonisolated static func isAutomaticTitle(_ record: CallRecord) -> Bool {
        if record.title == TranscriptRenderer.suggestedTitle(for: record) { return true }
        var unnamed = record
        unnamed.speakers = []
        return record.title == TranscriptRenderer.suggestedTitle(for: unnamed)
    }

    /// Every rename by the user — typed or picked, in the label panel or the library window: the
    /// title is theirs, and Kan's earlier pick no longer counts, so new ideas never replace it
    /// (not even when it's the same text). Only an automatic title keeps following them.
    nonisolated static func setUserTitle(_ title: String, of record: inout CallRecord) {
        record.title = title
        if !isAutomaticTitle(record) { record.ai?.appliedTitle = nil }
    }

    // MARK: Running a job

    /// Sends a request for the call as it is stored now. One per call and kind: a request already
    /// running is kept (a button pressed again) or `replacing`ly cancelled (a newer transcript).
    /// Nothing new once quitting has begun: a transcript that becomes ready while the last
    /// recording is saved would be sent (and billed) for an answer nobody keeps.
    @discardableResult
    func startAIJob(_ kind: AIJobKind, for id: CallID, automatic: Bool, replacing: Bool) -> Bool {
        guard !isTerminating else { return false }
        let key = AIJobKey(callID: id, kind: kind)
        if aiRequests[key] != nil && !replacing { return false }
        guard let apiKey else {
            stopRequest(key)
            aiJobs[key] = .failed(.missingKey)
            return false
        }
        guard let record = record(id) else {
            stopRequest(key)
            aiJobs[key] = nil
            return false
        }
        stopRequest(key)
        let options = AIOptions(apiKey: apiKey, model: settings.effectiveAIModel, language: settings.aiLanguage,
                                userName: settings.userName.kanSingleLine)
        let token = UUID()
        let assistant = services.assistant
        let started = Date()
        let task = Task { [weak self] in
            let answer: Result<AIAnswer, Error>
            do {
                switch kind {
                case .titles: answer = .success(.titles(try await assistant.suggestTitles(for: record, options: options)))
                case .summary: answer = .success(.summary(try await assistant.summarize(record, options: options)))
                }
            } catch {
                answer = .failure(error)
            }
            self?.finishAIJob(key, token: token, answer: answer, started: started)
        }
        aiRequests[key] = AIRequest(token: token, task: task, automatic: automatic)
        aiJobs[key] = .running
        KanLog.info("Asking OpenAI (\(Self.loggableModelID(options.model))) for the \(kind.logName) of \(id)"
                    + (automatic ? "" : ", as the user asked"), category: "ai")
        return true
    }

    private func stopRequest(_ key: AIJobKey) {
        aiRequests.removeValue(forKey: key)?.task.cancel()
    }

    private func finishAIJob(_ key: AIJobKey, token: UUID, answer: Result<AIAnswer, Error>, started: Date) {
        // Cancelled (Discard, delete, Cancel, quitting, key removed) or replaced by a newer request.
        guard let request = aiRequests[key], request.token == token else { return }
        aiRequests[key] = nil
        let id = key.callID
        switch answer {
        case .success(let answer):
            aiJobs[key] = nil
            store(answer, for: id, started: started)
        case .failure(let error):
            if error is CancellationError {
                aiJobs[key] = nil
                return
            }
            let failure = Self.aiError(error)
            aiJobs[key] = .failed(failure)
            KanLog.warning("OpenAI \(key.kind.logName) for \(id) failed after \(Self.seconds(since: started)) s: "
                           + failure.logDescription, category: "ai")
            if request.automatic { noteAccountProblem(failure, kind: key.kind, callID: id) }
        }
    }

    /// Writes an answer onto the call as it is stored now: only `ai`, and the title when it still
    /// follows the ideas. A call deleted meanwhile gets nothing (and nothing is reported).
    private func store(_ answer: AIAnswer, for id: CallID, started: Date) {
        var retitled = false
        do {
            try library.update(id) { record in
                var insights = record.ai ?? CallInsights()
                switch answer {
                case .titles(let ideas):
                    insights.titleSuggestions = ideas
                    if let first = ideas.titles.first, Self.titleFollowsIdeas(record) {
                        record.title = first
                        insights.appliedTitle = first
                        retitled = true
                    }
                case .summary(let summary):
                    insights.summary = summary
                }
                record.ai = insights
            }
        } catch LibraryError.notFound {
            KanLog.info("OpenAI answered for \(id) after the call was deleted; nothing saved", category: "ai")
            return
        } catch {
            report("Couldn't save what OpenAI wrote", error: error, category: "ai", log: "Couldn't save OpenAI's answer for \(id)")
            return
        }
        let seconds = Self.seconds(since: started)
        switch answer {
        case .titles(let ideas):
            KanLog.info("Saved \(ideas.titles.count) title idea(s) for \(id) after \(seconds) s"
                        + (retitled ? "; the first one is now its title" : ""), category: "ai")
        case .summary(let summary):
            let items = summary.keyPoints.count + summary.ideas.count + summary.decisions.count
                + summary.actionItems.count + summary.openQuestions.count
            KanLog.info("Saved the summary of \(id) after \(seconds) s (\(items) list item(s)"
                        + (summary.shortened ? ", from a shortened transcript)" : ")"), category: "ai")
        }
    }

    /// A setting's job failed the way every later one will (the key, the credit or a spend limit,
    /// the permissions, the model): a notice says so (one at a time), unless the open label panel
    /// already shows it.
    private func noteAccountProblem(_ error: AIError, kind: AIJobKind, callID: CallID) {
        switch error {
        case .missingKey, .invalidKey, .noCredit, .spendLimit, .notAllowed, .modelUnavailable: break
        default: return
        }
        if kind == .titles && presentedLabel == callID { return }
        postProblem(Self.openAIProblemTitle, message: error.message,
                    buttons: [.init(title: "Settings…", command: .openSettings, role: .primary)])
    }

    /// What `CallAssisting` threw, as an `AIError` (it throws nothing else but cancellation).
    nonisolated static func aiError(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        if let error = error as? URLError { return .network(code: error.errorCode) }
        return .network(code: (error as NSError).code)
    }

    private nonisolated static func seconds(since start: Date) -> String {
        String(format: "%.1f", max(0, Date().timeIntervalSince(start)))
    }
}
