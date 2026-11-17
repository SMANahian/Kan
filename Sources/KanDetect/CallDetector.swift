import AppKit
import Foundation
import KanCore

/// Watches which apps use the microphone and turns that into call events. Implements `CallDetecting`.
///
/// The `AudioClientMonitor` (listeners + 1 s poll) feeds a `CallStateMachine` on a private serial
/// queue; a 1 s tick handles deadlines; NSWorkspace sleep / wake / app-termination notifications end,
/// hold or re-evaluate calls promptly. Browser calls are probed for meeting info at start and then
/// every `probeInterval` until something is found.
///
/// Thread-safety: all methods may be called from any thread. Events are delivered in order on the
/// main queue (main actor).
public final class CallDetector: CallDetecting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nahian.Kan.detector", qos: .userInitiated)
    private let probeQueue = DispatchQueue(label: "com.nahian.Kan.detector.probe", qos: .utility)
    private let monitor: AudioClientMonitoring
    private let meetingProbe: MeetingProbing?
    private let clock: @Sendable () -> Date
    private let tickInterval: TimeInterval
    private let probeInterval: TimeInterval

    // Confined to `queue`.
    private var machine: CallStateMachine
    private var running = false
    private var tickTimer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var probing: Set<UUID> = []

    // Guarded by `lock`.
    private let lock = NSLock()
    private var handler: (@MainActor (DetectionEvent) -> Void)?
    private var latestActivities: [AppActivity]?

    /// - Parameters:
    ///   - meetingProbe: nil disables browser meeting naming (no AppleScript / Accessibility at all).
    ///   - clock: injectable for tests.
    public init(config: DetectionConfig = DetectionConfig(), monitor: AudioClientMonitoring = AudioClientMonitor(),
                meetingProbe: MeetingProbing? = BrowserMeetingProbe(), tickInterval: TimeInterval = 1,
                probeInterval: TimeInterval = 30, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.machine = CallStateMachine(config: config)
        self.monitor = monitor
        self.meetingProbe = meetingProbe
        self.tickInterval = tickInterval
        self.probeInterval = probeInterval
        self.clock = clock
    }

    deinit {
        tickTimer?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
    }

    public var onEvent: (@MainActor (DetectionEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            monitor.startObserving(queue: queue) { [weak self] in self?.evaluate() }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in
                guard let self, self.running else { return }
                self.deliver(self.machine.tick(now: self.clock()))
            }
            t.resume()
            tickTimer = t
            observeWorkspace()
            KanLog.info("call detection started", category: "detect")
            evaluate()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            monitor.stopObserving()
            tickTimer?.cancel()
            tickTimer = nil
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.forEach { center.removeObserver($0) }
            workspaceObservers.removeAll()
            KanLog.info("call detection stopped", category: "detect")
        }
    }

    public func update(config: DetectionConfig) {
        queue.async { [self] in
            machine.updateConfig(config)
            if running { evaluate() }
        }
    }

    public func respond(_ response: UserCallResponse, to callID: UUID) {
        queue.async { [self] in
            KanLog.info("user response \(response) for call \(callID)", category: "detect")
            deliver(machine.respond(response, callID: callID, now: clock()))
        }
    }

    public func reportSilence(seconds: TimeInterval, for callID: UUID) {
        queue.async { [self] in deliver(machine.reportSilence(seconds: seconds, callID: callID, now: clock())) }
    }

    public func beginManualSession(_ call: DetectedCall) {
        queue.async { [self] in
            KanLog.info("manual session \(call.id) for \(call.app.bundleID)", category: "detect")
            deliver(machine.beginManualSession(call, now: clock()))
        }
    }

    public func endManualSession(_ callID: UUID) {
        queue.async { [self] in deliver(machine.endManualSession(callID, now: clock())) }
    }

    public func currentActivities() -> [AppActivity] {
        if let cached = lock.withLock({ latestActivities }) { return cached }
        return monitor.activities() ?? []
    }

    /// The state machine's view (diagnostics, tests). Blocks briefly; don't call from event handlers
    /// that run on the detector queue.
    public var currentSession: CallStateMachine.Session? { queue.sync { machine.session } }

    // MARK: Evaluation (detector queue)

    private func evaluate() {
        guard running else { return }
        // Skip the round rather than act on an empty list when Core Audio can't be read.
        guard var activities = monitor.activities() else { return }
        lock.withLock { latestActivities = activities }
        // A call app that still runs but momentarily has no Core Audio clients (coreaudiod or helper
        // restart) has released the mic — it has not quit.
        if let s = machine.session, !s.call.isManual,
           !activities.contains(where: { $0.app.bundleID == s.call.app.bundleID }),
           monitor.isProcessAlive(s.call.app.pid) {
            activities.append(AppActivity(app: s.call.app, category: s.call.category, micActive: false, outputActive: false))
        }
        deliver(machine.update(activities: activities, now: clock()))
    }

    private func deliver(_ events: [DetectionEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            KanLog.info("detection: \(CallDetector.describe(event))", category: "detect")
            switch event {
            case .started(let call), .ask(let call):
                if call.category == .browser { startProbing(call) }
            default:
                break
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onEvent else { return }
            MainActor.assumeIsolated {
                for event in events { handler(event) }
            }
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.running else { return }
                self.deliver(self.machine.systemWillSleep(now: self.clock()))
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.running else { return }
                self.machine.systemDidWake()
                self.evaluate()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                     queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            self?.queue.async {
                guard let self, self.running else { return }
                if let bundleID { self.machine.appTerminated(bundleID: bundleID) }
                self.evaluate()
            }
        })
    }

    // MARK: Meeting probe

    private func startProbing(_ call: DetectedCall) {
        guard meetingProbe != nil, !probing.contains(call.id) else { return }
        probing.insert(call.id)
        runProbe(call)
    }

    private func runProbe(_ call: DetectedCall) {
        guard let probe = meetingProbe else { return }
        let app = call.app
        probeQueue.async { [weak self] in
            let info = probe.probe(app: app)
            self?.queue.async {
                guard let self else { return }
                guard self.running, self.machine.session?.call.id == call.id else {
                    self.probing.remove(call.id)
                    return
                }
                if let info {
                    self.probing.remove(call.id)
                    self.deliver(self.machine.setMeetingInfo(info, callID: call.id))
                } else {
                    self.queue.asyncAfter(deadline: .now() + self.probeInterval) { [weak self] in
                        guard let self, self.running, self.machine.session?.call.id == call.id else {
                            self?.probing.remove(call.id)
                            return
                        }
                        self.runProbe(call)
                    }
                }
            }
        }
    }

    // MARK: Logging

    public static func describe(_ event: DetectionEvent) -> String {
        func c(_ call: DetectedCall) -> String { "\(call.app.name) [\(call.app.bundleID)] \(call.id.uuidString.prefix(8))" }
        switch event {
        case .started(let call): return "started \(c(call)) since \(KanDate.iso8601(call.startedAt))"
        case .ask(let call): return "ask \(c(call)) since \(KanDate.iso8601(call.startedAt))"
        case .meetingInfo(let call):
            // Never the title or URL themselves: the log outlives the call.
            return "meeting info \(c(call)): \(call.platform.rawValue), title \(call.meeting?.title == nil ? "no" : "yes"), "
                + "url \(call.meeting?.url == nil ? "no" : "yes")"
        case .activityChanged(let call, let activity):
            return "activity changed \(c(call)): objects \(activity.processObjectIDs) in \(activity.inputDeviceUIDs) out \(activity.outputDeviceUIDs)"
        case .ending(let call, let deadline): return "ending \(c(call)) at \(KanDate.iso8601(deadline))"
        case .resumed(let call): return "resumed \(c(call))"
        case .ended(let call, let endedAt): return "ended \(c(call)) at \(KanDate.iso8601(endedAt))"
        case .stale(let call): return "stale \(c(call))"
        }
    }
}
