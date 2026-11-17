import Accelerate
import Foundation
import KanCore
import os

public enum RecorderError: Error, CustomStringConvertible {
    case diskFull(availableBytes: Int64)
    case cannotCreate(URL, String)
    case nothingToRecord(String)

    public var description: String {
        switch self {
        case .diskFull(let bytes): return "not enough free disk space to record (\(bytes / 1_048_576) MB free)"
        case .cannotCreate(let url, let why): return "cannot create \(url.path): \(why)"
        case .nothingToRecord(let why): return "nothing to record: \(why)"
        }
    }
}

/// One call's recording. Writes, in `request.directory`:
///
/// * `me.wav`, `them.wav` — 16 kHz mono PCM16, both starting at the session start on one clock:
///   audio is placed by its HAL host time; gaps (rebuilds, device switches, pause, missing source)
///   are filled with silence and drift beyond 100 ms is corrected by padding or dropping samples.
///   Headers are rewritten every ~2 s, so a crash leaves valid files.
/// * `anchors.json` — `RecordingAnchors` (track frame ↔ host time, plus every edit), rewritten
///   every 30 s and on stop.
/// * `session.json` — the `RecordingResult`, written on stop.
///
/// Recovery never gives up while recording: the "them" tap is rebuilt after faults and, when it
/// can't start, falls back for now (the call app's tap → all system audio → no call audio) while it
/// keeps trying to get back (see *Tap*); "me" follows the call app's microphone (`retarget`) or else
/// the default input, and restarts after device loss.
///
/// Thread-safety: every public member may be called from any thread. Capture, conversion and file
/// IO run on a private serial queue; `levels`, `issues`, `isPaused` and `silenceSeconds` read a
/// lock-protected snapshot. `onIssue` is called on that private queue.
public final class RecordingSession: RecordingHandle, @unchecked Sendable {
    public let callID: CallID
    public let startedAt: Date
    public let directory: URL

    // MARK: Shared state (lock)

    private struct Shared {
        var levels = AudioLevels.zero
        var isPaused = false
        var issues: [RecordingIssue] = []
        var onIssue: (@Sendable (RecordingIssue) -> Void)?
        var lastAudibleHost: UInt64
    }

    private let shared: OSAllocatedUnfairLock<Shared>

    // MARK: Worker-confined state (only touched on `queue`)

    private enum Lifecycle {
        case recording
        case stopped(RecordingResult)
        case discarded
    }

    /// Scheduled tap work, run by the pump on the host clock.
    private enum TapJob {
        /// (Re)start a tap while none runs.
        case start
        /// Replace the system-audio fallback with the call app's tap.
        case returnToApp
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let env: RecordingEnvironment
    private let options: RecordingOptions
    private let request: RecordingRequest
    private let startHost: UInt64
    private var lifecycle = Lifecycle.recording
    private var me: Track?
    private var them: Track?
    /// The call app (`.app` requests; nil for all system audio or mic only).
    private var activity: AppActivity?
    /// Its tap; kept up to date (retargets, re-resolution) even while the fallback runs.
    private var appTarget: TapTarget?
    /// The call app's tap can't run right now: all system audio stands in for it.
    private var onSystemFallback = false
    /// No tap would start (`.tapFailed`): one attempt per target and round, every `tapRecoverySeconds`.
    private var tapRecovering = false
    private var tapRetry = 0
    private var tapStartsAttempted = 0
    private var tapEverStarted = false
    private var tapStartDue: UInt64?
    private var tapReturnDue: UInt64?
    private var tapLimiter: RebuildLimiter
    private var micChoice: MicrophoneSelector.Choice?
    private var micRestartPending = false
    private var micRetryScheduled = false
    private var micLimiter: RebuildLimiter
    private var loudspeakerSuspected = false
    private var reportedSystemAudioSilence = false
    private var loggedRealSilence = false
    private var timer: DispatchSourceTimer?
    private var systemObserver: AnyObject?
    private var lastPumpHost: UInt64
    private var lastAnchorsWrite: UInt64
    private var createdDirectory = false
    private var createdFiles: [URL] = []

