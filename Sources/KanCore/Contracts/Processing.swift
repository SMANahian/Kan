import Foundation

// CONTRACT (implemented by the KanCore agent — keep these signatures; additions are fine).

public struct ProcessingStatus: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Codable {
        case queued, running, paused, failed, done, cancelled
    }

    public var id: CallID { callID }
    public var callID: CallID
    public var state: State
    public var progress: PipelineProgress?
    public var error: String?

    public init(callID: CallID, state: State, progress: PipelineProgress? = nil, error: String? = nil) {
        self.callID = callID
        self.state = state
        self.progress = progress
        self.error = error
    }
}

/// Serial, persistent transcription queue.
///
/// Behaviour:
///  - One job at a time, FIFO. Jobs (TranscriptionRequest) are persisted to `stateFile` so they
///    survive quits/crashes; `resumePersistedJobs()` re-enqueues them at launch.
///  - Running a job: mark the record `.processing` (via LibraryStore.update), call the transcriber,
///    then apply the output in ONE `LibraryStore.update` that re-reads the latest record (the user may
///    have edited title/folder/tags/notes meanwhile — never overwrite those): set segments, speakers
///    (keep the names the user gave, matched to the new speakers by when they talked — speaker ids
///    are renumbered on every run), languages, status `.ready`, processing info. Write speaker
///    embeddings to `<callDataDirectory>/embeddings.json` only while settings.rememberVoices is on
///    (they are voice templates of other people); otherwise remove that file.
///  - The audio is located when the job runs, not when it was queued: archiving turns me.wav into
///    me.m4a, so a job restored after a quit (or queued during the archive) uses what exists then.
///    A track the request names that is gone entirely fails the job instead of replacing the
///    transcript with one side of the call.
///  - Voiceprints: when a `VoiceprintStore` is given and settings.rememberVoices is on, match each
///    remote speaker's embedding; confident matches set name + nameSource `.voiceprint` + personID,
///    weaker ones set `suggestedName`.
///  - After success: if settings.keepAudio or the call is starred, `archiver.archive(directory:)` and
///    store the AudioAssets on the record; otherwise `archiver.deleteAudio(in:)`.
///  - Failure: status `.failed`, ProcessingInfo.error set, audio kept for retry. Cancellation: status
///    back to `.queued` if paused, `.failed("Cancelled")` if cancelled by the user.
///  - A model that isn't installed (`TranscriptionError.modelMissing`) fails the call too, but the
///    job is kept: `retryWaitingForModels()` (call it when models are installed) and the next launch
///    transcribe it again.
///  - Kan quitting after the transcript was saved but while the audio was archived: at the next
///    launch only the audio step runs (the transcript isn't redone).
///  - `pause()` cancels the running job (it restarts from the beginning on `resume()`; chunk-level
///    resume is not required) and stops picking new jobs. Used while a call is being recorded.
///  - `retranscribe` keeps the existing transcript until the new one succeeds.
///  - Callbacks (`onUpdate`) fire on the main queue.
///
/// Details:
///  - The record stays `.processing` while audio is archived, then becomes `.ready` (status `.done`).
///  - `cancel` of a job that is running records `.failed("Cancelled by user")`; a job that hasn't
///    started is dropped and the call goes back to `.ready` if it has a transcript (else `.failed`).
///  - Enqueueing a call that is already queued replaces its request; enqueueing one that is running
///    cancels that run and starts the new request next.
///  - Save the call in the library before enqueueing it; jobs for calls that are no longer in the
///    library fail with an explanation. Call `library.reload()` before `resumePersistedJobs()`.
///
/// Thread-safety: all methods may be called from any thread (one internal lock; jobs run one at a
/// time on a detached task; library writes go through `LibraryStore.update`).
public final class ProcessingQueue: @unchecked Sendable {
    /// Fires on the main queue for every status change (progress is throttled).
    public var onUpdate: (@MainActor (ProcessingStatus) -> Void)? {
        get { locked { updateHandler } }
        set { locked { updateHandler = newValue } }
    }

    private let library: LibraryStore
    private let transcriber: Transcribing
    private let archiver: AudioArchiving?
    private let voiceprints: VoiceprintStore?
    private let settings: @Sendable () -> KanSettings
    private let stateFile: URL
    private let callDataDirectory: @Sendable (CallID) -> URL

