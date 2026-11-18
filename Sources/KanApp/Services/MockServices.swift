import AVFoundation
import Foundation
import KanAI
import KanCore

// Mock implementations of every KanCore service protocol. They drive the whole app without
// touching audio hardware, privacy permissions, the network or the Keychain: KAN_MOCK=1 forces
// them, and they're used when the live services can't be created. The Debug submenu and the
// self-test script them.

enum MockServices {
    /// - Parameters:
    ///   - clock: `.realTime()` for the app; a virtual clock makes the self-test instantaneous.
    ///   - transcriptionStepSeconds: pause between progress steps of the mock transcriber.
    ///   - modelDownloadSeconds: how long a mock model download takes.
    ///   - aiSeconds: how long the mock OpenAI takes to answer.
    static func make(clock: MockClock = .realTime(), transcriptionStepSeconds: Double = 0.6,
                     modelDownloadSeconds: Double = 3, aiSeconds: Double = 1.5) -> KanServices {
        let audio = MockAudioLibrary.shared
        let models = MockModelStore(downloadSeconds: modelDownloadSeconds)
        return KanServices(
            detector: MockCallDetector(clock: clock),
            recorder: MockRecorder(clock: clock, audio: audio),
            transcriber: MockTranscriber(audio: audio, stepSeconds: transcriptionStepSeconds, models: models),
            models: models,
            permissions: MockPermissions(),
            archiver: MockArchiver(),
            assistant: MockAssistant(clock: clock, answerSeconds: aiSeconds),
            apiKeys: InMemoryAPIKeyStore(),
            isMock: true)
    }
}

// MARK: - Clock

/// Time for the mocks: the wall clock, or a virtual clock that only moves when told to.
/// Thread-safe. Scheduled actions run on the main queue (real time) or inside `advance` (virtual).
final class MockClock: @unchecked Sendable {
    private struct Scheduled {
        var token: Int
        var due: Date
        var action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let isVirtual: Bool
    private var current: Date
    private var scheduled: [Scheduled] = []
    /// Real-time tokens that haven't fired or been cancelled.
    private var pendingRealTime: Set<Int> = []
    private var nextToken = 1

    private init(isVirtual: Bool, start: Date) {
        self.isVirtual = isVirtual
        self.current = start
    }

    static func realTime() -> MockClock { MockClock(isVirtual: false, start: Date()) }
    static func virtual(start: Date = Date()) -> MockClock { MockClock(isVirtual: true, start: start) }

    func now() -> Date {
        isVirtual ? lock.withLock { current } : Date()
    }

    @discardableResult
    func schedule(after seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) -> Int {
        let token: Int = lock.withLock {
            defer { nextToken += 1 }
            if isVirtual {
                scheduled.append(Scheduled(token: nextToken, due: current.addingTimeInterval(max(0, seconds)), action: action))
            } else {
                pendingRealTime.insert(nextToken)
            }
            return nextToken
        }
        if !isVirtual {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                guard let self, self.lock.withLock({ self.pendingRealTime.remove(token) != nil }) else { return }
                action()
            }
        }
        return token
    }

    func cancel(_ token: Int) {
        lock.withLock {
            if isVirtual {
                scheduled.removeAll { $0.token == token }
            } else {
                pendingRealTime.remove(token)
            }
        }
    }

    /// Virtual clocks: moves time forward, running due actions in time order on this thread.
    func advance(by seconds: TimeInterval) {
        guard isVirtual else { return }
        let target = lock.withLock { current.addingTimeInterval(max(0, seconds)) }
        while true {
            let next: Scheduled? = lock.withLock {
                guard let index = scheduled.indices.filter({ scheduled[$0].due <= target })
                    .min(by: { scheduled[$0].due < scheduled[$1].due }) else { return nil }
                let item = scheduled.remove(at: index)
                current = max(current, item.due)
                return item
            }
            guard let next else { break }
            next.action()
        }
        lock.withLock { current = max(current, target) }
    }
}

// MARK: - Apps

/// App activity snapshots for the simulations (fake pids and process objects).
enum MockApps {
    static func activity(_ bundleID: String, _ name: String, category: AppCategory, mic: Bool = true,
                         output: Bool = true, pid: Int32) -> AppActivity {
        AppActivity(app: AppIdentity(bundleID: bundleID, name: name, path: "/Applications/\(name).app", pid: pid),
                    category: category, micActive: mic, outputActive: output,
                    processObjectIDs: [UInt32(pid) + 1000], processBundleIDs: [bundleID], pids: [pid],
                    inputDeviceUIDs: ["BuiltInMicrophoneDevice"], outputDeviceUIDs: ["BuiltInSpeakerDevice"])
    }

    static var zoom: AppActivity { activity("us.zoom.xos", "Zoom", category: .meeting, pid: 41_001) }
    static var zen: AppActivity { activity("app.zen-browser.zen", "Zen", category: .browser, pid: 41_002) }
    /// Recording a voice message: the mic is on, nothing is playing.
    static var telegramVoiceNote: AppActivity {
        activity("com.tdesktop.Telegram", "Telegram", category: .messaging, output: false, pid: 41_003)
    }
    static var telegramCall: AppActivity { activity("com.tdesktop.Telegram", "Telegram", category: .messaging, pid: 41_003) }
    /// An app that isn't in the catalog (policy: ask).
    static var unknown: AppActivity { activity("com.example.VoiceLounge", "Voice Lounge", category: .unknown, pid: 41_004) }
    /// A browser that isn't in the catalog, recognized by its Info.plist (policy: the browsers', auto).
    static var unlistedBrowser: AppActivity { activity("org.example.Lumen", "Lumen", category: .browser, pid: 41_005) }