    /// Prefer `CallRecorder.start(_:)`. Creates the directory and both WAV files synchronously
    /// (errors throw), then starts capture asynchronously; capture problems become `issues`.
    public init(request: RecordingRequest, environment: RecordingEnvironment, options: RecordingOptions = RecordingOptions()) throws {
        self.request = request
        self.callID = request.callID
        self.directory = request.directory
        self.env = environment
        self.options = options
        self.startHost = environment.hostTime()
        self.startedAt = environment.wallClock()
        self.lastPumpHost = startHost
        self.lastAnchorsWrite = startHost
        self.shared = OSAllocatedUnfairLock(initialState: Shared(lastAudibleHost: startHost))
        self.queue = DispatchQueue(label: "com.nahian.Kan.recording.\(request.callID.rawValue)", qos: .userInitiated)
        self.tapLimiter = RebuildLimiter(maxEvents: options.maxRebuildsPerMinute, windowSeconds: 60)
        self.micLimiter = RebuildLimiter(maxEvents: options.maxRebuildsPerMinute, windowSeconds: 60)
        let recordThem: Bool
        switch request.target {
        case .app(let activity):
            self.activity = activity
            self.appTarget = TapTarget.app(activity)
            recordThem = true
        case .systemAudio:
            recordThem = true
        case .micOnly:
            recordThem = false
        }
        queue.setSpecific(key: queueKey, value: true)

        let micDenied = environment.microphonePermission() == .denied
        if !recordThem && (!request.captureMic || micDenied) {
            throw RecorderError.nothingToRecord(request.captureMic ? "the microphone permission is denied" : "no microphone and no call audio requested")
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                createdDirectory = true
            } catch {
                throw RecorderError.cannotCreate(directory, error.localizedDescription)
            }
        }
        if let free = environment.availableDiskBytes(at: directory), free < options.minimumFreeDiskBytes {
            throw RecorderError.diskFull(availableBytes: free)
        }
        do {
            if request.captureMic {
                me = try makeTrack(.me, file: KanPaths.CallFile.meWAV)
            }
            if recordThem {
                them = try makeTrack(.them, file: KanPaths.CallFile.themWAV)
            }
        } catch {
            for url in createdFiles { try? fm.removeItem(at: url) }
            if createdDirectory { try? fm.removeItem(at: directory) }
            throw error
        }
        KanLog.info("recording \(callID) started → \(directory.path) (target \(describe(request.target)), mic \(request.captureMic))", category: "recorder")
        queue.async { [weak self] in self?.begin() }
    }

    deinit {
        timer?.cancel()
        for track in [me, them].compactMap({ $0 }) {
            track.source?.stop()
            try? track.writer.close()
        }
    }

    // MARK: RecordingHandle

    public var levels: AudioLevels { shared.withLock { $0.levels } }
    public var isPaused: Bool { shared.withLock { $0.isPaused } }
    public var issues: [RecordingIssue] { shared.withLock { $0.issues } }

    public var silenceSeconds: TimeInterval {
        let (last, paused) = shared.withLock { ($0.lastAudibleHost, $0.isPaused) }
        return paused ? 0 : max(0, HostClock.seconds(from: last, to: env.hostTime()))
    }

    public var onIssue: (@Sendable (RecordingIssue) -> Void)? {
        get { shared.withLock { $0.onIssue } }
        set { shared.withLock { $0.onIssue = newValue } }
    }

    public func pause() {
        let changed = shared.withLock { s -> Bool in
            defer { s.isPaused = true }
            return !s.isPaused
        }
        if changed { KanLog.info("recording \(callID) paused", category: "recorder") }
    }

    public func resume() {
        let now = env.hostTime()
        let changed = shared.withLock { s -> Bool in
            defer {
                s.isPaused = false
                s.lastAudibleHost = now
            }
            return s.isPaused
        }
        if changed { KanLog.info("recording \(callID) resumed", category: "recorder") }
    }

    public func retarget(_ activity: AppActivity) {
        queue.async { [weak self] in self?.applyRetarget(activity) }
    }