    // Guarded by `lock`.
    private let lock = NSLock()
    private var updateHandler: (@MainActor (ProcessingStatus) -> Void)?
    private var pending: [ProcessingJob] = []
    private var running: RunningJob?
    /// Jobs that failed because a model wasn't installed (see `retryWaitingForModels()`).
    private var waitingForModels: [ProcessingJob] = []
    private var paused = false
    private var statusByID: [CallID: ProcessingStatus] = [:]
    private var statusOrder: [CallID] = []
    private var finishedAt: [CallID: Date] = [:]

    /// Failed / cancelled statuses stay visible in `statuses()` this long.
    static let finishedStatusLifetime: TimeInterval = 30 * 60
    static let maxFinishedStatuses = 50
    static let cancelledMessage = "Cancelled by user"

    /// The job being executed. Mutable fields are guarded by the queue's lock.
    private final class RunningJob: @unchecked Sendable {
        let job: ProcessingJob
        var task: Task<Void, Never>?
        var cancelReason: CancelReason?
        var lastNotified: (date: Date, fraction: Double, stage: PipelineStage)?

        init(job: ProcessingJob) { self.job = job }

        var callID: CallID { job.request.callID }
    }

    private enum CancelReason {
        case pause, user, superseded
    }

    private enum Outcome {
        case succeeded
        case failed(String)
        /// A model isn't installed: failed for now, retried once models are installed.
        case waitingForModels(String)
        case cancelled(CancelReason)
        /// The call isn't in the library (anymore): nothing to update.
        case missing(String)
    }

    static let waitingForModelsNote = "Kan transcribes this call automatically once the model is installed."

    /// - Parameter callDataDirectory: where each call's audio and embeddings live; injectable for tests.
    public init(library: LibraryStore, transcriber: Transcribing, archiver: AudioArchiving?,
                voiceprints: VoiceprintStore?, settings: @escaping @Sendable () -> KanSettings,
                stateFile: URL = KanPaths.processingQueueFile,
                callDataDirectory: @escaping @Sendable (CallID) -> URL = { KanPaths.callDataDirectory(for: $0) }) {
        self.library = library
        self.transcriber = transcriber
        self.archiver = archiver
        self.voiceprints = voiceprints
        self.settings = settings
        self.stateFile = stateFile
        self.callDataDirectory = callDataDirectory
    }

    // MARK: - Public API

    public func enqueue(_ request: TranscriptionRequest) {
        enqueue(ProcessingJob(request: request, kind: .transcribe, enqueuedAt: Date()), restoring: false)
    }

    /// Re-run transcription for an existing call from its kept audio (WAV or m4a — the transcriber
    /// accepts both), optionally with a different language mode / models.
    ///
    /// `languageMode` nil keeps the call's current mode; models, vocabulary, diarization and the
    /// user's name come from `settings`. Throws `LibraryError.notFound` or
    /// `ProcessingError.audioNotAvailable`.
    public func retranscribe(_ id: CallID, languageMode: LanguageMode?, settings: KanSettings) throws {
        let record = try library.record(id)
        let directory = callDataDirectory(id)
        func existing(_ names: String...) -> URL? {
            names.lazy.map { directory.appendingPathComponent($0) }.first(where: FileOps.exists)
        }
        let me = existing(KanPaths.CallFile.meWAV, KanPaths.CallFile.meM4A)
        let them = existing(KanPaths.CallFile.themWAV, KanPaths.CallFile.themM4A)
        guard me != nil || them != nil else { throw ProcessingError.audioNotAvailable(id) }
        let session = FileManager.default.contents(atPath: directory.appendingPathComponent(KanPaths.CallFile.session).path)
            .flatMap { try? JSONDecoder.kan.decode(RecordingResult.self, from: $0) }
        let request = TranscriptionRequest(
            callID: id, meFile: me, themFile: them, anchorsFile: existing(KanPaths.CallFile.anchors),
            languageMode: languageMode ?? record.languageMode, userName: settings.effectiveUserName,
            vocabulary: settings.vocabulary, diarize: settings.diarize, maxRemoteSpeakers: settings.maxRemoteSpeakers,
            echoSuppression: settings.echoSuppression, loudspeakerSuspected: session?.loudspeakerSuspected ?? false,
            generalModelID: settings.generalModelID, englishModelID: settings.englishModelID,
            banglaModelID: settings.banglaModelID)
        KanLog.info("Re-transcription of \(id) requested (\(request.languageMode.rawValue))", category: "queue")
        enqueue(ProcessingJob(request: request, kind: .retranscribe, enqueuedAt: Date()), restoring: false)
    }

