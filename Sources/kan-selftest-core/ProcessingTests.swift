import Foundation
import KanCore
import KanTestKit

/// A transcriber that returns a canned output (or error), optionally holding at a gate until
/// released. Honours Task cancellation like the real pipeline.
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var requestLog: [TranscriptionRequest] = []
    private var held = false
    private var inside = 0
    private var cancelled = 0
    private var output: TranscriptionOutput
    private var failure: Error?

    init(output: TranscriptionOutput) { self.output = output }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [TranscriptionRequest] { locked { requestLog } }
    var isInside: Bool { locked { inside > 0 } }
    var cancellations: Int { locked { cancelled } }
    func hold() { locked { held = true } }
    func release() { locked { held = false } }
    func set(output: TranscriptionOutput) { locked { self.output = output } }
    func set(error: Error?) { locked { failure = error } }

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> TranscriptionOutput {
        locked {
            requestLog.append(request)
            inside += 1
        }
        defer { locked { inside -= 1 } }
        progress(PipelineProgress(stage: .preparing, fraction: 0.05))
        do {
            while locked({ held }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try Task.checkCancellation()
        } catch {
            locked { cancelled += 1 }
            throw TranscriptionError.cancelled
        }
        progress(PipelineProgress(stage: .transcribingBangla, fraction: 0.6, message: "chunk 3/5"))
        progress(PipelineProgress(stage: .finishing, fraction: 1))
        if let failure = locked({ failure }) { throw failure }
        return locked { output }
    }
}

/// Archives like the real one (me.wav → me.m4a …) and records what it was asked to do.
final class FakeArchiver: AudioArchiving, @unchecked Sendable {
    private let lock = NSLock()
    private var archivedDirectories: [URL] = []
    private var deletedDirectories: [URL] = []

    var archived: [URL] { lock.withLock { archivedDirectories } }
    var deleted: [URL] { lock.withLock { deletedDirectories } }