    public func stop(trimEndAt: Date?) async -> RecordingResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.finish(trimEndAt: trimEndAt))
            }
        }
    }

    public func discard() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.discardNow()
                continuation.resume()
            }
        }
    }

    /// Drains captured audio now. The internal timer does this every `pumpInterval`; tests run
    /// with `pumpInterval = nil` and call this instead. Safe from any thread.
    public func processPendingAudio() {
        if DispatchQueue.getSpecific(key: queueKey) == true { pump() } else { queue.sync { pump() } }
    }

    /// True while the loudspeaker heuristic has fired at least once in this session.
    public var isLoudspeakerSuspected: Bool { onQueue { loudspeakerSuspected } }

    /// Names of the sources currently feeding each track (diagnostics).
    public var currentSources: (me: String?, them: String?) { onQueue { (me?.source?.name, them?.source?.name) } }

    // MARK: Start

    private func begin() {
        guard isRecording else { return }
        systemObserver = env.observeSystemAudio(queue: queue) { [weak self] event in self?.handleSystemEvent(event) }
        updateLoudspeaker()
        if them != nil { attemptTap() }
        if me != nil { startMic() }
        if let interval = options.pumpInterval {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.pump() }
            t.resume()
            timer = t
        }
    }

    // MARK: Pump (worker queue)

    /// - Parameter runningTapJobs: false for the final drain in `finish` (no new taps then).
    private func pump(runningTapJobs: Bool = true) {
        guard isRecording else { return }
        let now = env.hostTime()
        let elapsed = max(0, HostClock.seconds(from: lastPumpHost, to: now))
        lastPumpHost = now
        let paused = shared.withLock { $0.isPaused }
        var audible = false
        for track in tracks {
            if process(track, now: now, paused: paused, elapsed: elapsed) { audible = true }
        }
        runWatchdog(now: now)
        if runningTapJobs { runTapJobs(now: now) }
        let levels = AudioLevels(me: me?.meter.level ?? 0, them: them?.meter.level ?? 0)
        let heard = paused || audible
        shared.withLock { s in
            s.levels = paused ? .zero : levels
            if heard { s.lastAudibleHost = now }
        }
        if HostClock.seconds(from: lastAnchorsWrite, to: now) >= options.anchorsWriteInterval {
            writeAnchors()
        }
    }

    /// Returns true if the track carried audible sound in this round.
    private func process(_ track: Track, now: UInt64, paused: Bool, elapsed: Double) -> Bool {
        var audible = false
        var metered = false
        if paused { track.zeroRunStart = nil }          // a run of zeros must not span a pause
        if let ring = track.ring {
            let batch = ring.read()
            if !batch.isEmpty {
                track.lastDeliveryHost = now
                if !paused {
                    if track.channel == .them { checkDigitalSilence(track, batch) }
                    let out = track.converter?.convert(batch.samples) ?? batch.samples
                    let host = batch.firstHostTime ?? now
                    if let rms = write(track, out, firstHostTime: host) {
                        track.meter.add(rms: rms, elapsed: elapsed)
                        metered = true
                        audible = rms > LevelMeter.amplitude(dBFS: options.audibleThresholdDBFS)
                    }
                }
            }
        }
        if !metered { track.meter.decay(elapsed: elapsed) }

        // Keep the file growing in real time while nothing usable arrives.
        let idle = HostClock.seconds(from: max(track.lastDeliveryHost, track.sourceStartHost), to: now)
        if paused || track.ring == nil || idle > options.idlePadSeconds {
            let target = track.timeline.expectedFrame(atHostTime: now) - Int64(options.padHoldbackSeconds * options.sampleRate)
            let from = track.timeline.framesWritten
            let pad = track.timeline.padTo(frame: target)
            if pad > 0 {
                writeSilence(track, frames: pad, at: from, reason: paused ? "pause" : (track.ring == nil ? "noSource" : "gap"))
                track.placeExactly = true
            }
        }
        return audible
    }

    /// Places converted samples on the track's clock. Returns their RMS, nil if nothing was written.
    private func write(_ track: Track, _ samples: [Float], firstHostTime: UInt64) -> Float? {
        guard !samples.isEmpty else { return nil }
        let before = track.timeline.framesWritten
        let placement = track.timeline.place(count: samples.count, firstSampleHostTime: firstHostTime, exact: track.placeExactly)
        track.placeExactly = false
        if placement.padFrames > 0 {
            writeSilence(track, frames: placement.padFrames, at: before,
                         reason: track.deliveredAudio || before > 0 ? "gap" : "start")
        }
        if placement.dropFrames > 0 {
            track.addEdit(.init(kind: .drop, frame: placement.frame, frames: Int64(placement.dropFrames), reason: "drift"))
        }
        guard placement.dropFrames < samples.count else { return nil }
        let rms: Float = samples.withUnsafeBufferPointer { all in
            let kept = UnsafeBufferPointer(rebasing: all[placement.dropFrames...])
            safely(track) { try track.writer.write(kept) }
            return LevelMeter.rms(kept)
        }
        track.deliveredAudio = true
        let anchorDue = placement.padFrames > 0 || placement.dropFrames > 0 || track.anchors.isEmpty
            || placement.frame - track.lastAnchorFrame >= Int64(options.anchorIntervalSeconds * options.sampleRate)
        if anchorDue {
            let host = HostClock.offset(firstHostTime, by: Double(placement.dropFrames) / options.sampleRate)
            track.anchors.append(.init(frame: placement.frame, hostTime: host, seconds: HostClock.seconds(from: startHost, to: host)))
            track.lastAnchorFrame = placement.frame
        }
        return rms
    }

    private func writeSilence(_ track: Track, frames: Int64, at frame: Int64, reason: String) {
        guard frames > 0 else { return }
        safely(track) { try track.writer.writeSilence(frames: frames) }
        track.addEdit(.init(kind: .silence, frame: frame, frames: frames, reason: reason))
    }

    private func safely(_ track: Track, _ body: () throws -> Void) {
        guard !track.writeFailed else { return }
        do {
            try body()
        } catch {
            track.writeFailed = true
            let full = (error as? WAVError)?.isDiskFull ?? false
            KanLog.error("recording \(callID): writing \(track.fileName) failed: \(error)", category: "recorder")
            addIssue(full ? .diskFull : .writeError)
        }
    }

    /// Missing System Audio Recording permission fails silently: the tap delivers exact zeros. So does
    /// a grant made in System Settings while Kan runs (it applies after a relaunch), although TCC
    /// already reports it granted. Only a grant known to reach this process makes a long run of
    /// zeros real silence — and that is checked again after every such run.
    private func checkDigitalSilence(_ track: Track, _ batch: CaptureRing.Batch) {
        var peak: Float = 0
        batch.samples.withUnsafeBufferPointer { b in
            if let base = b.baseAddress { vDSP_maxmgv(base, 1, &peak, vDSP_Length(b.count)) }
        }
        guard peak == 0 else {
            track.zeroRunStart = nil
            return
        }
        let start = batch.firstHostTime ?? lastPumpHost
        if track.zeroRunStart == nil { track.zeroRunStart = start }
        guard !reportedSystemAudioSilence, let runStart = track.zeroRunStart else { return }
        let end = HostClock.offset(start, by: Double(batch.samples.count) / (track.ring?.sampleRate ?? options.sampleRate))
        guard HostClock.seconds(from: runStart, to: end) >= options.systemAudioSilentSeconds else { return }
        let seconds = Int(options.systemAudioSilentSeconds)
        switch env.systemAudioAccess() {
        case .granted:
            if !loggedRealSilence {
                loggedRealSilence = true
                KanLog.info("recording \(callID): \(seconds) s of digital silence from the call app (System Audio Recording reaches Kan: real silence)",
                            category: "recorder")
            }
            track.zeroRunStart = end                    // look again after the next stretch
        case .grantedPendingRelaunch:
            reportedSystemAudioSilence = true
            KanLog.warning("recording \(callID): \(seconds) s of digital silence; System Audio Recording was granted in System Settings after Kan saw it denied and applies after a relaunch",
                           category: "recorder")
            addIssue(.systemAudioSilent)
        case .notGranted:
            reportedSystemAudioSilence = true
            addIssue(.systemAudioSilent)
        }
    }

    private func runWatchdog(now: UInt64) {
        for track in tracks {
            guard let source = track.source, let ring = track.ring else { continue }
            let last = max(ring.stats.lastCallbackHostTime, track.sourceStartHost)
            if HostClock.seconds(from: last, to: now) > options.watchdogSeconds {
                KanLog.warning("recording \(callID): no audio callbacks from \(source.name) for \(String(format: "%.1f", HostClock.seconds(from: last, to: now))) s", category: "recorder")
                track.sourceStartHost = now      // don't fire again before the restart happens
                handleFault(.noCallbacks, from: source)
            }
        }
    }

    // MARK: Sources

    /// Starts `source` and makes it the track's input. A source already feeding the track is drained
    /// and stopped only once the new one runs (make-before-break), so a failed switch loses nothing.
    private func attach(_ source: CaptureSource, to track: Track) throws {
        source.onFault = { [weak self, weak source] fault in
            self?.queue.async { self?.handleFault(fault, from: source) }
        }
        let ring = try source.start()
        let converter: SampleRateConverter
        do {
            converter = try SampleRateConverter(inputRate: ring.sampleRate, inputChannels: 1, outputRate: options.sampleRate)
        } catch {
            source.stop()
            throw error
        }
        if track.source != nil { detach(track) }
        track.source = source
        track.ring = ring
        track.converter = converter
        track.placeExactly = true
        track.sourceStartHost = env.hostTime()
        track.lastDeliveryHost = track.sourceStartHost
        track.sources.append(.init(name: source.name, sampleRate: ring.sampleRate, startFrame: track.timeline.framesWritten))
    }

    /// Drains the ring, stops the source and writes the converter's tail.
    private func detach(_ track: Track) {
        guard let source = track.source else { return }
        let paused = shared.withLock { $0.isPaused }
        drain(track, paused: paused)
        source.stop()
        drain(track, paused: paused)
        if let tail = track.converter?.flush(), !tail.isEmpty, !paused {
            safely(track) { try track.writer.write(tail) }
            track.timeline.appendContiguous(tail.count)
        }
        track.source = nil
        track.ring = nil
        track.converter = nil
    }

    private func drain(_ track: Track, paused: Bool) {
        guard let ring = track.ring else { return }
        let batch = ring.read()
        guard !batch.isEmpty, !paused else { return }
        if track.channel == .them { checkDigitalSilence(track, batch) }
        let out = track.converter?.convert(batch.samples) ?? batch.samples
        _ = write(track, out, firstHostTime: batch.firstHostTime ?? env.hostTime())
    }

    private func handleFault(_ fault: CaptureFault, from source: CaptureSource?) {
        guard isRecording, let source else { return }
        if let them, them.source === source {
            rebuildTap(reason: fault.description)
        } else if let me, me.source === source {
            scheduleMicRestart(reason: fault.description)
        }
    }

    private func handleSystemEvent(_ event: SystemAudioEvent) {
        guard isRecording else { return }
        switch event {
        case .defaultInputChanged:
            // A call app that follows the default moves too; `retarget` reports that (and a mic
            // picked in the app itself, which changes no default).
            guard let me else { return }
            if me.source == nil {
                startMic()
            } else if micChoice?.followsDefault == true, let uid = env.defaultInputUID(), uid != micChoice?.uid {
                scheduleMicRestart(reason: "default input changed")
            }
        case .defaultOutputChanged:
            updateLoudspeaker()
        case .devicesChanged:
            if let me, me.source == nil { startMic() }
            updateLoudspeaker()
        case .serviceRestarted:
            // Every tap, aggregate, device and process object id is now invalid.
            KanLog.warning("recording \(callID): coreaudiod restarted", category: "recorder")
            if them != nil { rebuildTap(reason: "service restarted") }
            if me != nil { scheduleMicRestart(reason: "service restarted") }
        }
    }

    // MARK: Tap
    //
    // The "them" track wants the call app's tap (`appTarget`), or all system audio for a
    // `.systemAudio` request, and keeps trying for as long as the recording runs:
    // * a fault → full teardown now, a new tap after `rebuildDebounceSeconds` (coalesces the burst
    //   of HAL notifications one event causes);
    // * a start that fails → quick retries (`retryDelaysSeconds`), then the next fallback: the call
    //   app's tap → all system audio → no call audio for now (`.tapFailed`), with a new round every
    //   `tapRecoverySeconds`;
    // * while all system audio stands in, the call app's tap is tried every `tapRecoverySeconds`
    //   (and at once when its processes change); the system tap keeps recording until it runs;
    // * every tap creation after the first counts against `maxRebuildsPerMinute`: a used-up budget
    //   delays the next attempt instead of ending recovery.
    // Scheduled attempts run on the host clock, from the pump.

    private func isUsable(_ target: TapTarget) -> Bool {
        if !target.processObjectIDs.isEmpty { return true }
        if #available(macOS 26.0, *) { return !target.bundleIDs.isEmpty }
        return false
    }

    /// What the next tap captures: the call app, unless all system audio stands in for it.
    private func plannedTapTarget() -> TapTarget {
        if !onSystemFallback, let appTarget { return appTarget }
        return .systemAudio(excluding: env.ownProcessObjectID())
    }

    private func scheduleTap(_ job: TapJob, after seconds: Double) {
        let due = HostClock.offset(env.hostTime(), by: max(0, seconds))
        switch job {
        case .start: tapStartDue = min(tapStartDue ?? due, due)
        case .returnToApp: tapReturnDue = min(tapReturnDue ?? due, due)
        }
    }

    private func runTapJobs(now: UInt64) {
        if let due = tapStartDue, now >= due {
            tapStartDue = nil
            attemptTap()
        }
        if let due = tapReturnDue, now >= due {
            tapReturnDue = nil
            returnToAppTap()
        }
    }

    /// Takes one tap creation from the budget, or schedules `job` for when one is available.
    private func spendTapBudget(for job: TapJob) -> Bool {
        let now = HostClock.seconds(env.hostTime())
        if tapLimiter.allow(at: now) { return true }
        let wait = tapLimiter.delay(at: now)
        KanLog.warning("recording \(callID): tap restart budget used up; next try in \(String(format: "%.1f", wait)) s",
                       category: "recorder")
        scheduleTap(job, after: wait)
        return false
    }

    /// Full teardown now, recreation after the debounce — the only recovery reported to work reliably.
    private func rebuildTap(reason: String) {
        guard isRecording, let them else { return }
        KanLog.info("recording \(callID): rebuilding tap (\(reason))", category: "recorder")
        detach(them)
        tapReturnDue = nil              // the start that follows schedules the next return
        scheduleTap(.start, after: options.rebuildDebounceSeconds)
    }

    /// Starts a tap on the planned target while none runs; a failure moves down the fallbacks.
    private func attemptTap() {
        guard isRecording, let them, them.source == nil else { return }
        tapStartDue = nil
        if tapStartsAttempted > 0 {
            guard spendTapBudget(for: .start) else { return }
            reresolveTapTarget()
        }
        tapStartsAttempted += 1
        if !onSystemFallback, let target = appTarget, !isUsable(target) {
            KanLog.warning("recording \(callID): the call app has no tappable processes; recording all system audio until it has",
                           category: "recorder")
            onSystemFallback = true
        }
        let target = plannedTapTarget()
        do {
            try attach(try env.makeTapSource(target), to: them)
        } catch {
            KanLog.warning("recording \(callID): tap (\(target)) failed to start: \(error)", category: "recorder")
            tapStartFailed()
            return
        }
        tapRetry = 0
        if tapRecovering {
            tapRecovering = false
            KanLog.info("recording \(callID): call audio is back (\(target))", category: "recorder")
        }
        if tapEverStarted { addIssue(.tapRebuilt) }
        tapEverStarted = true
        if onSystemFallback {
            if appTarget != nil { addIssue(.systemAudioFallback) }   // other apps' sounds may be included
            scheduleTap(.returnToApp, after: options.tapRecoverySeconds)
        }
    }

    private func tapStartFailed() {
        if !tapRecovering, tapRetry < options.retryDelaysSeconds.count {
            let delay = options.retryDelaysSeconds[tapRetry]
            tapRetry += 1
            scheduleTap(.start, after: delay)
            return
        }
        tapRetry = 0
        if appTarget != nil, !onSystemFallback {
            onSystemFallback = true
            KanLog.warning("recording \(callID): the call app's tap won't start; recording all system audio until it does",
                           category: "recorder")
            attemptTap()
            return
        }
        // Nothing starts: the other side isn't being recorded (only now is that `.tapFailed`).
        if !tapRecovering {
            tapRecovering = true
            KanLog.warning("recording \(callID): no call audio; recording the microphone only and trying again every "
                           + "\(String(format: "%.0f", options.tapRecoverySeconds)) s", category: "recorder")
            addIssue(.tapFailed)
        }
        onSystemFallback = false        // each round tries the call app's tap first
        scheduleTap(.start, after: options.tapRecoverySeconds)
    }

    /// While all system audio stands in: tries the call app's tap again.
    private func returnToAppTap() {
        guard isRecording, onSystemFallback, let them, them.source != nil, appTarget != nil else { return }
        tapReturnDue = nil
        reresolveTapTarget()
        guard let target = appTarget, isUsable(target) else {
            scheduleTap(.returnToApp, after: options.tapRecoverySeconds)
            return
        }
        guard spendTapBudget(for: .returnToApp) else { return }
        do {
            try attach(try env.makeTapSource(target), to: them)
        } catch {
            KanLog.info("recording \(callID): the call app's tap still won't start (\(error)); staying on all system audio",
                        category: "recorder")
            scheduleTap(.returnToApp, after: options.tapRecoverySeconds)
            return
        }
        onSystemFallback = false
        tapRetry = 0
        KanLog.info("recording \(callID): back on the call app's tap (\(target))", category: "recorder")
    }

    /// After a coreaudiod restart (or a failed start) the process object ids may have changed.
    private func reresolveTapTarget() {
        guard var target = appTarget, let activity else { return }
        let resolved = env.resolveProcessObjects(pids: activity.pids, bundleIDs: target.bundleIDs).sorted()
        guard !resolved.isEmpty, resolved != target.processObjectIDs else { return }
        target.processObjectIDs = resolved
        appTarget = target
        KanLog.info("recording \(callID): tap target re-resolved to \(resolved)", category: "recorder")
    }

    /// The call app changed (process set, devices): the tap, the microphone and the loudspeaker
    /// check follow it. Recordings of all system audio or mic only don't follow any app.
    private func applyRetarget(_ newActivity: AppActivity) {
        guard isRecording, activity != nil else { return }
        activity = newActivity
        updateLoudspeaker()
        followCallAppMicrophone()
        retargetTap(TapTarget.app(newActivity))
    }

    private func retargetTap(_ target: TapTarget) {
        guard let current = appTarget, target != current, let them else { return }
        appTarget = target
        if !onSystemFallback, let source = them.source {
            do {
                try source.retarget(target)
            } catch let error as CoreAudioError where error.isPermissionError {
                KanLog.warning("recording \(callID): tap retarget refused ('!hog'): System Audio Recording permission missing", category: "recorder")
                addIssue(.systemAudioSilent)
                rebuildTap(reason: "retarget refused")
            } catch {
                KanLog.warning("recording \(callID): tap retarget failed: \(error)", category: "recorder")
                rebuildTap(reason: "retarget failed")
            }
        } else if onSystemFallback, them.source != nil {
            scheduleTap(.returnToApp, after: 0)     // the new processes may make the app's tap work
        } else {
            onSystemFallback = false                // nothing runs: try the app's new processes first
            tapRetry = 0
            scheduleTap(.start, after: 0)
        }
    }

    // MARK: Microphone

    /// The call app's current microphones first (they change when AirPods connect or a mic is picked
    /// in the app), then the one requested at the start.
    private func preferredInputUIDs() -> [String] {
        (activity?.inputDeviceUIDs ?? []) + [request.preferredInputDeviceUID].compactMap { $0 }
    }

    /// The call app records from another physical microphone now: so does "me". While the app's
    /// microphone is unknown (it released it, or uses only a virtual device) the current one stays.
    private func followCallAppMicrophone() {
        guard me != nil, let current = micChoice,
              let appMic = MicrophoneSelector.firstPhysicalInput(among: activity?.inputDeviceUIDs ?? [], devices: env.devices()),
              appMic != current.uid else { return }
        scheduleMicRestart(reason: "the call app switched to another microphone")
    }

    private func startMic() {
        guard isRecording, let me, me.source == nil else { return }
        if env.microphonePermission() == .denied {
            addIssue(.micPermissionDenied)
            return
        }
        guard let choice = MicrophoneSelector.choose(preferredUIDs: preferredInputUIDs(), devices: env.devices(),
                                                     defaultInputUID: env.defaultInputUID()) else {
            KanLog.warning("recording \(callID): no microphone available", category: "recorder")
            addIssue(.micUnavailable)
            scheduleMicRetry()
            return
        }
        do {
            let source = try env.makeMicrophoneSource(deviceUID: choice.uid)
            try attach(source, to: me)
            if let previous = micChoice, previous.uid != choice.uid { addIssue(.deviceChanged) }
            micChoice = choice
        } catch {
            KanLog.warning("recording \(callID): microphone \(choice.uid) failed to start: \(error)", category: "recorder")
            addIssue(.micUnavailable)
            scheduleMicRetry()
        }
    }

    private func scheduleMicRetry() {
        guard !micRetryScheduled else { return }
        micRetryScheduled = true
        schedule(after: options.microphoneRetrySeconds) { [weak self] in
            guard let self else { return }
            self.micRetryScheduled = false
            if let me = self.me, me.source == nil { self.startMic() }
        }
    }

    private func scheduleMicRestart(reason: String) {
        guard !micRestartPending else { return }
        micRestartPending = true
        schedule(after: options.rebuildDebounceSeconds) { [weak self] in self?.restartMic(reason: reason) }
    }

    private func restartMic(reason: String) {
        micRestartPending = false
        guard isRecording, let me else { return }
        KanLog.info("recording \(callID): restarting microphone (\(reason))", category: "recorder")
        detach(me)
        guard micLimiter.allow(at: HostClock.seconds(env.hostTime())) else {
            KanLog.warning("recording \(callID): microphone restart budget exhausted", category: "recorder")
            addIssue(.micUnavailable)
            scheduleMicRetry()
            return
        }
        startMic()
    }

    // MARK: Loudspeaker

    private func updateLoudspeaker() {
        guard them != nil, !loudspeakerSuspected else { return }
        if LoudspeakerClassifier.isLoudspeakerSuspected(outputUIDs: activity?.outputDeviceUIDs ?? [], devices: env.devices(),
                                                        defaultOutputUID: env.defaultOutputUID()) {
            loudspeakerSuspected = true
            KanLog.info("recording \(callID): call audio plays through a loudspeaker (echo expected)", category: "recorder")
        }
    }

    // MARK: Stop / discard

    private func finish(trimEndAt: Date?) -> RecordingResult {
        switch lifecycle {
        case .stopped(let result): return result
        case .discarded: return emptyResult()
        case .recording: break
        }
        let stopHost = env.hostTime()
        let stopDate = env.wallClock()
        timer?.cancel()
        timer = nil
        pump(runningTapJobs: false)
        for track in tracks { detach(track) }
        systemObserver = nil

        let rate = options.sampleRate
        let endFrame = max(0, Int64((HostClock.seconds(from: startHost, to: stopHost) * rate).rounded()))
        var finalFrames = endFrame
        var endedAt = stopDate
        if let trim = trimEndAt {
            // `trim` is wall-clock time; the tracks run on host time, which stops while the Mac
            // sleeps. Measured back from the stop, a sleep between `trim` and the stop (a stop
            // requested at sleep that only runs after the wake) would cut the whole call; measured
            // from the start it can't, as a detected call never spans a sleep. The later of the two
            // wins: a clock disagreement keeps audio rather than losing it.
            let fromStop = endFrame - Int64((stopDate.timeIntervalSince(trim) * rate).rounded())
            let fromStart = Int64((trim.timeIntervalSince(startedAt) * rate).rounded())
            finalFrames = min(max(0, fromStop, fromStart), endFrame)
            endedAt = min(stopDate, startedAt.addingTimeInterval(Double(finalFrames) / rate))
        }
        var kept: [AudioChannel: URL] = [:]
        for track in tracks {
            let writer = track.writer
            if writer.frameCount < endFrame {
                let from = writer.frameCount
                safely(track) { try writer.writeSilence(frames: endFrame - from) }
                track.addEdit(.init(kind: .silence, frame: from, frames: endFrame - from, reason: "stop"))
            }
            if writer.frameCount > finalFrames {
                let cut = writer.frameCount - finalFrames
                safely(track) { try writer.truncate(toFrames: finalFrames) }
                if finalFrames < endFrame { track.addEdit(.init(kind: .drop, frame: finalFrames, frames: cut, reason: "trim")) }
            }
            track.timeline.truncate(to: finalFrames)
            track.anchors.removeAll { $0.frame >= finalFrames && $0.frame > 0 }
            do { try writer.close() } catch {
                KanLog.error("recording \(callID): closing \(track.fileName) failed: \(error)", category: "recorder")
                addIssue((error as? WAVError)?.isDiskFull == true ? .diskFull : .writeError)
            }
            if track.deliveredAudio {
                kept[track.channel] = track.url
            } else {
                // The source never delivered anything (permission denied, no device, tap failed).
                try? FileManager.default.removeItem(at: track.url)
                KanLog.info("recording \(callID): no audio captured for \(track.fileName); file removed", category: "recorder")
            }
        }
        let anchorsURL = writeAnchors()
        let seconds = Double(finalFrames) / rate
        let result = RecordingResult(
            callID: callID, directory: directory, meFile: kept[.me], themFile: kept[.them], anchorsFile: anchorsURL,
            startedAt: startedAt, endedAt: endedAt,
            meSeconds: kept[.me] != nil ? seconds : 0, themSeconds: kept[.them] != nil ? seconds : 0,
            loudspeakerSuspected: loudspeakerSuspected, issues: issues)
        let sessionURL = directory.appendingPathComponent(KanPaths.CallFile.session)
        do {
            try JSONEncoder.kanPretty.encode(result).write(to: sessionURL, options: .atomic)
            noteCreated(sessionURL)
        } catch {
            KanLog.error("recording \(callID): writing session.json failed: \(error)", category: "recorder")
        }
        lifecycle = .stopped(result)
        shared.withLock { $0.levels = .zero }
        KanLog.info("recording \(callID) stopped: \(String(format: "%.1f", seconds)) s, me \(kept[.me] != nil), them \(kept[.them] != nil), issues \(result.issues.map(\.rawValue))", category: "recorder")
        return result
    }

    private func discardNow() {
        if case .discarded = lifecycle { return }
        timer?.cancel()
        timer = nil
        systemObserver = nil
        for track in tracks {
            track.source?.stop()
            track.source = nil
            track.ring = nil
            try? track.writer.close()
        }
        let fm = FileManager.default
        for url in createdFiles { try? fm.removeItem(at: url) }
        if createdDirectory, (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fm.removeItem(at: directory)
        }
        lifecycle = .discarded
        shared.withLock { $0.levels = .zero }
        KanLog.info("recording \(callID) discarded", category: "recorder")
    }

    private func emptyResult() -> RecordingResult {
        RecordingResult(callID: callID, directory: directory, meFile: nil, themFile: nil, anchorsFile: nil,
                        startedAt: startedAt, endedAt: startedAt, meSeconds: 0, themSeconds: 0,
                        loudspeakerSuspected: loudspeakerSuspected, issues: issues)
    }

    @discardableResult
    private func writeAnchors() -> URL? {
        lastAnchorsWrite = env.hostTime()
        let anchors = RecordingAnchors(sampleRate: options.sampleRate, startedAt: startedAt, startHostTime: startHost,
                                       me: me.map { $0.snapshot() }, them: them.map { $0.snapshot() })
        let url = directory.appendingPathComponent(KanPaths.CallFile.anchors)
        do {
            try JSONEncoder.kanPretty.encode(anchors).write(to: url, options: .atomic)
            noteCreated(url)
            return url
        } catch {
            KanLog.error("recording \(callID): writing anchors.json failed: \(error)", category: "recorder")
            return nil
        }
    }

    // MARK: Helpers

    private var isRecording: Bool {
        if case .recording = lifecycle { return true }
        return false
    }

    private var tracks: [Track] { [me, them].compactMap { $0 } }

    private func makeTrack(_ channel: AudioChannel, file: String) throws -> Track {
        let url = directory.appendingPathComponent(file)
        let writer: WAVWriter
        do {
            writer = try WAVWriter(url: url, sampleRate: Int(options.sampleRate), channels: 1,
                                   headerUpdateInterval: options.headerUpdateInterval)
        } catch {
            throw RecorderError.cannotCreate(url, "\(error)")
        }
        noteCreated(url)
        let timeline = TrackTimeline(sampleRate: options.sampleRate, startHostTime: startHost,
                                     toleranceSeconds: options.driftToleranceSeconds)
        return Track(channel: channel, fileName: file, url: url, writer: writer, timeline: timeline, startHost: startHost)
    }

    private func noteCreated(_ url: URL) {
        if !createdFiles.contains(url) { createdFiles.append(url) }
    }

    private func addIssue(_ issue: RecordingIssue) {
        let handler = shared.withLock { s -> (@Sendable (RecordingIssue) -> Void)?? in
            guard !s.issues.contains(issue) else { return nil }
            s.issues.append(issue)
            return .some(s.onIssue)
        }
        guard let handler else { return }
        KanLog.warning("recording \(callID): issue \(issue.rawValue)", category: "recorder")
        handler?(issue)
    }

    private func schedule(after delay: Double, _ work: @escaping () -> Void) {
        if delay <= 0 { queue.async(execute: work) } else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }

    private func describe(_ target: CaptureTarget) -> String {
        switch target {
        case .app(let a): return "app \(a.app.bundleID) \(a.processObjectIDs)"
        case .systemAudio: return "system audio"
        case .micOnly: return "mic only"
        }
    }
}

