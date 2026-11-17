import Foundation
import KanCore

/// The call start/end rules as a pure value type: snapshots of app audio activity, the time, the
/// user's answers and silence reports go in; `DetectionEvent`s come out. No Core Audio, no clocks,
/// no queues — `CallDetector` feeds it.
///
/// Rules:
/// * **Start**: an app holds the mic for `startConfirmSeconds`; `DetectedCall.startedAt` is when it
///   took the mic. When `messagingRequiresOutput`, apps whose mic use may be a recorded message must
///   also be playing audio: messaging apps (voice notes) and the meeting apps that record clips
///   (`KnownApp.requiresOutput`: Slack, Teams, Element). A call's playout stream runs all along;
///   recording a message plays nothing. Policy `.auto` → `.started`, `.ask` → `.ask` (tentative),
///   `.never` → nothing. Detection disabled or paused → nothing; an app that holds the mic while
///   detection is off is ignored for the rest of that call (see *Ignored apps*), so un-pausing
///   mid-call doesn't start a recording halfway through. Ongoing calls are never killed by a config
///   change.
/// * **One call at a time**: other apps are ignored while a session exists — except that a call
///   which is already ending gives way to an `.auto` app that now holds the mic (back-to-back calls).
///   An app still holding the mic when the session ends can start right after (`startedAt` is then
///   not earlier than that end).
/// * **End**: mic released (debounced by `releaseDebounceSeconds`) → `.ending(deadline: release +
///   grace)`, browser grace for browsers → `.ended(endedAt: release)` at the deadline; mic back first →
///   `.resumed`. The app disappearing from the activity list (quit/crash) → `.ended` at once. A muted
///   app that keeps its mic stream open never ends.
/// * **Sleep**: `systemWillSleep` ends detected calls at once and nothing starts until
///   `systemDidWake` (or `sleepHoldSeconds` later, should the wake never be reported). An app that
///   holds the mic after the wake goes through the confirm window again and starts a new call: the
///   call reconnected, and the user didn't decline anything.
/// * **Stale**: reported silence ≥ `staleSilenceSeconds` → `.stale`, once; again only after audio returned.
/// * **Manual sessions**: never auto-ended (mic release, quit, sleep); stale still applies;
///   `endManualSession` ends them.
/// * **Answers**: `.record` confirms a tentative session; `.notNow` / `.never` drop it and ignore the
///   app for the rest of that call; `.keepRecording` cancels `.ending` until the mic returns (normal
///   rules then resume); `.endNow` ends now. A session ended by the user (`.endNow`,
///   `endManualSession`) while its app still holds the mic is not restarted for the rest of that call
///   either.
/// * **Ignored apps**: the ignored call is over once the app has kept the mic released for its end
///   grace — as a recorded call would end — or has quit (`appTerminated`). Until then the app can't
///   start a session: a device switch mid-call (AirPods, another mic in the app) restarts its input
///   with a gap of a second or more, which must not record the call the user declined or stopped.
/// * `.activityChanged` whenever the session app's process objects or its input / output devices
///   change (the recorder retargets the tap and follows the app's microphone).
///
/// Every session that emitted `.started` / `.ask` (or was registered manually) ends with exactly one
/// `.ended`, except sessions dropped by `.notNow` / `.never`.
public struct CallStateMachine: Sendable {
    public struct Session: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case active
            /// Mic released at `releasedAt`; the call ends at `deadline` unless it comes back.
            case ending(releasedAt: Date, deadline: Date)
            /// "Keep recording" during `.ending`: no deadline until the mic returns.
            case held
        }

        public fileprivate(set) var call: DetectedCall
        /// `.ask`ed and not answered yet.
        public fileprivate(set) var isTentative: Bool
        public fileprivate(set) var phase: Phase
        public fileprivate(set) var processObjectIDs: Set<UInt32>
        /// The app's devices as last reported in `.activityChanged` (or at the start).
        public fileprivate(set) var inputDeviceUIDs: [String] = []
        public fileprivate(set) var outputDeviceUIDs: [String] = []
        public fileprivate(set) var staleNotified: Bool
        fileprivate var releaseSeenAt: Date?
    }

    /// The mic must stay released this long before `.ending` (absorbs device switches and the
    /// brief IO restarts call apps do when the route changes).
    public static let releaseDebounceSeconds: TimeInterval = 1

    /// Longest wait for `systemDidWake` after `systemWillSleep` before starts are allowed again (the
    /// Mac may not go to sleep after all).
    public static let sleepHoldSeconds: TimeInterval = 30

    public private(set) var config: DetectionConfig
    public private(set) var session: Session?

    /// An app ignored for the rest of its current call.
    private struct Suppression: Sendable {
        /// Decides the end grace after which the ignored call counts as over.
        var category: AppCategory
        /// Since when the app has been seen without the mic (nil while it holds it).
        var releasedSince: Date?
    }

    private var micSince: [String: Date] = [:]
    private var suppressed: [String: Suppression] = [:]
    private var lastActivities: [String: AppActivity] = [:]
    private var lastSessionEndedAt: Date?
    private var asleepSince: Date?

    public init(config: DetectionConfig = DetectionConfig()) {
        self.config = config
    }

    public var currentCall: DetectedCall? { session?.call }

    /// True while an app is being ignored for the rest of its current call.
    public func isSuppressed(_ bundleID: String) -> Bool { suppressed[bundleID] != nil }

    public func isDetectionActive(at now: Date) -> Bool {
        guard config.enabled else { return false }
        if let until = config.pausedUntil, until > now { return false }
        return true
    }

    // MARK: Inputs

    public mutating func updateConfig(_ config: DetectionConfig) {
        self.config = config
    }

    /// A fresh activity snapshot. Also processes deadlines.
    public mutating func update(activities: [AppActivity], now: Date) -> [DetectionEvent] {
        var events: [DetectionEvent] = []
        var byID: [String: AppActivity] = [:]
        for activity in activities where byID[activity.app.bundleID] == nil {
            byID[activity.app.bundleID] = activity
        }
        lastActivities = byID
        let asleep = isAsleep(at: now)

        // An ignored app's call is over once the app has kept the mic released for its end grace.
        // Having no audio clients at all counts as a release (a helper or coreaudiod restarting
        // looks the same as a quit; `appTerminated` reports real quits).
        for (id, s) in suppressed {
            var s = s
            if let activity = byID[id], activity.micActive {
                s.releasedSince = nil
            } else {
                let since = s.releasedSince ?? now
                if now.timeIntervalSince(since) >= grace(for: s.category) {
                    suppressed[id] = nil
                    continue
                }
                s.releasedSince = since
            }
            suppressed[id] = s
        }

        // How long each app has held the mic. Ignored apps don't count, and nothing is counted
        // between `systemWillSleep` and the wake: confirm windows start again afterwards.
        for (id, activity) in byID {
            if activity.micActive, suppressed[id] == nil, !asleep {
                if micSince[id] == nil { micSince[id] = now }
            } else {
                micSince[id] = nil
            }
        }
        for id in micSince.keys where byID[id] == nil { micSince[id] = nil }

        if var s = session {
            let id = s.call.app.bundleID
            if let activity = byID[id] {
                let objects = Set(activity.processObjectIDs)
                // An empty object list is the detector's stand-in for a running app without audio
                // clients: it says nothing about the app's processes or devices.
                if !objects.isEmpty, objects != s.processObjectIDs || activity.inputDeviceUIDs != s.inputDeviceUIDs
                    || activity.outputDeviceUIDs != s.outputDeviceUIDs {
                    s.processObjectIDs = objects
                    s.inputDeviceUIDs = activity.inputDeviceUIDs
                    s.outputDeviceUIDs = activity.outputDeviceUIDs
                    events.append(.activityChanged(s.call, activity))
                }
                if !s.call.isManual { advance(&s, micActive: activity.micActive, now: now, events: &events) }
                session = s
            } else if !s.call.isManual {
                events.append(endSession(s, endedAt: endTime(of: s, now: now), now: now, ignoreApp: false))
            }
        }

        events += tick(now: now)
        events += startIfNeeded(byID, now: now)
        return events
    }

    /// Deadline processing between snapshots.
    public mutating func tick(now: Date) -> [DetectionEvent] {
        guard let s = session, case .ending(let releasedAt, let deadline) = s.phase, now >= deadline else { return [] }
        return [endSession(s, endedAt: releasedAt, now: now, ignoreApp: false)]
    }

    /// Seconds since either recorded track had sound.
    public mutating func reportSilence(seconds: TimeInterval, callID: UUID, now: Date) -> [DetectionEvent] {
        guard var s = session, s.call.id == callID else { return [] }
        if case .ending = s.phase { return [] }
        if seconds >= config.staleSilenceSeconds {
            guard !s.staleNotified else { return [] }
            s.staleNotified = true
            session = s
            return [.stale(s.call)]
        }
        if s.staleNotified {
            s.staleNotified = false          // audio came back: ask again next time
            session = s
        }
        return []
    }

    public mutating func respond(_ response: UserCallResponse, callID: UUID, now: Date) -> [DetectionEvent] {
        guard var s = session, s.call.id == callID else { return [] }
        switch response {
        case .record:
            s.isTentative = false
            session = s
            return []
        case .notNow, .never:
            session = nil
            lastSessionEndedAt = now
            ignoreForRestOfCall(s.call.app.bundleID, category: s.call.category)
            return []
        case .keepRecording:
            if case .ending = s.phase { s.phase = .held }
            s.releaseSeenAt = nil
            session = s
            return []
        case .endNow:
            return [endSession(s, endedAt: now, now: now, ignoreApp: true)]
        }
    }

    /// Registers a call the user started from the menu. Replaces any current session (the app
    /// stops that recording itself).
    public mutating func beginManualSession(_ call: DetectedCall, now: Date) -> [DetectionEvent] {
        var manual = call
        manual.isManual = true
        let last = lastActivities[call.app.bundleID]
        session = Session(call: manual, isTentative: false, phase: .active, processObjectIDs: Set(last?.processObjectIDs ?? []),
                          inputDeviceUIDs: last?.inputDeviceUIDs ?? [], outputDeviceUIDs: last?.outputDeviceUIDs ?? [],
                          staleNotified: false)
        micSince[call.app.bundleID] = nil
        return []
    }

    public mutating func endManualSession(_ callID: UUID, now: Date) -> [DetectionEvent] {
        guard let s = session, s.call.id == callID, s.call.isManual else { return [] }
        return [endSession(s, endedAt: now, now: now, ignoreApp: true)]
    }

    /// Better meeting information from the browser probe. Emits `.meetingInfo` when something changed.
    public mutating func setMeetingInfo(_ info: MeetingInfo, callID: UUID) -> [DetectionEvent] {
        guard var s = session, s.call.id == callID else { return [] }
        var call = s.call
        call.meeting = info
        if info.platform != .browser && info.platform != .other { call.platform = info.platform }
        guard call != s.call else { return [] }
        s.call = call
        session = s
        return [.meetingInfo(call)]
    }

    /// The Mac is going to sleep: detected calls end now, and nothing starts until the wake. The app
    /// is not ignored afterwards: if it still holds the mic after the wake, the call went on.
    public mutating func systemWillSleep(now: Date) -> [DetectionEvent] {
        micSince.removeAll()
        asleepSince = now
        guard let s = session, !s.call.isManual else { return [] }
        return [endSession(s, endedAt: endTime(of: s, now: now), now: now, ignoreApp: false)]
    }

    /// The Mac woke up: starts are allowed again, every confirm window starts now.
    public mutating func systemDidWake() {
        asleepSince = nil
        micSince.removeAll()
    }

    /// The app quit: a call it was ignored for is over.
    public mutating func appTerminated(bundleID: String) {
        suppressed[bundleID] = nil
        micSince[bundleID] = nil
    }

    // MARK: Rules

    private func grace(for call: DetectedCall) -> TimeInterval { grace(for: call.category) }

    private func grace(for category: AppCategory) -> TimeInterval {
        category == .browser ? config.endGraceBrowserSeconds : config.endGraceNativeSeconds
    }

    /// Between `systemWillSleep` and `systemDidWake` (at most `sleepHoldSeconds`).
    private func isAsleep(at now: Date) -> Bool {
        guard let since = asleepSince else { return false }
        return now.timeIntervalSince(since) < CallStateMachine.sleepHoldSeconds
    }

    /// Mic use alone may be a recorded message rather than a call: such apps count only while they
    /// also play audio.
    private func needsPlayback(_ activity: AppActivity) -> Bool {
        guard config.messagingRequiresOutput else { return false }
        return activity.category == .messaging || AppCatalog.requiresOutput(bundleID: activity.app.bundleID)
    }

    private func advance(_ s: inout Session, micActive: Bool, now: Date, events: inout [DetectionEvent]) {
        switch s.phase {
        case .active:
            guard !micActive else {
                s.releaseSeenAt = nil
                return
            }
            let released = s.releaseSeenAt ?? now
            s.releaseSeenAt = released
            guard now.timeIntervalSince(released) >= CallStateMachine.releaseDebounceSeconds else { return }
            let deadline = released.addingTimeInterval(grace(for: s.call))
            s.phase = .ending(releasedAt: released, deadline: deadline)
            s.releaseSeenAt = nil
            events.append(.ending(s.call, deadline: deadline))
        case .ending:
            if micActive {
                s.phase = .active
                s.releaseSeenAt = nil
                events.append(.resumed(s.call))
            }
        case .held:
            if micActive {
                s.phase = .active           // the call is clearly on again: normal rules resume
                s.releaseSeenAt = nil
            }
        }
    }

    private func endTime(of s: Session, now: Date) -> Date {
        switch s.phase {
        case .ending(let releasedAt, _): return releasedAt
        case .active: return s.releaseSeenAt ?? now
        case .held: return now
        }
    }

    private mutating func endSession(_ s: Session, endedAt: Date, now: Date, ignoreApp: Bool) -> DetectionEvent {
        session = nil
        lastSessionEndedAt = now
        if ignoreApp { ignoreForRestOfCall(s.call.app.bundleID, category: s.call.category) }
        return .ended(s.call, endedAt: endedAt)
    }

    /// Ignores the app until its current call is over (see *Ignored apps*).
    private mutating func ignoreForRestOfCall(_ bundleID: String, category: AppCategory) {
        suppressed[bundleID] = Suppression(category: category, releasedSince: nil)
        micSince[bundleID] = nil
    }

    private mutating func startIfNeeded(_ byID: [String: AppActivity], now: Date) -> [DetectionEvent] {
        if let s = session, !isEnding(s) { return [] }
        guard !isAsleep(at: now) else { return [] }
        let candidates = micSince.sorted { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }
        for (id, since) in candidates {
            guard let activity = byID[id], activity.micActive, suppressed[id] == nil else { continue }
            if let s = session, s.call.app.bundleID == id { continue }
            guard now.timeIntervalSince(since) >= config.startConfirmSeconds else { continue }
            if needsPlayback(activity), !activity.outputActive { continue }
            guard isDetectionActive(at: now) else {
                ignoreForRestOfCall(id, category: activity.category)
                continue
            }
            let policy = config.policy(for: activity.app, category: activity.category)
            if policy == .never { continue }

            var events: [DetectionEvent] = []
            if let s = session {
                // Only a confidently detected call app may cut a fading call short.
                guard policy == .auto, case .ending(let releasedAt, _) = s.phase else { continue }
                events.append(endSession(s, endedAt: releasedAt, now: now, ignoreApp: false))
            }
            let startedAt = max(since, lastSessionEndedAt ?? since)
            let call = DetectedCall(app: activity.app, category: activity.category, startedAt: startedAt,
                                    platform: AppCatalog.platform(bundleID: activity.app.bundleID))
            session = Session(call: call, isTentative: policy == .ask, phase: .active,
                              processObjectIDs: Set(activity.processObjectIDs), inputDeviceUIDs: activity.inputDeviceUIDs,
                              outputDeviceUIDs: activity.outputDeviceUIDs, staleNotified: false)
            micSince[id] = nil
            events.append(policy == .auto ? .started(call) : .ask(call))
            return events
        }
        return []
    }

    private func isEnding(_ s: Session) -> Bool {
        if case .ending = s.phase { return true }
        return false
    }
}