    public func cancel(_ id: CallID) {
        lock.lock()
        if waitingForModels.contains(where: { $0.request.callID == id }) {
            // The call already shows why it failed; it just won't be retried.
            waitingForModels.removeAll { $0.request.callID == id }
            persistLocked()
        }
        if let index = pending.firstIndex(where: { $0.request.callID == id }) {
            pending.remove(at: index)
            let status = setStatusLocked(id, .cancelled, error: Self.cancelledMessage)
            persistLocked()
            lock.unlock()
            // Never started (or waiting to restart): back to the previous transcript if there is one.
            updateRecord(id) { r in
                if r.segments.isEmpty {
                    Self.markFailed(&r, Self.cancelledMessage)
                } else {
                    r.status = .ready
                }
            }
            KanLog.info("Cancelled queued transcription of \(id)", category: "queue")
            notify(status)
            return
        }
        if let job = running, job.callID == id, job.cancelReason != .user {
            job.cancelReason = .user
            let task = job.task
            let status = setStatusLocked(id, .cancelled, error: Self.cancelledMessage)
            persistLocked()
            lock.unlock()
            KanLog.info("Cancelling transcription of \(id)", category: "queue")
            task?.cancel()
            notify(status)
            return
        }
        lock.unlock()
    }

    public func pause() {
        lock.lock()
        guard !paused else {
            lock.unlock()
            return
        }
        paused = true
        var task: Task<Void, Never>?
        var status: ProcessingStatus?
        if let job = running, job.cancelReason == nil {
            job.cancelReason = .pause
            task = job.task
            status = setStatusLocked(job.callID, .paused)
        }
        lock.unlock()
        KanLog.info("Transcription paused" + (task == nil ? "" : " (the running job restarts on resume)"), category: "queue")
        task?.cancel()
        if let status { notify(status) }
    }

    public func resume() {
        lock.lock()
        guard paused else {
            lock.unlock()
            return
        }
        paused = false
        var changed: [ProcessingStatus] = []
        for job in pending where statusByID[job.request.callID]?.state == .paused {
            changed.append(setStatusLocked(job.request.callID, .queued))
        }
        lock.unlock()
        KanLog.info("Transcription resumed", category: "queue")
        changed.forEach(notify)
        scheduleNext()
    }

    public var isPaused: Bool { locked { paused } }

    /// Re-enqueues the jobs persisted by a previous run (calls already queued here are skipped),
    /// including those that were waiting for a model: it may have been installed since.
    public func resumePersistedJobs() {
        let contents = ProcessingQueueFile.load(stateFile)
        let jobs = contents.jobs + (contents.waitingForModels ?? [])
        guard !jobs.isEmpty else { return }
        KanLog.info("Restoring \(jobs.count) transcription job(s)", category: "queue")
        for job in jobs { enqueue(job, restoring: true) }
    }

    /// Queues again the calls whose transcription failed because a model wasn't installed. Call it
    /// when a model download finishes or the installed models change (it does nothing when no
    /// call is waiting); a call still missing its model fails again and keeps waiting.
    public func retryWaitingForModels() {
        let jobs: [ProcessingJob] = locked {
            let jobs = waitingForModels
            waitingForModels.removeAll()
            if !jobs.isEmpty { persistLocked() }
            return jobs
        }
        guard !jobs.isEmpty else { return }
        KanLog.info("Retrying \(jobs.count) transcription(s) that were waiting for a model", category: "queue")
        for job in jobs { enqueue(job, restoring: true) }
    }

    /// Calls whose transcription waits for a model to be installed, oldest first.
    public var callsWaitingForModels: [CallID] {
        locked { waitingForModels.map(\.request.callID) }
    }

    /// Current statuses (queued, running, recently failed), oldest first.
    /// Recently cancelled jobs are listed too; finished ones are not.
    public func statuses() -> [ProcessingStatus] {
        locked {
            pruneLocked()
            return statusOrder.compactMap { statusByID[$0] }.filter { $0.state != .done }
        }
    }

    /// The latest status of one call (including `.done`), if the queue has seen it recently.
    public func status(for id: CallID) -> ProcessingStatus? {
        locked { statusByID[id] }
    }

