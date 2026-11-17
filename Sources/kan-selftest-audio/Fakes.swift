import CoreAudio
import Foundation
import KanAudio
import KanCore
import KanDetect
import KanTestKit

// Test doubles. Nothing here touches real audio devices, taps or permissions.

/// A host clock the tests advance by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    let startHost: UInt64 = 5_000_000_000
    let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var host: UInt64
    private var slept: Double = 0

    init() { host = startHost }

    var now: UInt64 { lock.withLock { host } }
    var date: Date {
        let (ticks, asleep) = lock.withLock { (host, slept) }
        return startDate.addingTimeInterval(HostClock.seconds(from: startHost, to: ticks) + asleep)
    }
    /// Seconds since the clock started.
    var elapsed: Double { HostClock.seconds(from: startHost, to: now) }

    func advance(_ seconds: Double) { lock.withLock { host &+= HostClock.ticks(seconds) } }
    /// The Mac sleeps: wall-clock time passes, host time (mach_absolute_time) doesn't.
    func sleep(_ seconds: Double) { lock.withLock { slept += seconds } }
    func set(_ seconds: Double) { lock.withLock { host = startHost &+ HostClock.ticks(seconds) } }
    func host(at seconds: Double) -> UInt64 { HostClock.offset(startHost, by: seconds) }
}

/// A capture source fed by the test: `emit` writes 10 ms IO buffers into the ring with host times.
final class FakeSource: CaptureSource, @unchecked Sendable {
    enum Kind: Equatable {
        case mic(String)
        case tap(TapTarget)
    }

    let kind: Kind
    let sampleRate: Double
    var onFault: ((CaptureFault) -> Void)?
    var startError: Error?
    var retargetError: Error?
    private(set) var ring: CaptureRing?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var retargets: [TapTarget] = []
    private var phase = 0

    init(kind: Kind, sampleRate: Double = 48_000) {
        self.kind = kind
        self.sampleRate = sampleRate
    }

    var name: String {
        switch kind {
        case .mic(let uid): return "fake mic \(uid)"
        case .tap(let target): return "fake tap \(target)"
        }
    }

    var tapTarget: TapTarget? {
        if case .tap(let t) = kind { return retargets.last ?? t }
        return nil
    }

    func start() throws -> CaptureRing {
        if let startError { throw startError }
        let r = CaptureRing(sampleRate: sampleRate, seconds: 30)
        ring = r
        startCount += 1
        return r
    }

    func stop() { stopCount += 1 }

    func retarget(_ target: TapTarget) throws {
        if let retargetError { throw retargetError }
        retargets.append(target)
    }

    /// Writes `duration` seconds of a sine (amplitude 0 = exact digital silence) starting at
    /// `start` seconds on the fake clock. `hostSecondsPerSecond` > 1 models a device clock that runs
    /// slow relative to the host clock (its samples take longer in host time).
    func emit(from start: Double, duration: Double, clock: FakeClock, amplitude: Float = 0.3,
              frequency: Double = 440, hostSecondsPerSecond: Double = 1, bufferFrames: Int = 480) {
        guard let ring else { return }
        let total = Int((duration * sampleRate).rounded())
        var written = 0
        var buffer = [Float](repeating: 0, count: bufferFrames)
        while written < total {
            let n = min(bufferFrames, total - written)
            for i in 0..<n {
                buffer[i] = amplitude == 0 ? 0 : amplitude * Float(sin(2 * Double.pi * frequency * Double(phase + i) / sampleRate))
            }
            let t = start + Double(written) / sampleRate * hostSecondsPerSecond
            buffer.withUnsafeBufferPointer { ring.write(mono: UnsafeBufferPointer(rebasing: $0[0..<n]), hostTime: clock.host(at: t)) }
            phase += n
            written += n
        }
    }
}

/// The recording environment with fake devices and sources and a simulated clock.
final class FakeRecordingEnvironment: RecordingEnvironment, @unchecked Sendable {
    let clock = FakeClock()
    private let lock = NSLock()
    var micPermission: PermissionStatus = .granted
    private var access: SystemAudioAccess = .notGranted
    private var devicesNow: [AudioDeviceInfo] = FakeDevices.standard
    private var defaultInputNow: String? = FakeDevices.builtInMic.uid
    var defaultOutput: String? = FakeDevices.builtInSpeakers.uid
    private var failingScopes: Set<String> = []
    var micStartError: Error?
    var freeBytes: Int64? = 50_000_000_000
    var resolvedObjects: [UInt32] = []
    private var tapSources: [FakeSource] = []
    private var micSources: [FakeSource] = []
    private var systemHandler: ((SystemAudioEvent) -> Void)?
    private var systemQueue: DispatchQueue?

    var taps: [FakeSource] { lock.withLock { tapSources } }
    var mics: [FakeSource] { lock.withLock { micSources } }

    // Read on the session queue while a test changes them.
    var systemAudio: SystemAudioAccess {
        get { lock.withLock { access } }
        set { lock.withLock { access = newValue } }
    }
    var deviceList: [AudioDeviceInfo] {
        get { lock.withLock { devicesNow } }
        set { lock.withLock { devicesNow = newValue } }
    }
    var defaultInput: String? {
        get { lock.withLock { defaultInputNow } }
        set { lock.withLock { defaultInputNow = newValue } }
    }
    /// Tap scopes ("processes", "systemAudio") whose sources fail to start.
    var failingTapScopes: Set<String> {
        get { lock.withLock { failingScopes } }
        set { lock.withLock { failingScopes = newValue } }
    }

