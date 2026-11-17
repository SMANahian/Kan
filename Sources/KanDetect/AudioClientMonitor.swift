import CoreAudio
import Darwin
import Foundation
import KanAudio
import KanCore

/// Source of app audio activity for `CallDetector` (live: `AudioClientMonitor`; tests: a fake).
public protocol AudioClientMonitoring: AnyObject {
    /// Activities grouped by owning app, without Kan and system noise. nil when Core Audio can't be read.
    func activities() -> [AppActivity]?
    /// Calls `onChange` on `queue` whenever the client list or a client's state may have changed
    /// (listeners plus a poll), until `stopObserving()`.
    func startObserving(queue: DispatchQueue, onChange: @escaping () -> Void)
    func stopObserving()
    func isProcessAlive(_ pid: Int32) -> Bool
}

/// Reads the Core Audio client list and groups it by owning app.
///
/// Change triggers: C-API property listeners on the process list (`prs#`) and on every client's
/// `pir?` (IsRunning) and `pdv#` (Devices), plus a poll — on macOS 26 the per-process
/// IsRunningInput / IsRunningOutput listeners never fire, so those values are re-read on every
/// trigger. Reading needs no permission. Never uses kAudioDevicePropertyDeviceIsRunningSomewhere:
/// Kan's own recording keeps the device running.
///
/// Thread-safety: snapshot methods may be called from any thread (an internal lock guards the owner
/// cache). Observation state is confined to the queue passed to `startObserving`.
public final class AudioClientMonitor: AudioClientMonitoring, @unchecked Sendable {
    public let resolver: OwnerResolver
    public let pollInterval: TimeInterval

    private struct CacheKey: Hashable {
        var object: UInt32
        var pid: Int32
        var bundleID: String
    }

    /// What never changes for a process object: read once, not on every poll.
    private struct StaticInfo {
        var pid: Int32
        var bundleID: String
        var path: String?
    }

    private let cacheLock = NSLock()
    private var ownerCache: [CacheKey: ResolvedClient] = [:]     // guarded by cacheLock
    private var staticInfo: [AudioObjectID: StaticInfo] = [:]    // guarded by cacheLock

    // Confined to `observeQueue`.
    private var observeQueue: DispatchQueue?
    private var onChange: (() -> Void)?
    private var systemListeners: [HALListener] = []
    private var processListeners: [UInt32: [HALListener]] = [:]
    private var timer: DispatchSourceTimer?
    private var notifyPending = false
    private var generation = 0

    public init(resolver: OwnerResolver = OwnerResolver(), pollInterval: TimeInterval = 1) {
        self.resolver = resolver
        self.pollInterval = pollInterval
    }

    deinit {
        // Both are thread-safe; normally stopObserving() already did this on the observe queue.
        timer?.cancel()
        systemListeners.forEach { $0.invalidate() }
        processListeners.values.forEach { $0.forEach { $0.invalidate() } }
    }

    // MARK: Snapshots

    /// Every Core Audio client process, unfiltered. nil when the process list can't be read.
    public func clients() -> [AudioClient]? {
        guard let objects = try? HAL.processObjects() else { return nil }
        var uidCache: [AudioObjectID: String] = [:]
        func uids(_ object: AudioObjectID, input: Bool) -> [String] {
            let devices = (try? HAL.readObjectIDs(object, kAudioProcessPropertyDevices,
                                                  scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)) ?? []
            return devices.compactMap { device in
                if let cached = uidCache[device] { return cached }
                let uid = HAL.deviceUID(device)
                uidCache[device] = uid
                return uid
            }
        }
        let known = cacheLock.withLock { staticInfo }
        var fresh: [AudioObjectID: StaticInfo] = [:]
        let result = objects.compactMap { object -> AudioClient? in
            let info: StaticInfo
            if let cached = known[object] {
                info = cached
            } else {
                guard let pid = try? HAL.read(object, kAudioProcessPropertyPID, as: pid_t(-1)), pid > 0 else { return nil }
                info = StaticInfo(pid: pid, bundleID: (try? HAL.readString(object, kAudioProcessPropertyBundleID)) ?? "",
                                  path: LiveLookups.executablePath(pid))
            }
            fresh[object] = info
            return AudioClient(
                processObjectID: object, pid: info.pid, bundleID: info.bundleID, path: info.path,
                isRunning: HAL.readBool(object, kAudioProcessPropertyIsRunning),
                isRunningInput: HAL.readBool(object, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: HAL.readBool(object, kAudioProcessPropertyIsRunningOutput),
                inputDeviceUIDs: uids(object, input: true), outputDeviceUIDs: uids(object, input: false))
        }
        cacheLock.withLock { staticInfo = fresh }
        return result
    }

    /// Clients with their owners (including excluded ones, for diagnostics).
    public func resolvedClients() -> [ResolvedClient]? {
        guard let clients = clients() else { return nil }
        return resolve(clients)
    }

    public func activities() -> [AppActivity]? {
        resolvedClients().map(AudioClientMonitor.group)
    }

    public func isProcessAlive(_ pid: Int32) -> Bool { LiveLookups.isAlive(pid) }

    /// Resolves owners, caching per process (the FaceTime mapping depends on whether FaceTime runs,
    /// so call daemons are never cached). The cache keeps the live state fields fresh.
    func resolve(_ clients: [AudioClient]) -> [ResolvedClient] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var fresh: [CacheKey: ResolvedClient] = [:]
        let resolved = clients.map { client -> ResolvedClient in
            let key = CacheKey(object: client.processObjectID, pid: client.pid, bundleID: client.bundleID)
            var r: ResolvedClient
            if let cached = ownerCache[key], !OwnerResolver.isCallDaemon(client) {
                r = cached
                r.client = client
            } else {
                r = resolver.resolve(client)
            }
            fresh[key] = r
            return r
        }
        ownerCache = fresh
        return resolved
    }