    /// The call being transcribed right now.
    public var runningCallID: CallID? {
        locked { running?.callID }
    }

    // MARK: - Scheduling

    private func enqueue(_ job: ProcessingJob, restoring: Bool) {
        var job = job
        let id = job.request.callID
        lock.lock()
        let alreadyQueued = pending.contains { $0.request.callID == id }
        let isRunning = running?.callID == id
        lock.unlock()
        if restoring && (alreadyQueued || isRunning) { return }

        let current = try? library.record(id)
        if restoring, let current, let info = current.processing, info.error == nil,
           let finished = info.finishedAt, finished > job.enqueuedAt {
            if current.status == .ready {
                // Finished after it was queued (the app quit before the queue file caught up).
                KanLog.info("Not restoring \(id): it was already transcribed", category: "queue")
                return
            }
            if current.status == .processing {
                // The transcript was saved, but Kan quit while the audio was being archived: redoing
                // the transcript would waste the work (and the archived WAVs are gone).
                job.kind = .finishAudio
            }
        }
        // Before the job is visible to the worker, so this can't overwrite `.processing`.
        if let current, current.status != .queued, job.kind != .finishAudio {
            updateRecord(id) { $0.status = .queued }
        }

        lock.lock()
        var superseded: Task<Void, Never>?
        waitingForModels.removeAll { $0.request.callID == id }
        if let index = pending.firstIndex(where: { $0.request.callID == id }) {
            pending[index] = ProcessingJob(request: job.request, kind: job.kind, enqueuedAt: pending[index].enqueuedAt)
        } else if let current = running, current.callID == id {
            if current.cancelReason == nil || current.cancelReason == .pause {
                current.cancelReason = .superseded
                superseded = current.task
            }
            pending.insert(job, at: 0)
        } else {
            pending.append(job)
        }
        let status = setStatusLocked(id, .queued)
        persistLocked()
        lock.unlock()
        superseded?.cancel()
        notify(status)
        scheduleNext()
    }

    private func scheduleNext() {
        lock.lock()
        guard !paused, running == nil, !pending.isEmpty else {
            lock.unlock()
            return
        }
        let job = RunningJob(job: pending.removeFirst())
        running = job
        let status = setStatusLocked(job.callID, .running)
        persistLocked()
        job.task = Task.detached(priority: .utility) { [weak self] in
            await self?.execute(job)
        }
        lock.unlock()
        notify(status)
    }

    // MARK: - Running a job

    private func execute(_ job: RunningJob) async {
        let id = job.callID
        let startedAt = Date()
        guard id.isWellFormed, library.contains(id) else {
            KanLog.warning("Dropping transcription of \(id): the call is no longer in the library", category: "queue")
            finish(job, .missing("This call is no longer in the library."))
            return
        }
        if job.job.kind == .finishAudio {
            await finishRestoredAudio(job)
            return
        }
        let request: TranscriptionRequest
        do {
            request = try locatingAudio(job.job.request)
        } catch {
            KanLog.error("Not transcribing \(id): \(Self.message(error))", category: "queue")
            finish(job, .failed(Self.message(error)))
            return
        }
        var attempts = 1
        do {
            try library.update(id) { r in
                attempts = (r.processing?.attempts ?? 0) + 1
                var info = r.processing ?? ProcessingInfo(languageMode: request.languageMode)
                info.startedAt = startedAt
                info.finishedAt = nil
                info.error = nil
                info.attempts = attempts
                r.processing = info
                r.status = .processing
            }
        } catch {
            KanLog.error("Couldn't start transcribing \(id): \(KanLog.describe(error))", category: "queue")
            finish(job, Self.isNotFound(error) ? .missing(Self.message(error)) : .failed(Self.message(error)))
            return
        }

        KanLog.info("Transcribing \(id) (\(job.job.kind.rawValue), attempt \(attempts), \(request.languageMode.rawValue))",
                    category: "queue")
        do {
            try Task.checkCancellation()
            let output = try await transcriber.transcribe(request) { [weak self] progress in
                self?.reportProgress(job, progress)
            }
            // A transcript that arrives after a user cancel (or a newer request) is discarded;
            // one that arrives after a pause is kept — the work is done.
            if let reason = cancelReason(job), reason != .pause { throw CancellationError() }
            try await complete(job, output: output, attempts: attempts, startedAt: startedAt)
            KanLog.info("Transcribed \(id): \(output.segments.count) segments, \(output.speakers.count) speakers, "
                        + "\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s", category: "queue")
            finish(job, .succeeded)
        } catch {
            if let reason = cancelReason(job) {
                finish(job, .cancelled(reason))
            } else if Self.isCancellation(error) {
                finish(job, .cancelled(.pause))       // cancelled from outside: run it again later
            } else if case TranscriptionError.modelMissing? = error as? TranscriptionError {
                KanLog.warning("Transcription of \(id) waits for a model: \(Self.message(error))", category: "queue")
                finish(job, .waitingForModels(Self.message(error) + ". " + Self.waitingForModelsNote))
            } else {
                KanLog.error("Transcription of \(id) failed: \(KanLog.describe(error))", category: "queue")
                finish(job, Self.isNotFound(error) ? .missing(Self.message(error)) : .failed(Self.message(error)))
            }
        }
    }