    func hostTime() -> UInt64 { clock.now }
    func wallClock() -> Date { clock.date }
    func microphonePermission() -> PermissionStatus { micPermission }
    func systemAudioAccess() -> SystemAudioAccess { systemAudio }
    func devices() -> [AudioDeviceInfo] { deviceList }
    func defaultInputUID() -> String? { defaultInput }
    func defaultOutputUID() -> String? { defaultOutput }

    func makeMicrophoneSource(deviceUID: String) throws -> CaptureSource {
        let s = FakeSource(kind: .mic(deviceUID))
        s.startError = micStartError
        lock.withLock { micSources.append(s) }
        return s
    }

    func makeTapSource(_ target: TapTarget) throws -> CaptureSource {
        let s = FakeSource(kind: .tap(target))
        if failingTapScopes.contains(target.scope == .processes ? "processes" : "systemAudio") {
            s.startError = CoreAudioError(kAudioHardwareIllegalOperationError, "fake tap start")
        }
        lock.withLock { tapSources.append(s) }
        return s
    }

    func ownProcessObjectID() -> UInt32? { 999 }
    func resolveProcessObjects(pids: [Int32], bundleIDs: [String]) -> [UInt32] { resolvedObjects }

    func observeSystemAudio(queue: DispatchQueue, handler: @escaping (SystemAudioEvent) -> Void) -> AnyObject? {
        lock.withLock {
            systemQueue = queue
            systemHandler = handler
        }
        return NSObject()
    }

    func availableDiskBytes(at url: URL) -> Int64? { freeBytes }

    /// Delivers a system event the way the live observer would (on the session queue).
    func fire(_ event: SystemAudioEvent) {
        let (queue, handler) = lock.withLock { (systemQueue, systemHandler) }
        guard let queue, let handler else { return }
        queue.async { handler(event) }
    }
}

enum FakeDevices {
    static let builtInMic = AudioDeviceInfo(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                            transport: .builtIn, inputChannels: 1)
    static let builtInSpeakers = AudioDeviceInfo(id: 2, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                                 transport: .builtIn, outputChannels: 2, outputDataSource: "ispk",
                                                 outputTerminalTypes: ["769"])
    static let airPods = AudioDeviceInfo(id: 3, uid: "AirPods-UID", name: "Nahian's AirPods Pro", transport: .bluetooth,
                                         inputChannels: 1, outputChannels: 2, outputTerminalTypes: ["hdph"])
    static let usbMic = AudioDeviceInfo(id: 4, uid: "USB-Mic", name: "Blue Yeti", transport: .usb, inputChannels: 2, outputChannels: 2)
    static let zoomVirtual = AudioDeviceInfo(id: 5, uid: "zoom.us.zoomaudiodevice.001", name: "ZoomAudioDevice", transport: .virtual,
                                             inputChannels: 2, outputChannels: 2, outputTerminalTypes: ["spdf"])
    static let standard = [builtInMic, builtInSpeakers, zoomVirtual]
}

/// An audio-client monitor driven by the test. Polls (calls onChange) every `interval` while observed.
final class FakeMonitor: AudioClientMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AppActivity] = []
    private var alive: Set<Int32> = []
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.02) { self.interval = interval }

    func set(_ activities: [AppActivity], alive pids: Set<Int32>? = nil) {
        lock.withLock {
            current = activities
            alive = pids ?? Set(activities.map(\.app.pid))
        }
    }

    func activities() -> [AppActivity]? { lock.withLock { current } }
    func isProcessAlive(_ pid: Int32) -> Bool { lock.withLock { alive.contains(pid) } }

    func startObserving(queue: DispatchQueue, onChange: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler(handler: onChange)
        t.resume()
        lock.withLock { timer = t }
    }

    func stopObserving() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}

/// Thread-safe collector for callbacks.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

// MARK: Shared helpers

func activity(_ bundleID: String, _ name: String, _ category: AppCategory, mic: Bool, out: Bool = false,
              objects: [UInt32] = [1], pid: Int32 = 100, inputs: [String] = [], outputs: [String] = []) -> AppActivity {
    AppActivity(app: AppIdentity(bundleID: bundleID, name: name, path: "/Applications/\(name).app", pid: pid),
                category: category, micActive: mic, outputActive: out, processObjectIDs: objects,
                processBundleIDs: [bundleID], pids: [pid], inputDeviceUIDs: inputs, outputDeviceUIDs: outputs)
}

func maxAbs(_ samples: ArraySlice<Float>) -> Float { samples.reduce(0) { max($0, abs($1)) } }

func rms(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

func readMono(_ url: URL) throws -> [Float] { try WAVReader(url: url).readAllMono() }

/// A fresh, empty directory inside this run's private KAN_HOME (not the shared $TMPDIR/kan-tests,
/// which other test executables running at the same time may clean up).
func scratchDirectory(_ name: String) -> URL {
    let home = ProcessInfo.processInfo.environment["KAN_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("kan-selftest-audio-\(getpid())", isDirectory: true)
    let url = home.appendingPathComponent("tests/\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