    static let meetInfo = MeetingInfo(platform: .googleMeet, title: "Meet – Weekly sync with Prof. Rahman",
                                      url: "https://meet.google.com/abc-defg-hij")
}

// MARK: - Detector

/// A scriptable `CallDetecting` that follows the real rules in simplified form: an app must hold
/// the mic for `startConfirmSeconds`; messaging apps must also play audio (voice notes don't
/// count); policies auto / ask / never; one call at a time; an end grace period with
/// `.ending` / `.resumed`; stale silence; manual sessions. Thread-safe; events are delivered on the
/// main queue, like `CallDetector`'s.
final class MockCallDetector: CallDetecting, @unchecked Sendable {
    private struct Session {
        var call: DetectedCall
        var tentative: Bool
        var endingToken: Int?
        var releasedAt: Date?
        var held = false
        var staleNotified = false
    }

    let clock: MockClock
    private let lock = NSLock()
    private var handler: (@MainActor (DetectionEvent) -> Void)?
    private var config = DetectionConfig()
    private var running = false
    private var activities: [String: AppActivity] = [:]
    private var micSince: [String: Date] = [:]
    private var pendingStarts: [String: Int] = [:]
    private var suppressed: Set<String> = []
    private var session: Session?
    private var decision: String?

    init(clock: MockClock) {
        self.clock = clock
    }