    /// Applies the output, writes embeddings, archives or deletes audio, then marks the call ready.
    private func complete(_ job: RunningJob, output: TranscriptionOutput, attempts: Int, startedAt: Date) async throws {
        let request = job.job.request
        let id = request.callID
        let current = settings()
        var matches: [String: VoiceprintMatch] = [:]
        if current.rememberVoices, let voiceprints {
            matches = TranscriptMerge.voiceprintMatches(output: output, store: voiceprints)
        }
        let finishedAt = Date()
        try library.update(id) { r in
            TranscriptMerge.apply(output, to: &r, request: request, matches: matches, attempts: attempts,
                                  startedAt: startedAt, finishedAt: finishedAt)
        }
        storeSpeakerEmbeddings(output.speakerEmbeddings, for: id, remember: current.rememberVoices)
        try await finishAudio(of: id, keepAudio: current.keepAudio)
    }

    /// Speaker embeddings are voice templates of the other people on the call: they are kept (to
    /// remember a voice when the user names a speaker) only while the user has opted into
    /// remembering voices. A previous run's file is always replaced or removed — its speaker ids
    /// belong to the old transcript.
    private func storeSpeakerEmbeddings(_ embeddings: [String: [Float]], for id: CallID, remember: Bool) {
        let directory = callDataDirectory(id)
        do {
            if remember && !embeddings.isEmpty {
                try SpeakerEmbeddingsFile.write(embeddings, in: directory)
            } else {
                try SpeakerEmbeddingsFile.delete(in: directory)
            }
        } catch {
            KanLog.warning("Couldn't update the speaker embeddings of \(id): \(Self.message(error))", category: "queue")
        }
    }

    /// Archives (or deletes) the call's audio, then marks the call ready. Starred calls always keep
    /// their audio, and so does a call whose record can't be read right now (never delete audio
    /// when unsure).
    private func finishAudio(of id: CallID, keepAudio: Bool) async throws {
        let starred = (try? library.record(id))?.starred ?? true
        let (assets, warning) = await handleAudio(in: callDataDirectory(id), keep: keepAudio || starred)
        try library.update(id) { r in
            if let assets { r.audio = assets }
            if let warning { r.processing?.warnings.append(warning) }
            r.status = .ready
        }
    }

    /// A restored job whose transcript was already saved: only the audio step is left.
    private func finishRestoredAudio(_ job: RunningJob) async {
        let id = job.callID
        KanLog.info("Finishing \(id): its transcript was saved before Kan quit; archiving the audio", category: "queue")
        do {
            try await finishAudio(of: id, keepAudio: settings().keepAudio)
            finish(job, .succeeded)
        } catch {
            KanLog.error("Couldn't finish \(id): \(KanLog.describe(error))", category: "queue")
            finish(job, Self.isNotFound(error) ? .missing(Self.message(error)) : .failed(Self.message(error)))
        }
    }