    func archive(directory: URL) async throws -> AudioAssets {
        lock.withLock { archivedDirectories.append(directory) }
        var me: String?, them: String?
        for (wav, m4a) in [(KanPaths.CallFile.meWAV, KanPaths.CallFile.meM4A), (KanPaths.CallFile.themWAV, KanPaths.CallFile.themM4A)] {
            let source = directory.appendingPathComponent(wav)
            let target = directory.appendingPathComponent(m4a)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: target)
            } else if !FileManager.default.fileExists(atPath: target.path) {
                continue
            }
            if wav == KanPaths.CallFile.meWAV { me = m4a } else { them = m4a }
        }
        return AudioAssets(meFile: me, themFile: them, format: "m4a", sizeBytes: 42)
    }

    func deleteAudio(in directory: URL) throws {
        lock.withLock { deletedDirectories.append(directory) }
        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// A library, fakes, settings and a queue file in one temporary directory.
final class QueueEnv {
    let lib: TestLibrary
    let transcriber: FakeTranscriber
    let archiver = FakeArchiver()
    let voiceprints: VoiceprintStore
    let settings = Locked(KanSettings())
    let stateFile: URL

    static let output = TranscriptionOutput(
        segments: [Fixture.segment(0, 0.5, 2, "me", "Hello from me"),
                   Fixture.segment(1, 2.5, 4, "s1", "আমরা বাংলা ভাষার জন্য", language: "bn")],
        speakers: [Speaker(id: "me", name: "Me", isMe: true, talkTime: 1.5),
                   Speaker(id: "s1", name: "Speaker 1", isMe: false, talkTime: 1.5)],
        languages: ["en", "bn"], speakerEmbeddings: ["s1": Fixture.vector(0)],
        modelsUsed: ["large-v3-turbo", "bengali-medium-q8_0"], warnings: ["w1"], stats: ["seconds.total": 12.5])

    init(_ name: String, output: TranscriptionOutput = QueueEnv.output) {
        lib = TestLibrary(name)
        transcriber = FakeTranscriber(output: output)
        voiceprints = VoiceprintStore(fileURL: lib.base.appendingPathComponent("voiceprints.json"))
        stateFile = lib.base.appendingPathComponent("queue.json")
    }

    func makeQueue() -> ProcessingQueue {
        let settings = self.settings
        let calls = lib.calls
        return ProcessingQueue(library: lib.store, transcriber: transcriber, archiver: archiver, voiceprints: voiceprints,
                               settings: { settings.current }, stateFile: stateFile,
                               callDataDirectory: { calls.appendingPathComponent($0.rawValue, isDirectory: true) })
    }

    /// Saves a call and creates its recorded audio files.
    func addCall(title: String = "Call", status: CallStatus = .queued, speakers: [Speaker] = [],
                 segments: [TranscriptSegment] = [], audio: [String] = [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV]) throws -> CallRecord {
        let record = Fixture.record(title: title, status: status, speakers: speakers, segments: segments)
        try lib.store.save(record)
        let directory = lib.callDirectory(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in audio { try Data(repeating: 1, count: 64).write(to: directory.appendingPathComponent(name)) }
        return record
    }

    func request(_ id: CallID, language: LanguageMode = .auto, userName: String = "Nahian") -> TranscriptionRequest {
        let directory = lib.callDirectory(id)
        return TranscriptionRequest(callID: id, meFile: directory.appendingPathComponent(KanPaths.CallFile.meWAV),
                                    themFile: directory.appendingPathComponent(KanPaths.CallFile.themWAV),
                                    languageMode: language, userName: userName)
    }

    func record(_ id: CallID) throws -> CallRecord { try lib.store.record(id) }
    func status(_ id: CallID) -> CallStatus? { try? lib.store.record(id).status }
    func exists(_ id: CallID, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: lib.callDirectory(id).appendingPathComponent(name).path)
    }

    /// Waits until the queue has retired these calls' jobs (the record turns `.ready` just before).
    func settled(_ queue: ProcessingQueue, _ ids: CallID...) async throws {
        try await eventually("queue settled") {
            queue.runningCallID == nil && ids.allSatisfy { id in
                [.done, .failed, .cancelled].contains(queue.status(for: id)?.state ?? .queued)
            }
        }
    }

    /// Jobs in queue.json.
    var persistedJobs: Int {
        guard let data = FileManager.default.contents(atPath: stateFile.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = object["jobs"] as? [Any] else { return -1 }
        return jobs.count
    }

    /// Jobs in queue.json that wait for a model to be installed.
    var persistedWaiting: Int {
        guard let data = FileManager.default.contents(atPath: stateFile.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return -1 }
        return (object["waitingForModels"] as? [Any])?.count ?? 0
    }

    /// queue.json as a previous run of the app left it.
    func writeQueueFile(_ requests: [TranscriptionRequest], enqueuedAt: Date) throws {
        struct Job: Encodable {
            let request: TranscriptionRequest
            let kind: String
            let enqueuedAt: Date
        }
        struct Contents: Encodable {
            let version: Int
            let jobs: [Job]
        }
        let jobs = requests.map { Job(request: $0, kind: "transcribe", enqueuedAt: enqueuedAt) }
        try JSONEncoder.kanPretty.encode(Contents(version: 1, jobs: jobs)).write(to: stateFile)
    }
}

func processingTests() -> TestSuite {
    let suite = TestSuite("Processing")

    suite.test("a job transcribes, keeps the user's labels and archives the audio") {
        let env = QueueEnv("q-success")
        let call = try env.addCall(title: "My label")
        try env.lib.store.update(call.id) { r in
            r.folder = "Research"
            r.tags = ["x"]
            r.notes = "n"
            r.starred = true
        }
        let queue = env.makeQueue()
        let updates = Locked<[ProcessingStatus]>([])
        let onMain = Locked(true)
        queue.onUpdate = { status in
            if !Thread.isMainThread { onMain.mutate { $0 = false } }
            updates.mutate { $0.append(status) }
        }
        queue.enqueue(env.request(call.id))
        try await eventually("ready") { env.status(call.id) == .ready }

        let r = try env.record(call.id)
        try expectEqual(r.title, "My label")
        try expectEqual(r.folder, "Research")
        try expectEqual(r.tags, ["x"])
        try expectEqual(r.notes, "n")
        try expectEqual(r.starred, true)
        try expectEqual(r.segments.map(\.text), ["Hello from me", "আমরা বাংলা ভাষার জন্য"])
        try expectEqual(r.speakers.map(\.name), ["Nahian", "Speaker 1"])
        try expectEqual(r.languages, ["en", "bn"])
        let info = try expectNotNil(r.processing)
        try expectEqual(info.modelsUsed, ["large-v3-turbo", "bengali-medium-q8_0"])
        try expectEqual(info.warnings, ["w1"])
        try expectEqual(info.attempts, 1)
        try expectEqual(info.stats?["seconds.total"], 12.5)
        try expectEqual(info.error, nil)
        try expect(info.startedAt != nil && info.finishedAt != nil && info.processingSeconds != nil)
        try expectEqual(r.audio, AudioAssets(meFile: "me.m4a", themFile: "them.m4a", format: "m4a", sizeBytes: 42))
        try expectEqual(env.archiver.archived.map(\.lastPathComponent), [call.id.rawValue])
        try expectEqual(env.archiver.deleted.count, 0)
        // "Remember voices" is off by default: no voice templates of the other people are kept.
        try expect(!env.exists(call.id, KanPaths.CallFile.embeddings), "embeddings.json written without opt-in")
        let markdown = try String(contentsOf: try expectNotNil(env.lib.store.files(for: call.id)).markdown, encoding: .utf8)
        try expect(markdown.contains("আমরা বাংলা ভাষার জন্য"))

        try await eventually("done update") { updates.current.contains { $0.state == .done } }
        try expect(updates.current.contains { $0.state == .running && $0.progress?.stage == .preparing })
        try expect(onMain.current, "onUpdate must run on the main thread")
        try expectEqual(queue.statuses().count, 0)                        // finished jobs aren't listed
        try expectEqual(queue.status(for: call.id)?.state, .done)
        try expectEqual(env.persistedJobs, 0)
        try expectEqual(queue.runningCallID, nil)
    }

    suite.test("a failure marks the call failed and keeps the audio") {
        let env = QueueEnv("q-failure")
        env.transcriber.set(error: TranscriptionError.engineFailed("Metal device lost"))
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await eventually("failed") { env.status(call.id) == .failed }
        let r = try env.record(call.id)
        try expectEqual(r.processing?.error, "Transcription failed: Metal device lost")
        try expectEqual(r.segments.count, 0)
        try expectEqual(env.archiver.archived.count + env.archiver.deleted.count, 0)
        try expect(env.exists(call.id, "me.wav") && env.exists(call.id, "them.wav"))
        try await eventually("status") { queue.statuses().first?.state == .failed }
        try expectEqual(queue.statuses().map(\.error), ["Transcription failed: Metal device lost"])
        try expectEqual(env.persistedJobs, 0)
        try expectEqual(queue.callsWaitingForModels, [])
    }

    suite.test("cancelling a running job records “Cancelled by user”") {
        let env = QueueEnv("q-cancel-running")
        env.transcriber.hold()
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await eventually("transcribing") { env.transcriber.isInside }
        try expectEqual(env.status(call.id), .processing)
        try expectEqual(queue.runningCallID, call.id)
        queue.cancel(call.id)
        try await eventually("failed") { env.status(call.id) == .failed }
        try expectEqual(try env.record(call.id).processing?.error, "Cancelled by user")
        try expectEqual(queue.statuses().map(\.state), [.cancelled])
        try expectEqual(env.transcriber.cancellations, 1)
        try expectEqual(env.archiver.archived.count, 0)
        try await eventually("queue idle") { queue.runningCallID == nil }
        try expectEqual(env.persistedJobs, 0)
    }

    suite.test("cancelling a job that never started restores the previous state") {
        let env = QueueEnv("q-cancel-queued")
        let queue = env.makeQueue()
        queue.pause()
        let transcribed = try env.addCall(title: "Has transcript", status: .ready, speakers: Fixture.speakers(),
                                          segments: [Fixture.segment(0, 0, 1, "s1", "old words")])
        let fresh = try env.addCall(title: "Nothing yet")
        queue.enqueue(env.request(transcribed.id))
        queue.enqueue(env.request(fresh.id))
        try expectEqual(env.status(transcribed.id), .queued)
        try expectEqual(queue.statuses().map(\.state), [.queued, .queued])
        try expectEqual(env.persistedJobs, 2)
        queue.cancel(transcribed.id)
        queue.cancel(fresh.id)
        try expectEqual(env.status(transcribed.id), .ready)
        try expectEqual(try env.record(transcribed.id).segments.map(\.text), ["old words"])
        try expectEqual(env.status(fresh.id), .failed)
        try expectEqual(try env.record(fresh.id).processing?.error, "Cancelled by user")
        try expectEqual(queue.statuses().map(\.state), [.cancelled, .cancelled])
        try expectEqual(env.persistedJobs, 0)
        queue.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        try expectEqual(env.transcriber.requests.count, 0)
    }

    suite.test("pause() interrupts the running job; resume() restarts it from the beginning") {
        let env = QueueEnv("q-pause")
        env.transcriber.hold()
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await eventually("transcribing") { env.transcriber.isInside }
        queue.pause()
        try expect(queue.isPaused)
        try await eventually("back in the queue") { env.status(call.id) == .queued && !env.transcriber.isInside }
        try expectEqual(queue.status(for: call.id)?.state, .paused)
        try expectEqual(env.persistedJobs, 1)
        env.transcriber.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(env.transcriber.requests.count, 1)                // nothing runs while paused
        try expectEqual(env.status(call.id), .queued)
        queue.resume()
        try expect(!queue.isPaused)
        try await eventually("ready") { env.status(call.id) == .ready }
        try expectEqual(env.transcriber.requests.count, 2)
        try expectEqual(try env.record(call.id).processing?.attempts, 2)
        try await env.settled(queue, call.id)
        try expectEqual(env.persistedJobs, 0)
    }

    suite.test("jobs run FIFO and survive a new queue instance") {
        let env = QueueEnv("q-persist")
        let first = env.makeQueue()
        first.pause()
        let a = try env.addCall(title: "A"), b = try env.addCall(title: "B"), c = try env.addCall(title: "C")
        for call in [a, b, c] { first.enqueue(env.request(call.id)) }
        try expectEqual(env.persistedJobs, 3)
        first.cancel(c.id)
        try expectEqual(env.persistedJobs, 2)

        let second = env.makeQueue()                                      // e.g. after a relaunch
        second.resumePersistedJobs()
        try await eventually("both ready") { env.status(a.id) == .ready && env.status(b.id) == .ready }
        try expectEqual(env.transcriber.requests.map(\.callID), [a.id, b.id])
        try await env.settled(second, a.id, b.id)
        try expectEqual(env.persistedJobs, 0)
        second.resumePersistedJobs()                                      // nothing left to restore
        try await Task.sleep(nanoseconds: 30_000_000)
        try expectEqual(env.transcriber.requests.count, 2)

        try Data("{ garbage".utf8).write(to: env.stateFile)               // a damaged queue file is set aside
        let third = env.makeQueue()
        third.resumePersistedJobs()
        try expect(!FileManager.default.fileExists(atPath: env.stateFile.path))
        try expectEqual(third.statuses().count, 0)
    }

    suite.test("edits the user makes during processing are preserved") {
        let previous = [Speaker(id: "me", name: "Nahian", isMe: true),
                        Speaker(id: "s1", name: "Speaker 1", isMe: false),
                        Speaker(id: "s2", name: "Speaker 2", isMe: false)]
        let output = TranscriptionOutput(
            segments: [Fixture.segment(0, 0, 1, "me", "new me"), Fixture.segment(1, 1, 2, "s1", "new one"),
                       Fixture.segment(2, 2, 3, "s2", "new two")],
            speakers: [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Speaker 1", isMe: false),
                       Speaker(id: "s2", name: "Speaker 2", isMe: false)],
            languages: ["en"])
        let env = QueueEnv("q-edits", output: output)
        env.transcriber.hold()
        let call = try env.addCall(title: "Before", status: .ready, speakers: previous,
                                   segments: [Fixture.segment(0, 0, 1, "me", "old me"), Fixture.segment(1, 1, 2, "s1", "old one"),
                                              Fixture.segment(2, 2, 3, "s2", "old two")])
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id, userName: "Nahian"))
        try await eventually("transcribing") { env.transcriber.isInside }
        try env.lib.store.update(call.id) { r in
            r.title = "Edited title"
            r.folder = "Projects"
            r.tags = ["new"]
            r.notes = "typed during processing"
            r.starred = true
            r.labeled = true
            r.bookmarks = [Bookmark(time: 1, note: "mark")]
            r.speakers[0].name = "Nahian R."
            r.speakers[0].nameSource = .user
            r.speakers[1].name = "Karim"
            r.speakers[1].nameSource = .user
        }
        env.transcriber.release()
        try await eventually("ready") { env.status(call.id) == .ready }
        let r = try env.record(call.id)
        try expectEqual(r.title, "Edited title")
        try expectEqual(r.folder, "Projects")
        try expectEqual(r.tags, ["new"])
        try expectEqual(r.notes, "typed during processing")
        try expectEqual(r.starred, true)
        try expectEqual(r.labeled, true)
        try expectEqual(r.bookmarks.map(\.note), ["mark"])
        try expectEqual(r.speakers.map(\.name), ["Nahian R.", "Karim", "Speaker 2"])
        try expectEqual(r.speakers.map(\.nameSource), [.user, .user, .automatic])
        try expectEqual(r.segments.map(\.text), ["new me", "new one", "new two"])
        try expectEqual(env.lib.store.files(for: call.id)?.json.deletingLastPathComponent().lastPathComponent, "Projects")
    }

    suite.test("remembered voices name confident speakers and suggest weaker matches") {
        let output = TranscriptionOutput(
            segments: [Fixture.segment(0, 0, 1, "s1", "one"), Fixture.segment(1, 1, 2, "s2", "two"),
                       Fixture.segment(2, 2, 3, "s3", "three")],
            speakers: [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Speaker 1", isMe: false),
                       Speaker(id: "s2", name: "Speaker 2", isMe: false), Speaker(id: "s3", name: "Speaker 3", isMe: false)],
            languages: ["en"],
            speakerEmbeddings: ["me": Fixture.vector(0), "s1": Fixture.vector(0, cosine: 0.95, toward: 50),
                                "s2": Fixture.vector(1, cosine: 0.75, toward: 60), "s3": Fixture.vector(0, cosine: 0.9, toward: 70)])
        let env = QueueEnv("q-voices", output: output)
        let rahim = try env.voiceprints.enroll(name: "Rahim", embedding: Fixture.vector(0))
        try env.voiceprints.enroll(name: "Karim", embedding: Fixture.vector(1))
        env.settings.mutate { $0.rememberVoices = true }
        let queue = env.makeQueue()
        let call = try env.addCall()
        queue.enqueue(env.request(call.id))
        try await eventually("ready") { env.status(call.id) == .ready }
        let speakers = try env.record(call.id).speakers
        try expectEqual(speakers.map(\.name), ["Nahian", "Rahim", "Speaker 2", "Speaker 3"])
        try expectEqual(speakers[1].nameSource, .voiceprint)
        try expectEqual(speakers[1].personID, rahim)
        try expectEqual(speakers[1].suggestedName, nil)
        try expectEqual(speakers[2].suggestedName, "Karim")
        try expectEqual(speakers[3].suggestedName, "Rahim")             // Rahim is already s1 in this call
        try expectEqual(speakers[0].suggestedName, nil)                 // the user's own track is never matched

        env.settings.mutate { $0.rememberVoices = false }
        let other = try env.addCall(title: "Opted out")
        queue.enqueue(env.request(other.id))
        try await eventually("ready") { env.status(other.id) == .ready }
        let plain = try env.record(other.id).speakers
        try expectEqual(plain.map(\.name), ["Nahian", "Speaker 1", "Speaker 2", "Speaker 3"])
        try expect(plain.allSatisfy { $0.suggestedName == nil && $0.personID == nil })
    }

    suite.test("keepAudio off deletes the audio after transcription") {
        let env = QueueEnv("q-delete-audio")
        env.settings.mutate { $0.keepAudio = false }
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await eventually("ready") { env.status(call.id) == .ready }
        try expectEqual(env.archiver.deleted.map(\.lastPathComponent), [call.id.rawValue])
        try expectEqual(env.archiver.archived.count, 0)
        let audio = try expectNotNil(try env.record(call.id).audio)
        try expect(audio.deletedAt != nil && !audio.isAvailable)
        try expect(!env.exists(call.id, "me.wav") && !env.exists(call.id, "them.wav"))
        try expect(!env.exists(call.id, KanPaths.CallFile.embeddings))
        try expectEqual(env.lib.store.summary(call.id)?.hasAudio, false)
    }

    suite.test("retranscribe uses the kept m4a audio and keeps the old transcript until it succeeds") {
        let env = QueueEnv("q-retranscribe")
        let call = try env.addCall(title: "Old", status: .ready, speakers: Fixture.speakers(),
                                   segments: [Fixture.segment(0, 0, 1, "s1", "old text")],
                                   audio: [KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A])
        let kept = AudioAssets(meFile: "me.m4a", themFile: "them.m4a", format: "m4a", sizeBytes: 128)
        try env.lib.store.update(call.id) { $0.audio = kept }
        env.transcriber.hold()
        let queue = env.makeQueue()
        var settings = KanSettings()
        settings.userName = "Nahian"
        settings.englishModelID = "large-v3-turbo"
        try queue.retranscribe(call.id, languageMode: .bangla, settings: settings)
        try await eventually("transcribing") { env.transcriber.isInside }
        let during = try env.record(call.id)
        try expectEqual(during.status, .processing)
        try expectEqual(during.segments.map(\.text), ["old text"])
        let markdown = try String(contentsOf: try expectNotNil(env.lib.store.files(for: call.id)).markdown, encoding: .utf8)
        try expect(markdown.contains("old text") && markdown.contains("A new transcript is being generated"), markdown)
        let request = try expectNotNil(env.transcriber.requests.last)
        try expectEqual(request.meFile?.lastPathComponent, "me.m4a")
        try expectEqual(request.themFile?.lastPathComponent, "them.m4a")
        try expectEqual(request.languageMode, .bangla)
        try expectEqual(request.userName, "Nahian")
        try expectEqual(request.englishModelID, "large-v3-turbo")
        env.transcriber.release()
        try await eventually("ready") { env.status(call.id) == .ready }
        let after = try env.record(call.id)
        try expectEqual(after.segments.map(\.text), ["Hello from me", "আমরা বাংলা ভাষার জন্য"])
        try expectEqual(after.languageMode, .bangla)
        try expectEqual(after.audio, kept)                                // already archived: untouched
        try expectEqual(env.archiver.archived.count, 0)
        try expect(env.exists(call.id, "me.m4a"))
    }

    suite.test("a failed re-transcription keeps the previous transcript") {
        let env = QueueEnv("q-retranscribe-fail")
        env.transcriber.set(error: TranscriptionError.engineFailed("boom"))
        let call = try env.addCall(title: "Old", status: .ready, speakers: Fixture.speakers(),
                                   segments: [Fixture.segment(0, 0, 1, "s1", "old text")])
        let queue = env.makeQueue()
        try queue.retranscribe(call.id, languageMode: nil, settings: KanSettings())
        try await eventually("failed") { env.status(call.id) == .failed }
        let r = try env.record(call.id)
        try expectEqual(r.segments.map(\.text), ["old text"])
        try expectEqual(r.processing?.error, "Transcription failed: boom")
        try expect(env.exists(call.id, "me.wav"))
        let markdown = try String(contentsOf: try expectNotNil(env.lib.store.files(for: call.id)).markdown, encoding: .utf8)
        try expect(markdown.contains("The last transcription attempt failed") && markdown.contains("old text"), markdown)
        try expectEqual(env.transcriber.requests.first?.languageMode, .auto)    // nil keeps the call's mode
    }

    suite.test("retranscribe needs kept audio and an existing call") {
        let env = QueueEnv("q-retranscribe-errors")
        let call = try env.addCall(audio: [])
        let queue = env.makeQueue()
        do {
            try queue.retranscribe(call.id, languageMode: nil, settings: KanSettings())
            throw fail("expected audioNotAvailable")
        } catch let error as ProcessingError {
            try expectEqual(error, .audioNotAvailable(call.id))
        }
        try expectThrows { try queue.retranscribe(CallID.generate(), languageMode: nil, settings: KanSettings()) }
        try expectEqual(env.transcriber.requests.count, 0)
    }

    suite.test("enqueueing a running call again supersedes the run") {
        let env = QueueEnv("q-supersede")
        env.transcriber.hold()
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id, language: .auto))
        try await eventually("transcribing") { env.transcriber.isInside }
        queue.enqueue(env.request(call.id, language: .english))
        try await eventually("restarted") { env.transcriber.requests.count == 2 }
        env.transcriber.release()
        try await eventually("ready") { env.status(call.id) == .ready }
        try expectEqual(env.transcriber.requests.map(\.languageMode), [.auto, .english])
        try expectEqual(env.transcriber.cancellations, 1)
        try expectEqual(try env.record(call.id).languageMode, .english)
        try await env.settled(queue, call.id)
        try expectEqual(env.persistedJobs, 0)
    }

    suite.test("a queued call that is enqueued again keeps one job with the new request") {
        let env = QueueEnv("q-replace")
        let queue = env.makeQueue()
        queue.pause()
        let call = try env.addCall()
        queue.enqueue(env.request(call.id, language: .auto))
        queue.enqueue(env.request(call.id, language: .bangla))
        try expectEqual(env.persistedJobs, 1)
        queue.resume()
        try await eventually("ready") { env.status(call.id) == .ready }
        try expectEqual(env.transcriber.requests.map(\.languageMode), [.bangla])
    }

    suite.test("a job for a call that left the library fails without calling the transcriber") {
        let env = QueueEnv("q-ghost")
        let queue = env.makeQueue()
        let ghost = CallID.generate()
        queue.enqueue(TranscriptionRequest(callID: ghost, meFile: nil, themFile: nil))
        try await eventually("failed status") { queue.status(for: ghost)?.state == .failed }
        try expect(queue.status(for: ghost)?.error?.contains("no longer in the library") ?? false)
        try expectEqual(env.transcriber.requests.count, 0)
        try expectEqual(env.persistedJobs, 0)
    }

    suite.test("a job restored after Kan quit while archiving only finishes the audio") {
        let env = QueueEnv("q-restore-archiving")
        let enqueuedAt = Date().addingTimeInterval(-600)
        let call = try env.addCall(title: "Long call", status: .processing, speakers: Fixture.speakers(others: ["Speaker 1"]),
                                   segments: [Fixture.segment(0, 0, 2, "me", "my words"), Fixture.segment(1, 2, 4, "s1", "their words")])
        try env.lib.store.update(call.id) { r in       // the transcript was saved, then the archive started
            r.processing = ProcessingInfo(startedAt: enqueuedAt.addingTimeInterval(5), finishedAt: enqueuedAt.addingTimeInterval(300))
        }
        let directory = env.lib.callDirectory(call.id)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("me.wav"), to: directory.appendingPathComponent("me.m4a"))
        try env.writeQueueFile([env.request(call.id)], enqueuedAt: enqueuedAt)   // still names me.wav

        let queue = env.makeQueue()
        queue.resumePersistedJobs()
        try await env.settled(queue, call.id)
        try expectEqual(queue.status(for: call.id)?.state, .done)
        try expectEqual(env.transcriber.requests.count, 0)                    // the transcript isn't redone
        let r = try env.record(call.id)
        try expectEqual(r.status, .ready)
        try expectEqual(r.segments.map(\.text), ["my words", "their words"])
        try expectEqual(r.audio?.meFile, "me.m4a")
        try expectEqual(r.audio?.themFile, "them.m4a")
        try expect(!env.exists(call.id, "them.wav"))
        try expectEqual(env.persistedJobs, 0)
    }

    suite.test("audio is located when the job runs, not when it was queued") {
        let env = QueueEnv("q-locate-audio")
        let queue = env.makeQueue()
        queue.pause()
        let call = try env.addCall(title: "Archived meanwhile", status: .ready, speakers: Fixture.speakers(),
                                   segments: [Fixture.segment(0, 0, 1, "me", "old me"), Fixture.segment(1, 1, 2, "s1", "old them")])
        queue.enqueue(env.request(call.id))                                  // names me.wav and them.wav
        let directory = env.lib.callDirectory(call.id)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("me.wav"), to: directory.appendingPathComponent("me.m4a"))
        queue.resume()
        try await env.settled(queue, call.id)
        let request = try expectNotNil(env.transcriber.requests.first)
        try expectEqual(request.meFile?.lastPathComponent, "me.m4a")
        try expectEqual(request.themFile?.lastPathComponent, "them.wav")
        try expectEqual(try env.record(call.id).segments.map(\.channel), [.me, .them])
    }

    suite.test("a recorded track that is gone fails the job instead of halving the transcript") {
        let env = QueueEnv("q-missing-track")
        let call = try env.addCall(title: "Two sides", status: .ready, speakers: Fixture.speakers(),
                                   segments: [Fixture.segment(0, 0, 1, "me", "old me"), Fixture.segment(1, 1, 2, "s1", "old them")],
                                   audio: [KanPaths.CallFile.themWAV])        // no me.wav and no me.m4a
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await env.settled(queue, call.id)
        try expectEqual(env.transcriber.requests.count, 0)
        let r = try env.record(call.id)
        try expectEqual(r.status, .failed)
        try expectEqual(r.segments.map(\.text), ["old me", "old them"])
        try expect(r.processing?.error?.contains("me.wav") ?? false, r.processing?.error ?? "no error")
        try expect(env.exists(call.id, "them.wav"))
    }

    suite.test("re-transcription keeps the names the user gave on the voices they belong to") {
        var settings = KanSettings()
        settings.userName = "Nahian"
        // First run: Ayesha's "hello?" came first (s1), then Rahman (s2); the user named both.
        let previous = [Speaker(id: "me", name: "Nahian", isMe: true),
                        Speaker(id: "s1", name: "Ayesha", isMe: false, nameSource: .user, personID: "p-ayesha"),
                        Speaker(id: "s2", name: "Rahman", isMe: false, nameSource: .user)]
        let old = [Fixture.segment(0, 0.5, 1.5, "s1", "hello?"), Fixture.segment(1, 2, 10, "s2", "let's start"),
                   Fixture.segment(2, 10.5, 15, "s1", "yes"), Fixture.segment(3, 16, 30, "s2", "the model")]
        // Second run, in Bangla: the opening "hello?" is dropped, so Rahman is numbered s1 now.
        let renumbered = TranscriptionOutput(
            segments: [Fixture.segment(0, 2.1, 9.8, "s1", "চলো শুরু করি", language: "bn"),
                       Fixture.segment(1, 10.4, 15.2, "s2", "হ্যাঁ", language: "bn"),
                       Fixture.segment(2, 16, 29.5, "s1", "মডেলটা", language: "bn")],
            speakers: [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Speaker 1", isMe: false),
                       Speaker(id: "s2", name: "Speaker 2", isMe: false)],
            languages: ["bn"])
        let env = QueueEnv("q-speaker-names", output: renumbered)
        let call = try env.addCall(title: "Names", status: .ready, speakers: previous, segments: old)
        let queue = env.makeQueue()
        try queue.retranscribe(call.id, languageMode: .bangla, settings: settings)
        try await env.settled(queue, call.id)
        let speakers = try env.record(call.id).speakers
        try expectEqual(speakers.map(\.name), ["Nahian", "Rahman", "Ayesha"])
        try expectEqual(speakers.map(\.nameSource), [.automatic, .user, .user])
        try expectEqual(speakers.map(\.personID), [nil, nil, "p-ayesha"])

        // One named voice that the new run splits in two names neither: both only suggest it.
        let split = TranscriptionOutput(
            segments: [Fixture.segment(0, 0, 10, "s1", "first half"), Fixture.segment(1, 10, 20, "s2", "second half")],
            speakers: [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Speaker 1", isMe: false),
                       Speaker(id: "s2", name: "Speaker 2", isMe: false)],
            languages: ["en"])
        let splitEnv = QueueEnv("q-speaker-split", output: split)
        let one = try splitEnv.addCall(title: "Split", status: .ready,
                                       speakers: [Speaker(id: "me", name: "Nahian", isMe: true),
                                                  Speaker(id: "s1", name: "Ayesha", isMe: false, nameSource: .user)],
                                       segments: [Fixture.segment(0, 0, 20, "s1", "one long turn")])
        let splitQueue = splitEnv.makeQueue()
        try splitQueue.retranscribe(one.id, languageMode: nil, settings: settings)
        try await splitEnv.settled(splitQueue, one.id)
        let halves = try splitEnv.record(one.id).speakers
        try expectEqual(halves.map(\.name), ["Nahian", "Speaker 1", "Speaker 2"])
        try expectEqual(halves.map(\.suggestedName), [nil, "Ayesha", "Ayesha"])
    }

    suite.test("voice samples are kept only while Remember voices is on, and Forget All Voices removes them") {
        let env = QueueEnv("q-embeddings")
        let queue = env.makeQueue()
        let call = try env.addCall()
        env.settings.mutate { $0.rememberVoices = true }
        queue.enqueue(env.request(call.id))
        try await env.settled(queue, call.id)
        try expectEqual(SpeakerEmbeddingsFile.read(in: env.lib.callDirectory(call.id)), ["s1": Fixture.vector(0)])

        // Turned off: the next transcription removes the samples of the previous run.
        env.settings.mutate { $0.rememberVoices = false }
        try queue.retranscribe(call.id, languageMode: nil, settings: KanSettings())
        try await env.settled(queue, call.id)
        try expect(!env.exists(call.id, KanPaths.CallFile.embeddings))

        env.settings.mutate { $0.rememberVoices = true }
        try queue.retranscribe(call.id, languageMode: nil, settings: KanSettings())
        try await env.settled(queue, call.id)
        try expect(env.exists(call.id, KanPaths.CallFile.embeddings))
        let voices = VoiceprintStore(fileURL: env.lib.base.appendingPathComponent("people.json"), callsDirectory: env.lib.calls)
        try voices.enroll(name: "Rahim", embedding: Fixture.vector(0))
        try voices.forgetAll()
        try expectEqual(voices.people().count, 0)
        try expect(!env.exists(call.id, KanPaths.CallFile.embeddings), "Forget All Voices left a voice sample")
        try expect(env.exists(call.id, "me.m4a"), "the audio stays")
    }

    suite.test("a starred call keeps its audio even with Keep call audio off") {
        let env = QueueEnv("q-starred-audio")
        env.settings.mutate { $0.keepAudio = false }
        let starred = try env.addCall(title: "Important")
        try env.lib.store.update(starred.id) { $0.starred = true }        // starred in the label panel
        let routine = try env.addCall(title: "Routine")
        let queue = env.makeQueue()
        queue.enqueue(env.request(starred.id))
        queue.enqueue(env.request(routine.id))
        try await env.settled(queue, starred.id, routine.id)
        let kept = try expectNotNil(try env.record(starred.id).audio)
        try expect(kept.isAvailable && kept.deletedAt == nil, "\(kept)")
        try expect(env.exists(starred.id, "me.m4a") && env.exists(starred.id, "them.m4a"))
        try expectEqual(env.archiver.archived.map(\.lastPathComponent), [starred.id.rawValue])
        try expectEqual(env.archiver.deleted.map(\.lastPathComponent), [routine.id.rawValue])
        try expectEqual(try env.record(routine.id).audio?.isAvailable, false)
    }

    suite.test("a call that failed for a missing model is transcribed once the model is installed") {
        let env = QueueEnv("q-waiting-for-models")
        env.transcriber.set(error: TranscriptionError.modelMissing("Silero VAD (silero-v6.2.0)"))
        let call = try env.addCall()
        let queue = env.makeQueue()
        queue.enqueue(env.request(call.id))
        try await env.settled(queue, call.id)
        let failed = try env.record(call.id)
        try expectEqual(failed.status, .failed)
        try expect(failed.processing?.error?.hasPrefix("Model not installed: Silero VAD") ?? false, failed.processing?.error ?? "")
        try expect(failed.processing?.error?.contains("automatically") ?? false)
        try expectEqual(queue.callsWaitingForModels, [call.id])
        try expectEqual(env.persistedWaiting, 1)
        try expect(env.exists(call.id, "me.wav") && env.exists(call.id, "them.wav"))

        // The next launch tries again; still missing, it keeps waiting.
        let relaunched = env.makeQueue()
        relaunched.resumePersistedJobs()
        try await eventually("tried again") { env.transcriber.requests.count == 2 }
        try await env.settled(relaunched, call.id)
        try expectEqual(relaunched.callsWaitingForModels, [call.id])

        // The model is installed: the app asks the queue to retry.
        env.transcriber.set(error: nil)
        relaunched.retryWaitingForModels()
        try await eventually("ready") { env.status(call.id) == .ready }
        try await env.settled(relaunched, call.id)
        try expectEqual(relaunched.callsWaitingForModels, [])
        try expectEqual(env.persistedWaiting, 0)
        try expectEqual(env.transcriber.requests.count, 3)
        relaunched.retryWaitingForModels()                                   // nothing left: a no-op
        try await Task.sleep(nanoseconds: 30_000_000)
        try expectEqual(env.transcriber.requests.count, 3)

        // A waiting call that is cancelled (deleted, for instance) is no longer retried.
        env.transcriber.set(error: TranscriptionError.modelMissing("Whisper large-v3"))
        let other = try env.addCall(title: "Other")
        relaunched.enqueue(env.request(other.id))
        try await eventually("waiting") { relaunched.callsWaitingForModels == [other.id] }
        relaunched.cancel(other.id)
        try expectEqual(relaunched.callsWaitingForModels, [])
        try expectEqual(env.persistedWaiting, 0)
    }

    return suite
}