    var onEvent: (@MainActor (DetectionEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// What the detector made of the last simulated mic use ("voice note ignored"…).
    var lastDecision: String? { lock.withLock { decision } }
    var isRunning: Bool { lock.withLock { running } }
    var currentConfig: DetectionConfig { lock.withLock { config } }
    var hasSession: Bool { lock.withLock { session != nil } }

    func start() { lock.withLock { running = true } }

    func stop() {
        lock.withLock {
            running = false
            pendingStarts.values.forEach(clock.cancel)
            pendingStarts.removeAll()
            if let token = session?.endingToken { clock.cancel(token) }
        }
    }

    func update(config: DetectionConfig) { lock.withLock { self.config = config } }

    func respond(_ response: UserCallResponse, to callID: UUID) {
        var events: [DetectionEvent] = []
        lock.withLock {
            guard var s = session, s.call.id == callID else { return }
            switch response {
            case .record:
                s.tentative = false
                session = s
            case .notNow, .never:
                if let token = s.endingToken { clock.cancel(token) }
                session = nil
                suppressed.insert(s.call.app.bundleID)
            case .keepRecording:
                if let token = s.endingToken { clock.cancel(token) }
                s.endingToken = nil
                s.held = s.releasedAt != nil
                s.releasedAt = nil
                session = s
            case .endNow:
                if let token = s.endingToken { clock.cancel(token) }
                session = nil
                if activities[s.call.app.bundleID]?.micActive == true { suppressed.insert(s.call.app.bundleID) }
                events.append(.ended(s.call, endedAt: clock.now()))
            }
        }
        emit(events)
    }

    func reportSilence(seconds: TimeInterval, for callID: UUID) {
        var events: [DetectionEvent] = []
        lock.withLock {
            guard var s = session, s.call.id == callID, s.endingToken == nil else { return }
            if seconds >= config.staleSilenceSeconds {
                guard !s.staleNotified else { return }
                s.staleNotified = true
                events.append(.stale(s.call))
            } else {
                s.staleNotified = false
            }
            session = s
        }
        emit(events)
    }

    func beginManualSession(_ call: DetectedCall) {
        lock.withLock {
            var manual = call
            manual.isManual = true
            if let token = session?.endingToken { clock.cancel(token) }
            session = Session(call: manual, tentative: false)
        }
    }

    func endManualSession(_ callID: UUID) {
        var events: [DetectionEvent] = []
        lock.withLock {
            guard let s = session, s.call.id == callID, s.call.isManual else { return }
            session = nil
            events.append(.ended(s.call, endedAt: clock.now()))
        }
        emit(events)
    }

    func currentActivities() -> [AppActivity] {
        lock.withLock { activities.values.sorted { $0.app.name < $1.app.name } }
    }

    // MARK: Simulation

    /// An app takes the mic (and plays audio, per `activity.outputActive`).
    func simulateMicAcquired(_ activity: AppActivity) {
        let id = activity.app.bundleID
        lock.withLock {
            activities[id] = activity
            micSince[id] = clock.now()
            if let token = pendingStarts.removeValue(forKey: id) { clock.cancel(token) }
            if var s = session, s.call.app.bundleID == id {
                // Back on the mic while the call was ending or held: it's still the same call.
                if let token = s.endingToken {
                    clock.cancel(token)
                    s.endingToken = nil
                    s.releasedAt = nil
                    session = s
                    emitLocked([.resumed(s.call)])
                } else if s.held {
                    s.held = false
                    session = s
                }
                return
            }
            pendingStarts[id] = clock.schedule(after: config.startConfirmSeconds) { [weak self] in
                self?.evaluateStart(id)
            }
        }
    }

    /// The app (default: the call's app) releases the mic: the call ends after the grace period.
    func simulateMicReleased(bundleID: String? = nil) {
        lock.withLock {
            guard let id = bundleID ?? session?.call.app.bundleID ?? activities.keys.first else { return }
            if let token = pendingStarts.removeValue(forKey: id) { clock.cancel(token) }
            activities[id] = nil
            micSince[id] = nil
            suppressed.remove(id)
            guard var s = session, s.call.app.bundleID == id, !s.call.isManual, !s.held, s.endingToken == nil else { return }
            let releasedAt = clock.now()
            let grace = s.call.category == .browser ? config.endGraceBrowserSeconds : config.endGraceNativeSeconds
            let deadline = releasedAt.addingTimeInterval(grace)
            let callID = s.call.id
            s.releasedAt = releasedAt
            s.endingToken = clock.schedule(after: grace) { [weak self] in self?.endIfStillEnding(callID) }
            session = s
            emitLocked([.ending(s.call, deadline: deadline)])
        }
    }

    /// Better meeting information for the current call (a browser tab title / URL).
    func simulateMeetingInfo(_ info: MeetingInfo) {
        lock.withLock {
            guard var s = session else { return }
            s.call.meeting = info
            if info.platform != .browser && info.platform != .other { s.call.platform = info.platform }
            session = s
            emitLocked([.meetingInfo(s.call)])
        }
    }

    /// The call app quits: the call ends at once.
    func simulateAppQuit() {
        lock.withLock {
            guard let s = session, !s.call.isManual else { return }
            if let token = s.endingToken { clock.cancel(token) }
            activities[s.call.app.bundleID] = nil
            session = nil
            emitLocked([.ended(s.call, endedAt: s.releasedAt ?? clock.now())])
        }
    }

    // Debug-menu scenarios.
    func simulateZoomCall() { simulateMicAcquired(MockApps.zoom) }

    func simulateMeetInZen() {
        simulateMicAcquired(MockApps.zen)
        let delay = lock.withLock { config.startConfirmSeconds } + 2
        clock.schedule(after: delay) { [weak self] in self?.simulateMeetingInfo(MockApps.meetInfo) }
    }

    func simulateTelegramVoiceNote() {
        simulateMicAcquired(MockApps.telegramVoiceNote)
        let bundleID = MockApps.telegramVoiceNote.app.bundleID
        clock.schedule(after: 8) { [weak self] in self?.simulateMicReleased(bundleID: bundleID) }
    }

    func simulateUnknownApp() { simulateMicAcquired(MockApps.unknown) }

    // MARK: Rules

    private func evaluateStart(_ id: String) {
        lock.withLock {
            pendingStarts[id] = nil
            guard running, let activity = activities[id], activity.micActive else { return }
            if suppressed.contains(id) {
                decision = "\(activity.app.name): ignored until it releases the mic"
                return
            }
            if activity.category == .messaging || AppCatalog.requiresOutput(bundleID: activity.app.bundleID),
               config.messagingRequiresOutput, !activity.outputActive {
                decision = "\(activity.app.name): mic without sound — a voice note, not a call"
                KanLog.info("mock detector: \(decision ?? "")", category: "mock")
                return
            }
            let now = clock.now()
            if !config.enabled || (config.pausedUntil.map { $0 > now } ?? false) {
                suppressed.insert(id)
                decision = "\(activity.app.name): detection is paused"
                return
            }
            let policy = config.policy(for: activity.app, category: activity.category)
            guard policy != .never else {
                decision = "\(activity.app.name): policy is never"
                return
            }
            var events: [DetectionEvent] = []
            if let s = session {
                // Only a confidently detected app may cut a fading call short (back-to-back calls).
                guard policy == .auto, let releasedAt = s.releasedAt, let token = s.endingToken else {
                    decision = "\(activity.app.name): another call is being recorded"
                    return
                }
                clock.cancel(token)
                session = nil
                events.append(.ended(s.call, endedAt: releasedAt))
            }
            let call = DetectedCall(app: activity.app, category: activity.category,
                                    startedAt: micSince[id] ?? now, platform: AppCatalog.platform(bundleID: id))
            session = Session(call: call, tentative: policy == .ask)
            decision = "\(activity.app.name): \(policy == .auto ? "recording" : "asking")"
            events.append(policy == .auto ? .started(call) : .ask(call))
            emitLocked(events)
        }
    }

    private func endIfStillEnding(_ callID: UUID) {
        lock.withLock {
            guard let s = session, s.call.id == callID, let releasedAt = s.releasedAt, s.endingToken != nil else { return }
            session = nil
            emitLocked([.ended(s.call, endedAt: releasedAt)])
        }
    }

    private func emit(_ events: [DetectionEvent]) {
        lock.withLock { emitLocked(events) }
    }

    /// Delivers in order on the main queue (handler read at delivery time).
    private func emitLocked(_ events: [DetectionEvent]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onEvent else { return }
            MainActor.assumeIsolated {
                for event in events { handler(event) }
            }
        }
    }
}

// MARK: - Recorder

/// Writes plausible me.wav / them.wav (the canned conversation at 16 kHz mono PCM16, silence when
/// Tests/Audio isn't around), anchors.json and session.json when a recording stops. Thread-safe.
final class MockRecorder: CallRecording, @unchecked Sendable {
    let clock: MockClock
    let audio: MockAudioLibrary
    private let lock = NSLock()
    private weak var latest: MockRecordingHandle?
    private var failure: Error?

    init(clock: MockClock, audio: MockAudioLibrary) {
        self.clock = clock
        self.audio = audio
    }

    /// The most recent recording (Debug menu: stale silence, issues).
    var currentHandle: MockRecordingHandle? { lock.withLock { latest } }