/// One output track (worker-confined).
final class Track {
    let channel: AudioChannel
    let fileName: String
    let url: URL
    let writer: WAVWriter
    var timeline: TrackTimeline
    var source: CaptureSource?
    var ring: CaptureRing?
    var converter: SampleRateConverter?
    var sourceStartHost: UInt64
    var lastDeliveryHost: UInt64
    var deliveredAudio = false
    var writeFailed = false
    /// The next audio starts a new stream (or follows real-time padding): place it exactly.
    var placeExactly = true
    var meter = LevelMeter()
    var anchors: [RecordingAnchors.Anchor] = []
    var edits: [RecordingAnchors.Edit] = []
    var sources: [RecordingAnchors.Source] = []
    var lastAnchorFrame: Int64 = Int64.min / 2
    var zeroRunStart: UInt64?

    init(channel: AudioChannel, fileName: String, url: URL, writer: WAVWriter, timeline: TrackTimeline, startHost: UInt64) {
        self.channel = channel
        self.fileName = fileName
        self.url = url
        self.writer = writer
        self.timeline = timeline
        self.sourceStartHost = startHost
        self.lastDeliveryHost = startHost
    }

    /// Records an edit, merging with the previous one when it simply continues it.
    func addEdit(_ edit: RecordingAnchors.Edit) {
        if var last = edits.last, last.kind == edit.kind, last.reason == edit.reason,
           last.frame + (edit.kind == .silence ? last.frames : 0) == edit.frame {
            last.frames += edit.frames
            edits[edits.count - 1] = last
        } else {
            edits.append(edit)
        }
    }

    func snapshot() -> RecordingAnchors.Track {
        RecordingAnchors.Track(file: fileName, frames: writer.frameCount, sources: sources, anchors: anchors, edits: edits)
    }
}

/// Starts recordings. Implements `CallRecording`.
///
/// Thread-safe. Each `start` returns an independent `RecordingSession`.
public final class CallRecorder: CallRecording, @unchecked Sendable {
    public let environment: RecordingEnvironment
    public let options: RecordingOptions

    public init(environment: RecordingEnvironment = LiveRecordingEnvironment(), options: RecordingOptions = RecordingOptions()) {
        self.environment = environment
        self.options = options
    }

    /// Creates the call directory and both WAVs, then starts capture in the background. Throws only
    /// when nothing can be recorded at all (no space, unwritable directory, mic-only without
    /// microphone access); every other problem is reported through `RecordingHandle.issues`.
    public func start(_ request: RecordingRequest) throws -> RecordingHandle {
        try RecordingSession(request: request, environment: environment, options: options)
    }
}