    /// The request with every recorded track pointing at audio that exists now: the file it names,
    /// else that track's WAV or m4a in the call data directory (archiving replaces me.wav with
    /// me.m4a while a restored or superseding job waits). A track that is gone entirely throws:
    /// transcribing the other side alone would replace a full transcript with half of it.
    private func locatingAudio(_ request: TranscriptionRequest) throws -> TranscriptionRequest {
        let directory = callDataDirectory(request.callID)
        var missing: [String] = []
        func locate(_ requested: URL?, _ names: [String]) -> URL? {
            guard let requested else { return nil }                    // not recorded
            if FileOps.exists(requested) { return requested }
            if let found = names.lazy.map({ directory.appendingPathComponent($0) }).first(where: FileOps.exists) {
                KanLog.info("\(request.callID): using \(found.lastPathComponent) instead of \(requested.lastPathComponent)",
                            category: "queue")
                return found
            }
            missing.append(requested.lastPathComponent)
            return nil
        }
        var located = request
        located.meFile = locate(request.meFile, [KanPaths.CallFile.meWAV, KanPaths.CallFile.meM4A])
        located.themFile = locate(request.themFile, [KanPaths.CallFile.themWAV, KanPaths.CallFile.themM4A])
        guard missing.isEmpty else { throw MissingAudio(files: missing) }
        return located
    }

    private struct MissingAudio: LocalizedError {
        let files: [String]

        var errorDescription: String? {
            "The recorded audio (\(files.joined(separator: ", "))) is missing; Kan didn't transcribe the call without it."
        }
    }