    /// Makes the next `start` throw (tests).
    func failNextStart(with error: Error) { lock.withLock { failure = error } }

    func start(_ request: RecordingRequest) throws -> RecordingHandle {
        if let error = lock.withLock({ () -> Error? in defer { failure = nil }; return failure }) { throw error }
        try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        let handle = MockRecordingHandle(request: request, clock: clock, audio: audio)
        lock.withLock { latest = handle }
        return handle
    }
}

final class MockRecordingHandle: RecordingHandle, @unchecked Sendable {
    let callID: CallID
    let startedAt: Date
    private let request: RecordingRequest
    private let clock: MockClock
    private let audio: MockAudioLibrary
    private let lock = NSLock()
    private var pausedAt: Date?
    private var pausedRanges: [ClosedRange<Double>] = []
    private var issueList: [RecordingIssue] = []
    private var issueHandler: (@Sendable (RecordingIssue) -> Void)?
    private var forcedSilence: TimeInterval?
    private var finished = false

    init(request: RecordingRequest, clock: MockClock, audio: MockAudioLibrary) {
        self.request = request
        self.callID = request.callID
        self.clock = clock
        self.audio = audio
        self.startedAt = clock.now()
    }

    private var recordsMe: Bool { request.captureMic }
    private var recordsThem: Bool {
        if case .micOnly = request.target { return false }
        return true
    }

    var levels: AudioLevels {
        let (paused, done) = lock.withLock { (pausedAt != nil, finished) }
        guard !paused, !done else { return .zero }
        let elapsed = clock.now().timeIntervalSince(startedAt)
        let layout = MockScript.layout(duration: elapsed + 1, clipSeconds: audio.seconds)
        func level(_ channel: AudioChannel) -> Float {
            guard let placement = layout.last(where: { $0.line.channel == channel && $0.start <= elapsed && elapsed < $0.end })
            else { return 0.002 }
            guard let clip = audio.clip(placement.line.clip) else { return 0.08 }
            let index = Int((elapsed - placement.start) * 10)
            return clip.envelope.indices.contains(index) ? clip.envelope[index] : 0
        }
        return AudioLevels(me: recordsMe ? level(.me) : 0, them: recordsThem ? level(.them) : 0)
    }

    var isPaused: Bool { lock.withLock { pausedAt != nil } }
    var issues: [RecordingIssue] { lock.withLock { issueList } }

    var silenceSeconds: TimeInterval {
        if let forced = lock.withLock({ forcedSilence }) { return forced }
        if isPaused { return 0 }
        let elapsed = clock.now().timeIntervalSince(startedAt)
        let layout = MockScript.layout(duration: elapsed, clipSeconds: audio.seconds)
        guard let last = layout.last else { return max(0, elapsed) }
        return max(0, elapsed - last.end)
    }

    var onIssue: (@Sendable (RecordingIssue) -> Void)? {
        get { lock.withLock { issueHandler } }
        set { lock.withLock { issueHandler = newValue } }
    }

    func pause() {
        lock.withLock { if pausedAt == nil { pausedAt = clock.now() } }
    }

    func resume() {
        lock.withLock {
            guard let since = pausedAt else { return }
            pausedRanges.append(since.timeIntervalSince(startedAt)...clock.now().timeIntervalSince(startedAt))
            pausedAt = nil
        }
    }

    func retarget(_ activity: AppActivity) {
        KanLog.info("mock recording \(callID): retarget to \(activity.processObjectIDs)", category: "mock")
    }

    /// Debug / tests: pretend both tracks have been silent this long (nil = back to the script).
    func forceSilence(_ seconds: TimeInterval?) { lock.withLock { forcedSilence = seconds } }

    /// Debug / tests: report a recording issue as the real recorder would.
    func raise(_ issue: RecordingIssue) {
        let handler: (@Sendable (RecordingIssue) -> Void)? = lock.withLock {
            guard !issueList.contains(issue) else { return nil }
            issueList.append(issue)
            return issueHandler
        }
        handler?(issue)
    }

    func stop(trimEndAt: Date?) async -> RecordingResult {
        let stopDate = clock.now()
        let (paused, issues) = lock.withLock { () -> ([ClosedRange<Double>], [RecordingIssue]) in
            finished = true
            if let since = pausedAt {
                pausedRanges.append(since.timeIntervalSince(startedAt)...stopDate.timeIntervalSince(startedAt))
                pausedAt = nil
            }
            return (pausedRanges, issueList)
        }
        let endedAt = max(startedAt, min(stopDate, trimEndAt ?? stopDate))
        let duration = endedAt.timeIntervalSince(startedAt)
        let directory = request.directory
        let layout = MockScript.layout(duration: duration, clipSeconds: audio.seconds)
        var meURL: URL?
        var themURL: URL?
        do {
            if recordsMe {
                let url = directory.appendingPathComponent(KanPaths.CallFile.meWAV)
                try writeTrack(.me, layout: layout, duration: duration, paused: paused, to: url)
                meURL = url
            }
            if recordsThem {
                let url = directory.appendingPathComponent(KanPaths.CallFile.themWAV)
                try writeTrack(.them, layout: layout, duration: duration, paused: paused, to: url)
                themURL = url
            }
        } catch {
            KanLog.error("mock recording \(callID): writing audio failed: \(error.localizedDescription)", category: "mock")
        }
        let anchors = directory.appendingPathComponent(KanPaths.CallFile.anchors)
        let anchorsJSON: [String: Any] = ["sampleRate": WAV.sampleRate, "startedAt": KanDate.iso8601(startedAt), "mock": true]
        if let data = try? JSONSerialization.data(withJSONObject: anchorsJSON, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: anchors, options: .atomic)
        }
        let result = RecordingResult(callID: callID, directory: directory, meFile: meURL, themFile: themURL,
                                     anchorsFile: anchors, startedAt: startedAt, endedAt: endedAt,
                                     meSeconds: meURL == nil ? 0 : duration, themSeconds: themURL == nil ? 0 : duration,
                                     loudspeakerSuspected: false, issues: issues)
        do {
            try JSONEncoder.kanPretty.encode(result).write(to: directory.appendingPathComponent(KanPaths.CallFile.session),
                                                           options: .atomic)
        } catch {
            KanLog.error("mock recording \(callID): writing session.json failed: \(error.localizedDescription)", category: "mock")
        }
        return result
    }