    /// Groups resolved clients into one activity per owning app (excluded clients are dropped).
    /// Sorted: mic users first, then apps playing audio, then by name.
    public static func group(_ resolved: [ResolvedClient]) -> [AppActivity] {
        var order: [String] = []
        var groups: [String: [ResolvedClient]] = [:]
        for r in resolved where r.exclusion == nil {
            let key = r.owner.bundleID.isEmpty ? "pid:\(r.owner.pid)" : r.owner.bundleID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        let activities = order.compactMap { key -> AppActivity? in
            guard let members = groups[key], let first = members.first else { return nil }
            // Prefer an identity that knows its .app, then the owner PID most clients agree on.
            let pidCounts = Dictionary(grouping: members, by: { $0.owner.pid }).mapValues(\.count)
            let owner = members.map(\.owner).max { a, b in
                let ka = (a.path != nil ? 1 : 0, pidCounts[a.pid] ?? 0)
                let kb = (b.path != nil ? 1 : 0, pidCounts[b.pid] ?? 0)
                return ka < kb
            } ?? first.owner
            // Devices of clients that are actually doing IO in that direction come first.
            let inputs = unique(members.filter { $0.client.isRunningInput }.flatMap(\.client.inputDeviceUIDs)
                                + members.flatMap(\.client.inputDeviceUIDs))
            let outputs = unique(members.filter { $0.client.isRunningOutput }.flatMap(\.client.outputDeviceUIDs)
                                 + members.flatMap(\.client.outputDeviceUIDs))
            return AppActivity(
                app: owner, category: first.category,
                micActive: members.contains { $0.client.isRunningInput },
                outputActive: members.contains { $0.client.isRunningOutput },
                processObjectIDs: Array(Set(members.map(\.client.processObjectID))).sorted(),
                processBundleIDs: unique(members.map(\.client.bundleID).filter { !$0.isEmpty }),
                pids: Array(Set(members.map(\.client.pid))).sorted(),
                inputDeviceUIDs: inputs, outputDeviceUIDs: outputs)
        }
        return activities.sorted { a, b in
            if a.micActive != b.micActive { return a.micActive }
            if a.outputActive != b.outputActive { return a.outputActive }
            return a.app.name.localizedCaseInsensitiveCompare(b.app.name) == .orderedAscending
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Observation

    public func startObserving(queue: DispatchQueue, onChange: @escaping () -> Void) {
        queue.async { [self] in
            stopObservingNow()
            generation += 1
            observeQueue = queue
            self.onChange = onChange
            do {
                systemListeners.append(try HALListener(HAL.systemObject, kAudioHardwarePropertyProcessObjectList, queue: queue) {
                    [weak self] in self?.processListChanged()
                })
                systemListeners.append(try HALListener(HAL.systemObject, kAudioHardwarePropertyServiceRestarted, queue: queue) {
                    [weak self] in self?.serviceRestarted()
                })
            } catch {
                KanLog.warning("audio client listener: \(error)", category: "detect")
            }
            refreshProcessListeners()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.onChange?() }
            t.resume()
            timer = t
        }
    }

    public func stopObserving() {
        guard let queue = observeQueue else { return }
        queue.async { [self] in stopObservingNow() }
    }

    private func stopObservingNow() {
        timer?.cancel()
        timer = nil
        systemListeners.forEach { $0.invalidate() }
        systemListeners.removeAll()
        processListeners.values.forEach { $0.forEach { $0.invalidate() } }
        processListeners.removeAll()
        onChange = nil
    }

    private func processListChanged() {
        refreshProcessListeners()
        notify()
    }

    private func serviceRestarted() {
        // Every process object id is invalid now; re-register from scratch.
        KanLog.warning("coreaudiod restarted; re-reading audio clients", category: "detect")
        cacheLock.withLock {
            staticInfo.removeAll()
            ownerCache.removeAll()
        }
        processListeners.values.forEach { $0.forEach { $0.invalidate() } }
        processListeners.removeAll()
        refreshProcessListeners()
        notify()
    }

    private func refreshProcessListeners() {
        guard let queue = observeQueue, onChange != nil else { return }
        let current = Set((try? HAL.processObjects()) ?? [])
        for (object, listeners) in processListeners where !current.contains(object) {
            listeners.forEach { $0.invalidate() }
            processListeners[object] = nil
        }
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioProcessPropertyIsRunning, kAudioObjectPropertyScopeGlobal),
            (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeGlobal),
            (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
            (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
        ]
        for object in current where processListeners[object] == nil {
            processListeners[object] = selectors.compactMap { selector, scope in
                try? HALListener(object, selector, scope: scope, queue: queue) { [weak self] in self?.notify() }
            }
        }
    }

    /// Coalesces bursts of notifications (a call app starting IO touches several properties at once).
    private func notify() {
        guard !notifyPending, let queue = observeQueue else { return }
        notifyPending = true
        let gen = generation
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.notifyPending = false
            if gen == self.generation { self.onChange?() }
        }
    }
}