    /// Archives (keepAudio) or deletes the call's audio. Runs detached so a pause arriving now
    /// can't interrupt it: the transcript is already saved.
    private func handleAudio(in directory: URL, keep: Bool) async -> (AudioAssets?, String?) {
        let meWAV = directory.appendingPathComponent(KanPaths.CallFile.meWAV)
        let themWAV = directory.appendingPathComponent(KanPaths.CallFile.themWAV)
        let hasWAV = FileOps.exists(meWAV) || FileOps.exists(themWAV)
        if keep {
            guard hasWAV, let archiver else { return (Self.audioAssets(in: directory), nil) }
            do {
                let assets = try await Task.detached(priority: .utility) {
                    try await archiver.archive(directory: directory)
                }.value
                return (assets, nil)
            } catch {
                KanLog.error("Couldn't compress the audio in \(directory.lastPathComponent): \(Self.message(error))",
                             category: "queue")
                return (Self.audioAssets(in: directory),
                        "The audio couldn't be compressed and was kept uncompressed (\(Self.message(error))).")
            }
        }
        let format = Self.audioAssets(in: directory)?.format ?? "wav"
        do {
            if let archiver {
                try archiver.deleteAudio(in: directory)
            } else {
                for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A] {
                    let url = directory.appendingPathComponent(name)
                    if FileOps.exists(url) { try FileManager.default.removeItem(at: url) }
                }
            }
        } catch {
            KanLog.error("Couldn't delete the audio in \(directory.lastPathComponent): \(Self.message(error))", category: "queue")
            return (Self.audioAssets(in: directory), "The audio couldn't be deleted (\(Self.message(error))).")
        }
        return (AudioAssets(meFile: nil, themFile: nil, format: format, sizeBytes: 0, deletedAt: Date()), nil)
    }

    /// Kept audio found in a call directory (m4a preferred over WAV), or nil.
    static func audioAssets(in directory: URL) -> AudioAssets? {
        func size(_ name: String?) -> Int64 {
            guard let name else { return 0 }
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        for (me, them, format) in [(KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A, "m4a"),
                                   (KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, "wav")] {
            let meFile = FileOps.exists(directory.appendingPathComponent(me)) ? me : nil
            let themFile = FileOps.exists(directory.appendingPathComponent(them)) ? them : nil
            if meFile != nil || themFile != nil {
                return AudioAssets(meFile: meFile, themFile: themFile, format: format,
                                   sizeBytes: size(meFile) + size(themFile))
            }
        }
        return nil
    }

    private func finish(_ job: RunningJob, _ outcome: Outcome) {
        let id = job.callID
        // Update the record first, while this job still owns the queue (nothing else can start).
        switch outcome {
        case .failed(let message), .waitingForModels(let message):
            updateRecord(id) { Self.markFailed(&$0, message) }
        case .cancelled(.user):
            updateRecord(id) { Self.markFailed(&$0, Self.cancelledMessage) }
        case .cancelled(.pause):
            updateRecord(id) { $0.status = .queued }
        case .succeeded, .cancelled(.superseded), .missing:
            break
        }

        lock.lock()
        if running === job { running = nil }
        let status: ProcessingStatus
        switch outcome {
        case .succeeded:
            status = setStatusLocked(id, .done)
        case .failed(let message), .missing(let message):
            status = setStatusLocked(id, .failed, error: message)
        case .waitingForModels(let message):
            // Unless the call was queued again meanwhile (a newer request supersedes this one).
            if !pending.contains(where: { $0.request.callID == id }) {
                waitingForModels.removeAll { $0.request.callID == id }
                waitingForModels.append(job.job)
            }
            status = setStatusLocked(id, .failed, error: message)
        case .cancelled(.user):
            status = setStatusLocked(id, .cancelled, error: Self.cancelledMessage)
        case .cancelled(.pause):
            if !pending.contains(where: { $0.request.callID == id }) { pending.insert(job.job, at: 0) }
            status = setStatusLocked(id, paused ? .paused : .queued)
        case .cancelled(.superseded):
            status = setStatusLocked(id, .queued)
        }
        persistLocked()
        pruneLocked()
        lock.unlock()
        notify(status)
        scheduleNext()
    }

    private func cancelReason(_ job: RunningJob) -> CancelReason? {
        locked { job.cancelReason }
    }

    private func reportProgress(_ job: RunningJob, _ progress: PipelineProgress) {
        lock.lock()
        guard running === job, job.cancelReason == nil else {
            lock.unlock()
            return
        }
        let status = setStatusLocked(job.callID, .running, progress: progress)
        let now = Date()
        var shouldNotify = true
        if let last = job.lastNotified, last.stage == progress.stage,
           abs(progress.fraction - last.fraction) < 0.01, now.timeIntervalSince(last.date) < 0.25 {
            shouldNotify = false
        }
        if shouldNotify { job.lastNotified = (now, progress.fraction, progress.stage) }
        lock.unlock()
        if shouldNotify { notify(status) }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func notify(_ status: ProcessingStatus) {
        guard let handler = locked({ updateHandler }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(status) }
        }
    }

    @discardableResult
    private func setStatusLocked(_ id: CallID, _ state: ProcessingStatus.State, progress: PipelineProgress? = nil,
                                 error: String? = nil) -> ProcessingStatus {
        let status = ProcessingStatus(callID: id, state: state, progress: progress, error: error)
        let wasFinished = finishedAt[id] != nil
        if statusByID[id] == nil || (wasFinished && state == .queued) {
            statusOrder.removeAll { $0 == id }
            statusOrder.append(id)
        }
        statusByID[id] = status
        switch state {
        case .done, .failed, .cancelled: finishedAt[id] = Date()
        case .queued, .running, .paused: finishedAt[id] = nil
        }
        return status
    }

    private func pruneLocked() {
        let now = Date()
        var finished = statusOrder.filter { finishedAt[$0] != nil }
        let expired = Set(finished.filter { now.timeIntervalSince(finishedAt[$0] ?? now) > Self.finishedStatusLifetime })
        finished.removeAll { expired.contains($0) }
        let overflow = Set(finished.dropLast(Self.maxFinishedStatuses))
        let drop = expired.union(overflow)
        guard !drop.isEmpty else { return }
        statusOrder.removeAll { drop.contains($0) }
        for id in drop {
            statusByID[id] = nil
            finishedAt[id] = nil
        }
    }

    private func persistLocked() {
        var jobs: [ProcessingJob] = []
        if let job = running, job.cancelReason == nil || job.cancelReason == .pause { jobs.append(job.job) }
        jobs.append(contentsOf: pending)
        do {
            try ProcessingQueueFile.save(jobs, waitingForModels: waitingForModels, to: stateFile)
        } catch {
            KanLog.error("Couldn't save the transcription queue: \(Self.message(error))", category: "queue")
        }
    }

    private func updateRecord(_ id: CallID, _ mutate: (inout CallRecord) -> Void) {
        do {
            try library.update(id) { mutate(&$0) }
        } catch {
            KanLog.warning("Couldn't update the status of \(id): \(KanLog.describe(error))", category: "queue")
        }
    }

    private static func markFailed(_ record: inout CallRecord, _ message: String) {
        record.status = .failed
        var info = record.processing ?? ProcessingInfo(languageMode: record.languageMode)
        info.error = message
        info.finishedAt = Date()
        record.processing = info
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TranscriptionError.cancelled? = error as? TranscriptionError { return true }
        return false
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case LibraryError.notFound? = error as? LibraryError { return true }
        return false
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