    func discard() async {
        lock.withLock { finished = true }
        let fm = FileManager.default
        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.anchors, KanPaths.CallFile.session] {
            try? fm.removeItem(at: request.directory.appendingPathComponent(name))
        }
        if (try? fm.contentsOfDirectory(atPath: request.directory.path))?.isEmpty == true {
            try? fm.removeItem(at: request.directory)
        }
    }

    /// One track of the conversation, written in one-second chunks; paused spans are silent.
    private func writeTrack(_ channel: AudioChannel, layout: [MockScript.Placement], duration: Double,
                            paused: [ClosedRange<Double>], to url: URL) throws {
        let rate = WAV.sampleRate
        let total = Int(duration * Double(rate))
        let writer = try WAV.Writer(url: url)
        let placements = layout.filter { $0.line.channel == channel }
        var frame = 0
        while frame < total {
            let count = min(rate, total - frame)
            var chunk = [Int16](repeating: 0, count: count)
            for placement in placements {
                guard let clip = audio.clip(placement.line.clip) else { continue }
                let start = Int(placement.start * Double(rate))
                let end = min(Int(placement.end * Double(rate)), start + clip.samples.count)
                let from = max(start, frame), to = min(end, frame + count)
                guard from < to else { continue }
                for i in from..<to { chunk[i - frame] = clip.samples[i - start] }
            }
            for range in paused {
                let from = max(frame, Int(range.lowerBound * Double(rate)))
                let to = min(frame + count, Int(range.upperBound * Double(rate)))
                if from < to { for i in from..<to { chunk[i - frame] = 0 } }
            }
            try writer.write(chunk)
            frame += count
        }
        try writer.finish()
    }
}

// MARK: - Transcriber

/// Returns the canned bilingual conversation laid out over the recording's duration, with
/// progress through the real pipeline's stages. Honours cancellation. Like the real pipeline, it
/// fails with `TranscriptionError.modelMissing` while `models` can't transcribe. Thread-safe.
final class MockTranscriber: Transcribing, @unchecked Sendable {
    private let audio: MockAudioLibrary
    private let stepSeconds: Double
    private let models: MockModelStore?
    private let lock = NSLock()
    private var failure: Error?
    private var held = false

    init(audio: MockAudioLibrary, stepSeconds: Double, models: MockModelStore? = nil) {
        self.audio = audio
        self.stepSeconds = stepSeconds
        self.models = models
    }

    /// Makes the next transcription throw (tests, Debug).
    func failNext(with error: Error) { lock.withLock { failure = error } }

    /// Tests: transcriptions wait before their last step until `release()`, as a long call's would
    /// (so the label panel can be saved before the transcript is ready).
    func hold() { lock.withLock { held = true } }

    func release() { lock.withLock { held = false } }

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> TranscriptionOutput {
        let stages: [PipelineStage] = [.preparing, .detectingSpeech, .separatingSpeakers, .identifyingLanguage,
                                       .transcribingEnglish, .transcribingBangla, .assembling, .finishing]
        let started = Date()
        let duration = [request.meFile, request.themFile].compactMap { $0 }.compactMap(Self.duration(of:)).max()
        guard let duration, duration > 0 else { throw TranscriptionError.noAudio }
        if let models, !models.readiness(for: KanSettings()).canTranscribe {
            throw TranscriptionError.modelMissing(request.englishModelID == "auto" ? "a Whisper model" : request.englishModelID)
        }
        for (i, stage) in stages.enumerated() {
            progress(PipelineProgress(stage: stage, fraction: Double(i) / Double(stages.count)))
            try await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
        }
        while lock.withLock({ held }) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if let error = lock.withLock({ () -> Error? in defer { failure = nil }; return failure }) { throw error }
        progress(PipelineProgress(stage: .finishing, fraction: 1))

        let hasMe = request.meFile != nil, hasThem = request.themFile != nil
        let placements = MockScript.layout(duration: duration, clipSeconds: audio.seconds)
            .filter { $0.line.channel == .me ? hasMe : hasThem }
        let segments = placements.enumerated().map { index, placement -> TranscriptSegment in
            var language = placement.line.language
            if request.languageMode == .english { language = "en" }
            if request.languageMode == .bangla { language = "bn" }
            return TranscriptSegment(id: index, start: placement.start, end: placement.end,
                                     speakerID: placement.line.speakerID, channel: placement.line.channel,
                                     text: placement.line.text, language: language, confidence: 0.9)
        }
        var talk: [String: Double] = [:]
        for segment in segments { talk[segment.speakerID, default: 0] += segment.end - segment.start }
        var speakers = [Speaker(id: Speaker.meID, name: request.userName, isMe: true, talkTime: talk[Speaker.meID] ?? 0)]
        for (n, id) in ["s1", "s2"].enumerated() where talk[id] != nil {
            speakers.append(Speaker(id: id, name: Speaker.defaultName(number: n + 1), isMe: false, talkTime: talk[id] ?? 0))
        }
        var languages: [String] = []
        for segment in segments where !languages.contains(segment.language) { languages.append(segment.language) }
        var embeddings: [String: [Float]] = [:]
        for speaker in speakers where !speaker.isMe { embeddings[speaker.id] = Self.embedding(for: speaker.id) }
        return TranscriptionOutput(segments: segments, speakers: hasMe ? speakers : speakers.filter { !$0.isMe },
                                   languages: languages, speakerEmbeddings: embeddings, modelsUsed: ["mock"],
                                   warnings: [], stats: ["seconds.total": Date().timeIntervalSince(started),
                                                         "seconds.audio": duration])
    }

    /// WAV header, or AVAudioFile for archived m4a.
    static func duration(of url: URL) -> Double? {
        if let seconds = WAV.duration(of: url) { return seconds }
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// A fixed unit vector per remote speaker, so the same mock person is recognized across calls.
    static func embedding(for speakerID: String) -> [Float] {
        var state = UInt64(truncatingIfNeeded: speakerID.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) })
        var vector = [Float](repeating: 0, count: 256)
        for i in vector.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            vector[i] = Float(Int64(bitPattern: state >> 11) % 2001 - 1000) / 1000
        }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }
}

// MARK: - OpenAI

/// A scriptable `CallAssisting`: canned title ideas and a summary of the canned conversation
/// (naming the speakers as the call it's given has them), an answer delay, scripted failures, held
/// requests and a record of every request. It checks the key and the transcript the way
/// `OpenAIAssistant` does and honours cancellation. Nothing reaches the network. Thread-safe.
final class MockAssistant: CallAssisting, @unchecked Sendable {
    enum Kind: String, Sendable {
        case titles, summary, models
    }

    /// A request as the mock received it.
    struct Request: Sendable {
        var kind: Kind
        var callID: CallID?
        var apiKey: String
        var model: String
        var language: AIOutputLanguage
        var userName: String
        /// `CallInsights.fingerprint(of:)` of the call sent.
        var fingerprint: String
        /// The call's speaker names as sent (the summary must see those given in the label panel).
        var speakerNames: [String]
    }

    static let defaultTitles = [
        "Bangla speech recognition with little data",
        "Fine-tuning a multilingual model for Bangla",
        "Plan for a Bangla speech dataset",
    ]

    private static let banglaTitles = [
        "অল্প ডেটায় বাংলা স্পিচ রিকগনিশন",
        "বাংলার জন্য মাল্টিলিঙ্গুয়াল মডেল ফাইন-টিউনিং",
        "বাংলা স্পিচ ডেটাসেটের পরিকল্পনা",
    ]

    /// What `availableModels` answers: the known models and a few that aren't for text.
    static let defaultModels = ["gpt-6-astra", "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-image-2",
                                "gpt-realtime-2", "text-embedding-4-small"]

    private let clock: MockClock
    private let answerSeconds: Double
    private let lock = NSLock()
    private var titles = MockAssistant.defaultTitles
    private var failures: [Kind: [AIError]] = [:]
    private var standingFailure: AIError?
    private var held: Set<Kind> = []
    private var received: [Request] = []
    private var unanswered: [Kind: Int] = [:]
    private var cancelled: [Kind: Int] = [:]
    private var answersWhenCancelled = false

    init(clock: MockClock, answerSeconds: Double) {
        self.clock = clock
        self.answerSeconds = answerSeconds
    }

    // MARK: Scripting

    /// The title ideas of the next answers (`defaultTitles` to begin with).
    func setTitles(_ titles: [String]) { lock.withLock { self.titles = titles } }

    /// The next request of `kind` fails with `error` (calling it again queues more failures).
    func failNext(_ kind: Kind, with error: AIError) { lock.withLock { failures[kind, default: []].append(error) } }

    /// Debug: every request fails with `error` until this is set to nil.
    func setStandingFailure(_ error: AIError?) { lock.withLock { standingFailure = error } }

    /// Requests of `kind` wait once received, until `release(kind)` (a slow answer).
    func hold(_ kind: Kind) { _ = lock.withLock { held.insert(kind) } }

    func release(_ kind: Kind) { _ = lock.withLock { held.remove(kind) } }

    /// Tests: answers even after the request was cancelled, as a response already on its way does
    /// (Kan must drop it itself).
    func answerWhenCancelled(_ answers: Bool) { lock.withLock { answersWhenCancelled = answers } }

    /// Every request received, oldest first.
    var requests: [Request] { lock.withLock { received } }

    func requests(_ kind: Kind, for id: CallID? = nil) -> [Request] {
        requests.filter { $0.kind == kind && (id == nil || $0.callID == id) }
    }

    /// Requests of `kind` received and not answered (or failed) yet.
    func inFlight(_ kind: Kind) -> Int { lock.withLock { unanswered[kind] ?? 0 } }

    /// Requests of `kind` whose task was cancelled while the mock worked on them.
    func cancellations(_ kind: Kind) -> Int { lock.withLock { cancelled[kind] ?? 0 } }

    // MARK: CallAssisting

    func suggestTitles(for record: CallRecord, options: AIOptions) async throws -> AITitleSuggestions {
        try Self.check(options.apiKey, record: record)
        try await answer(.titles, request: Self.request(.titles, record: record, options: options))
        let scripted = lock.withLock { self.titles }
        let ideas = options.language == .bangla && scripted == Self.defaultTitles ? Self.banglaTitles : scripted
        return AITitleSuggestions(titles: ideas, model: options.model, generatedAt: clock.now(),
                                  fingerprint: CallInsights.fingerprint(of: record))
    }

    func summarize(_ record: CallRecord, options: AIOptions) async throws -> AISummary {
        try Self.check(options.apiKey, record: record)
        try await answer(.summary, request: Self.request(.summary, record: record, options: options))
        return Self.summary(of: record, options: options, at: clock.now())
    }

    func availableModels(apiKey: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.missingKey }
        try await answer(.models, request: Request(kind: .models, callID: nil, apiKey: apiKey, model: "",
                                                   language: .english, userName: "", fingerprint: "", speakerNames: []))
        return Self.defaultModels.sorted()
    }

    // MARK: Internals

    private static func check(_ key: String, record: CallRecord) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.missingKey }
        guard OpenAIPrompts.hasTranscript(record) else { throw AIError.emptyTranscript }
    }

    private static func request(_ kind: Kind, record: CallRecord, options: AIOptions) -> Request {
        Request(kind: kind, callID: record.id, apiKey: options.apiKey, model: options.model, language: options.language,
                userName: options.userName, fingerprint: CallInsights.fingerprint(of: record),
                speakerNames: record.speakers.map(\.name))
    }

    /// Records the request, takes as long as an answer would (held, then the delay), then throws a
    /// scripted failure, if any.
    private func answer(_ kind: Kind, request: Request) async throws {
        lock.withLock {
            received.append(request)
            unanswered[kind, default: 0] += 1
        }
        defer { lock.withLock { unanswered[kind] = max(0, (unanswered[kind] ?? 1) - 1) } }
        let ignoresCancellation = lock.withLock { answersWhenCancelled }
        do {
            while lock.withLock({ held.contains(kind) }) {
                if ignoresCancellation {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            if answerSeconds > 0 { try await Task.sleep(nanoseconds: UInt64(answerSeconds * 1_000_000_000)) }
            if !ignoresCancellation { try Task.checkCancellation() }
        } catch {
            lock.withLock { cancelled[kind, default: 0] += 1 }
            throw error
        }
        if Task.isCancelled { lock.withLock { cancelled[kind, default: 0] += 1 } }
        let failure: AIError? = lock.withLock {
            if var queued = failures[kind], !queued.isEmpty {
                let first = queued.removeFirst()
                failures[kind] = queued
                return first
            }
            return standingFailure
        }
        if let failure { throw failure }
    }

    /// A summary of the canned conversation that names the speakers as `record` has them.
    static func summary(of record: CallRecord, options: AIOptions, at date: Date) -> AISummary {
        let me = options.userName.isEmpty ? (record.me?.name ?? "Me") : options.userName
        func name(_ id: String) -> String { record.speaker(id)?.name ?? "the other side" }
        let overview = options.language == .bangla
            ? "অল্প কয়েক ঘণ্টার ডেটা দিয়ে বাংলা ভাষার জন্য একটি স্পিচ রিকগনিশন মডেল তৈরির পরিকল্পনা নিয়ে আলোচনা হয়েছে। প্রথম কাজ ডেটাসেট সংগ্রহ করা।"
            : "\(me), \(name("s1")) and \(name("s2")) discussed a speech recognition model for Bangla trained on only a few hours of data. "
                + "Fine-tuning a multilingual model, data augmentation and pseudo-labeling came up; the first step is collecting a dataset."
        return AISummary(
            overview: overview,
            keyPoints: ["The key question is whether a multilingual model can be fine-tuned with a few hours of Bangla data [00:00:09]",
                        "The project starts with collecting a dataset, then training the model [00:00:32]"],
            ideas: ["Data augmentation and pseudo-labeling from unlabeled recordings, proposed by \(me) [00:00:26]",
                    "A Bangla speech recognition model built for this project (\(name("s2"))) [00:00:16]"],
            decisions: ["Write down the plan and meet again next week [00:00:38]"],
            actionItems: ["\(me): write down the plan", "\(name("s2")): start collecting the dataset"],
            openQuestions: ["How many hours of Bangla data are enough for fine-tuning?"],
            language: options.language, model: options.model, generatedAt: date,
            fingerprint: CallInsights.fingerprint(of: record))
    }
}

// MARK: - Models

/// The real model catalog's shape, with install state in memory; downloads take a few seconds.
final class MockModelStore: ModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<String> = ["large-v3-turbo", "silero-v6.2.0", "fluidaudio-diarizer", "large-v3-q5_0"]
    let downloadSeconds: Double

    init(downloadSeconds: Double = 3) {
        self.downloadSeconds = downloadSeconds
    }

    private static let catalog: [(id: String, name: String, detail: String, role: ModelRole, size: Int64, recommended: Bool)] = [
        ("large-v3-q5_0", "Whisper large-v3 (q5_0)", "Language ID and Bangla fallback; quantized", .general, 1_080_000_000, true),
        ("large-v3", "Whisper large-v3", "Most accurate general model", .general, 3_100_000_000, false),
        ("large-v3-turbo", "Whisper large-v3 turbo", "Fast English", .english, 1_620_000_000, true),
        ("bengali-medium-q8_0", "Bengali Whisper medium (q8_0)", "Bengali.AI fine-tune: much better Bangla", .bangla, 820_000_000, true),
        ("silero-v6.2.0", "Silero VAD v6.2", "Finds speech", .vad, 885_000, true),
        ("fluidaudio-diarizer", "FluidAudio speaker models", "Who said what", .diarization, 52_000_000, true),
    ]

    func availableModels() -> [ModelInfo] {
        let installed = lock.withLock { self.installed }
        return Self.catalog.map {
            ModelInfo(id: $0.id, displayName: $0.name, detail: $0.detail, role: $0.role, sizeBytes: $0.size,
                      installed: installed.contains($0.id), recommended: $0.recommended)
        }
    }

    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard Self.catalog.contains(where: { $0.id == id }) else { throw TranscriptionError.modelMissing(id) }
        let steps = 20
        for step in 1...steps {
            try await Task.sleep(nanoseconds: UInt64(downloadSeconds / Double(steps) * 1_000_000_000))
            progress(Double(step) / Double(steps))
        }
        _ = lock.withLock { installed.insert(id) }
    }

    func delete(_ id: String) throws {
        _ = lock.withLock { installed.remove(id) }
    }

    func readiness(for settings: KanSettings) -> ModelReadiness {
        let installed = lock.withLock { self.installed }
        func first(_ role: ModelRole) -> String? {
            Self.catalog.first { $0.role == role && installed.contains($0.id) }?.id
        }
        var resolved: [ModelRole: String] = [:]
        for role in ModelRole.allCases { resolved[role] = first(role) }
        var missing: [String] = []
        if resolved[.general] == nil && resolved[.english] == nil { missing.append("No Whisper model installed") }
        if resolved[.vad] == nil { missing.append("The voice-activity model is missing") }
        var recommendations: [String] = []
        if resolved[.bangla] == nil { recommendations.append("Download the Bangla model for much better Bangla") }
        if settings.diarize && resolved[.diarization] == nil { recommendations.append("Download the speaker models to tell speakers apart") }
        return ModelReadiness(canTranscribe: missing.isEmpty, missing: missing, recommendations: recommendations,
                              resolved: resolved)
    }
}

// MARK: - Permissions

/// Everything granted unless simulated otherwise; requests answer at once; nothing is shown.
/// Thread-safe.
final class MockPermissions: PermissionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [PermissionKind: PermissionStatus] = [:]
    private var pendingRelaunch: Set<PermissionKind> = []

    func status(_ kind: PermissionKind) -> PermissionStatus { lock.withLock { statuses[kind] ?? .granted } }
    func request(_ kind: PermissionKind) async -> PermissionStatus { status(kind) }
    func openSystemSettings(_ kind: PermissionKind) {
        KanLog.info("mock: would open System Settings for \(kind.rawValue)", category: "mock")
    }

    func needsRelaunch(_ kind: PermissionKind) -> Bool { lock.withLock { pendingRelaunch.contains(kind) } }

    /// Debug / tests: what System Settings says about `kind`; `pendingRelaunch` = changed there
    /// while Kan runs (System Audio Recording then applies only after a relaunch).
    func simulate(_ kind: PermissionKind, _ status: PermissionStatus, pendingRelaunch: Bool = false) {
        lock.withLock {
            statuses[kind] = status
            if pendingRelaunch { self.pendingRelaunch.insert(kind) } else { self.pendingRelaunch.remove(kind) }
        }
    }
}

// MARK: - Archiver

/// Keeps the audio as the real archiver does (AAC .m4a, WAVs removed), cheaply; if encoding fails
/// the WAVs are kept and reported as the kept files.
struct MockArchiver: AudioArchiving {
    func archive(directory: URL) async throws -> AudioAssets {
        let fm = FileManager.default
        var kept: [AudioChannel: String] = [:]
        var bytes: Int64 = 0
        for (channel, wav, m4a) in [(AudioChannel.me, KanPaths.CallFile.meWAV, KanPaths.CallFile.meM4A),
                                    (AudioChannel.them, KanPaths.CallFile.themWAV, KanPaths.CallFile.themM4A)] {
            let source = directory.appendingPathComponent(wav)
            let target = directory.appendingPathComponent(m4a)
            if fm.fileExists(atPath: source.path) {
                do {
                    try Self.encode(source, to: target)
                    try fm.removeItem(at: source)
                    kept[channel] = m4a
                } catch {
                    KanLog.warning("mock archiver: keeping \(wav) uncompressed (\(error.localizedDescription))", category: "mock")
                    try? fm.removeItem(at: target)
                    kept[channel] = wav
                }
            } else if fm.fileExists(atPath: target.path) {
                kept[channel] = m4a
            }
            if let name = kept[channel] {
                bytes += (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?
                    .int64Value ?? 0
            }
        }
        guard !kept.isEmpty else { throw TranscriptionError.noAudio }
        let format = kept.values.allSatisfy { $0.hasSuffix(".m4a") } ? "m4a" : "wav"
        return AudioAssets(meFile: kept[.me], themFile: kept[.them], format: format, sizeBytes: bytes)
    }

    func deleteAudio(in directory: URL) throws {
        let fm = FileManager.default
        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    private static func encode(_ source: URL, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000.0,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let partial = target.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            let output = try AVAudioFile(forWriting: partial, settings: settings,
                                         commonFormat: input.processingFormat.commonFormat,
                                         interleaved: input.processingFormat.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768) else {
                throw TranscriptionError.audioUnreadable(source.lastPathComponent)
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }
}
