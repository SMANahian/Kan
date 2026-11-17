import CoreAudio
import Darwin
import Foundation
import KanCore

// Live capture sources. Lifecycle (order matters, from the research spike):
//
//   tap:  CATapDescription → AudioHardwareCreateProcessTap → tap UID + format
//         → AudioHardwareCreateAggregateDevice (tap only, private) → IOProc (nil queue) → AudioDeviceStart
//         The FIRST start of an aggregate containing a tap shows the System Audio Recording prompt.
//   stop: AudioDeviceStop → AudioDeviceDestroyIOProcID → AudioHardwareDestroyAggregateDevice
//         → AudioHardwareDestroyProcessTap
//
// IOProcs are created with a nil dispatch queue, so the HAL calls them directly on its real-time IO
// thread (with a queue it dispatch_syncs onto it and a busy queue stalls IO). They only mix into a
// preallocated CaptureRing; conversion and file writes happen on the session's worker queue.
//
// Both classes are driven from one queue (the session's). Fault callbacks arrive on a private
// listener queue.

private func ioHostTime(_ t: UnsafePointer<AudioTimeStamp>) -> UInt64 {
    let ts = t.pointee
    return ts.mFlags.contains(.hostTimeValid) && ts.mHostTime != 0 ? ts.mHostTime : mach_absolute_time()
}

private func isFloat32PCM(_ f: AudioStreamBasicDescription) -> Bool {
    f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && f.mBitsPerChannel == 32 && f.mSampleRate > 0 && f.mChannelsPerFrame > 0
}

/// The call app's output (or all system audio) through a mono mixdown process tap in a tap-only
/// private aggregate device.
///
/// Why tap-only: an aggregate that also contains an output device exposes that device's input
/// streams too (a headset mic → doubled audio and a Microphone permission check), and the tap clocks
/// the aggregate by itself, so a default-output switch with an unchanged format keeps running.
final class ProcessTapSource: CaptureSource {
    var onFault: ((CaptureFault) -> Void)?
    private(set) var target: TapTarget
    private let uuid = UUID()
    private let ringSeconds: Double
    private var tapID = HAL.unknownObject
    private var aggregateID = HAL.unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALListener] = []
    private var ring: CaptureRing?
    private let listenerQueue = DispatchQueue(label: "com.nahian.Kan.tap.listeners")

    init(target: TapTarget, ringSeconds: Double) {
        self.target = target
        self.ringSeconds = ringSeconds
    }

    deinit { stop() }

    var name: String { "tap: \(target)" }

    func start() throws -> CaptureRing {
        stop()
        do {
            let description = makeDescription()
            var tap = HAL.unknownObject
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
            // An unsatisfiable description can "succeed" with object id 0.
            guard tap != HAL.unknownObject else {
                throw CoreAudioError(kAudioHardwareIllegalOperationError, "AudioHardwareCreateProcessTap returned no tap")
            }
            tapID = tap
            let tapFormat = try HAL.readASBD(tap, kAudioTapPropertyFormat)
            let tapUID = try HAL.readString(tap, kAudioTapPropertyUID)

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Kan Call Audio",
                kAudioAggregateDeviceUIDKey: "com.nahian.Kan.tap.\(uuid.uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,        // invisible to other apps, not persisted
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,    // run IO now (zeros until the app plays)
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]],
            ]
            var aggregate = HAL.unknownObject
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                          "AudioHardwareCreateAggregateDevice")
            aggregateID = aggregate

            // The IOProc sees the aggregate's input stream format; it should equal the tap format.
            let format = (try? HAL.firstStreamVirtualFormat(aggregate, input: true).format) ?? tapFormat
            guard isFloat32PCM(format) else {
                throw CoreAudioError(kAudioHardwareUnsupportedOperationError,
                                     "tap format \(format.mSampleRate) Hz flags \(format.mFormatFlags)")
            }
            let ring = CaptureRing(sampleRate: format.mSampleRate, seconds: ringSeconds)
            let layout = InputLayout.forStream(format)          // tap-only aggregate: buffer 0 is the tap
            let core = ring.core
            var procID: AudioDeviceIOProcID?
            try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, inputTime, _, _ in
                CaptureRing.write(core, input, layout, ioHostTime(inputTime))
            }, "AudioDeviceCreateIOProcIDWithBlock(tap)")
            ioProcID = procID
            installListeners(tap: tap, aggregate: aggregate, format: format)
            try HAL.check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart(tap)")
            self.ring = ring
            KanLog.info("tap started: \(target), \(Int(format.mSampleRate)) Hz × \(format.mChannelsPerFrame)", category: "audio")
            return ring
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        listeners.forEach { $0.invalidate() }
        listeners.removeAll()
        if aggregateID != HAL.unknownObject {
            if let procID = ioProcID {
                let s1 = AudioDeviceStop(aggregateID, procID)
                let s2 = AudioDeviceDestroyIOProcID(aggregateID, procID)
                if s1 != noErr || s2 != noErr { KanLog.debug("tap IOProc teardown: \(HAL.fourCC(s1)) \(HAL.fourCC(s2))", category: "audio") }
            }
            let s = AudioHardwareDestroyAggregateDevice(aggregateID)
            if s != noErr { KanLog.debug("destroy tap aggregate: \(HAL.fourCC(s))", category: "audio") }
        }
        ioProcID = nil
        aggregateID = HAL.unknownObject
        if tapID != HAL.unknownObject {
            let s = AudioHardwareDestroyProcessTap(tapID)
            if s != noErr { KanLog.debug("destroy tap: \(HAL.fourCC(s))", category: "audio") }
        }
        tapID = HAL.unknownObject
        ring = nil
    }

    /// Changes the tapped processes on the live tap (kAudioTapPropertyDescription).
    /// Fails with '!hog' when the System Audio Recording permission is missing.
    func retarget(_ newTarget: TapTarget) throws {
        guard newTarget.scope == target.scope else {
            throw CoreAudioError(kAudioHardwareIllegalOperationError, "cannot change the tap scope live")
        }
        let previous = target
        target = newTarget
        guard tapID != HAL.unknownObject else { return }
        var description = makeDescription()
        var address = HAL.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.stride), $0)
        }
        if status != noErr {
            target = previous
            throw CoreAudioError(status, "set kAudioTapPropertyDescription")
        }
        KanLog.info("tap retargeted: \(newTarget)", category: "audio")
    }

    private func makeDescription() -> CATapDescription {
        let d: CATapDescription
        switch target.scope {
        case .processes: d = CATapDescription(monoMixdownOfProcesses: target.processObjectIDs)
        case .systemAudio: d = CATapDescription(monoGlobalTapButExcludeProcesses: target.processObjectIDs)
        }
        d.name = "Kan call audio"
        d.uuid = uuid
        d.isPrivate = true
        d.muteBehavior = .unmuted          // never mute: the user must keep hearing the call
        if #available(macOS 26.0, *), !target.bundleIDs.isEmpty {
            d.bundleIDs = target.bundleIDs
            if target.scope == .processes { d.isProcessRestoreEnabled = true }
        }
        return d
    }

    private func installListeners(tap: AudioObjectID, aggregate: AudioObjectID, format: AudioStreamBasicDescription) {
        let report: (CaptureFault) -> Void = { [weak self] fault in self?.onFault?(fault) }
        func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
            do {
                listeners.append(try HALListener(object, selector, queue: listenerQueue, handler: handler))
            } catch {
                KanLog.warning("tap listener: \(error)", category: "audio")
            }
        }
        // Compare before reacting: the HAL re-publishes properties when aggregates come and go.
        add(tap, kAudioTapPropertyFormat) {
            guard let f = try? HAL.readASBD(tap, kAudioTapPropertyFormat) else { return }
            if f.mSampleRate != format.mSampleRate || f.mChannelsPerFrame != format.mChannelsPerFrame { report(.formatChanged) }
        }
        add(aggregate, kAudioDevicePropertyNominalSampleRate) {
            guard let rate = try? HAL.readFloat64(aggregate, kAudioDevicePropertyNominalSampleRate),
                  rate > 0, rate != format.mSampleRate else { return }
            report(.formatChanged)
        }
        add(aggregate, kAudioDevicePropertyDeviceIsAlive) {
            if !HAL.readBool(aggregate, kAudioDevicePropertyDeviceIsAlive) { report(.deviceDied) }
        }
        add(aggregate, kAudioDevicePropertyIOStoppedAbnormally) { report(.ioStoppedAbnormally) }
    }
}

/// The user's microphone through a HAL IOProc on the input device.
///
/// Not AVAudioEngine: no output node (touching it can force AirPods into the low-quality headset
/// profile) and never voice processing (it ducks the call app's playback by 8–30 dB and can disturb
/// its microphone). The IOProc also gives exact host times on the same clock as the tap.
final class MicrophoneSource: CaptureSource {
    var onFault: ((CaptureFault) -> Void)?
    let deviceUID: String
    let name: String
    private let deviceID: AudioDeviceID
    private let ringSeconds: Double
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALListener] = []
    private var ring: CaptureRing?
    private let listenerQueue = DispatchQueue(label: "com.nahian.Kan.mic.listeners")

    init(deviceID: AudioDeviceID, uid: String, name: String, ringSeconds: Double) {
        self.deviceID = deviceID
        self.deviceUID = uid
        self.name = name
        self.ringSeconds = ringSeconds
    }

    deinit { stop() }

    func start() throws -> CaptureRing {
        stop()
        do {
            let (stream, format) = try HAL.firstStreamVirtualFormat(deviceID, input: true)
            guard isFloat32PCM(format) else {
                throw CoreAudioError(kAudioHardwareUnsupportedOperationError, "microphone format flags \(format.mFormatFlags)")
            }
            let ring = CaptureRing(sampleRate: format.mSampleRate, seconds: ringSeconds)
            let layout = InputLayout.forStream(format)          // stream 0's buffers come first
            let core = ring.core
            var procID: AudioDeviceIOProcID?
            try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, inputTime, output, _ in
                CaptureRing.write(core, input, layout, ioHostTime(inputTime))
                // Headsets have outputs too; this IOProc must never contribute sound to them.
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }, "AudioDeviceCreateIOProcIDWithBlock(mic)")
            ioProcID = procID
            if let procID { MicrophoneSource.disableOutputStreams(device: deviceID, procID: procID) }
            installListeners(stream: stream, format: format)
            // The first start triggers the Microphone prompt (needs NSMicrophoneUsageDescription).
            try HAL.check(AudioDeviceStart(deviceID, procID), "AudioDeviceStart(mic)")
            self.ring = ring
            KanLog.info("microphone started: \(name), \(Int(format.mSampleRate)) Hz × \(format.mChannelsPerFrame)", category: "audio")
            return ring
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        listeners.forEach { $0.invalidate() }
        listeners.removeAll()
        if let procID = ioProcID {
            let s1 = AudioDeviceStop(deviceID, procID)
            let s2 = AudioDeviceDestroyIOProcID(deviceID, procID)
            if s1 != noErr || s2 != noErr { KanLog.debug("mic IOProc teardown: \(HAL.fourCC(s1)) \(HAL.fourCC(s2))", category: "audio") }
        }
        ioProcID = nil
        ring = nil
    }

    func retarget(_ target: TapTarget) throws {
        throw CoreAudioError(kAudioHardwareUnsupportedOperationError, "a microphone cannot be retargeted")
    }

    /// Tells the HAL this IOProc uses no output streams (kAudioDevicePropertyIOProcStreamUsage), so
    /// recording a headset's microphone doesn't run its output side for us. Best effort.
    private static func disableOutputStreams(device: AudioDeviceID, procID: AudioDeviceIOProcID) {
        var address = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size,
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        guard count > 0, flagsOffset + count * MemoryLayout<UInt32>.size <= Int(size) else { return }
        let flags = (raw + flagsOffset).bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = 0 }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
        if status != noErr { KanLog.debug("mic output stream usage: \(HAL.fourCC(status))", category: "audio") }
    }

    private func installListeners(stream: AudioStreamID, format: AudioStreamBasicDescription) {
        let report: (CaptureFault) -> Void = { [weak self] fault in self?.onFault?(fault) }
        let device = deviceID
        func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping () -> Void) {
            do {
                listeners.append(try HALListener(object, selector, scope: scope, queue: listenerQueue, handler: handler))
            } catch {
                KanLog.warning("microphone listener: \(error)", category: "audio")
            }
        }
        let formatChanged: () -> Void = {
            guard let current = try? HAL.firstStreamVirtualFormat(device, input: true).format else { return }
            if current.mSampleRate != format.mSampleRate || current.mChannelsPerFrame != format.mChannelsPerFrame
                || current.mFormatFlags != format.mFormatFlags {
                report(.formatChanged)
            }
        }
        add(device, kAudioDevicePropertyDeviceIsAlive) {
            if !HAL.readBool(device, kAudioDevicePropertyDeviceIsAlive) { report(.deviceDied) }
        }
        add(device, kAudioDevicePropertyNominalSampleRate, formatChanged)
        add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput, formatChanged)
        add(stream, kAudioStreamPropertyVirtualFormat, formatChanged)
        add(device, kAudioDevicePropertyIOStoppedAbnormally) { report(.ioStoppedAbnormally) }
    }
}

/// Default-device, device-list and coreaudiod-restart notifications for the recorder.
final class SystemAudioObserver {
    private var listeners: [HALListener] = []

    init(queue: DispatchQueue, handler: @escaping (SystemAudioEvent) -> Void) {
        let pairs: [(AudioObjectPropertySelector, SystemAudioEvent)] = [
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
            (kAudioHardwarePropertyDevices, .devicesChanged),
            (kAudioHardwarePropertyServiceRestarted, .serviceRestarted),
        ]
        for (selector, event) in pairs {
            do {
                listeners.append(try HALListener(HAL.systemObject, selector, queue: queue) { handler(event) })
            } catch {
                KanLog.warning("system audio listener: \(error)", category: "audio")
            }
        }
    }

    deinit { listeners.forEach { $0.invalidate() } }
}

/// The real machine.
public final class LiveRecordingEnvironment: RecordingEnvironment, @unchecked Sendable {
    private let ringSeconds: Double

    public init(ringSeconds: Double = 10) {
        self.ringSeconds = ringSeconds
        Permissions.noteLaunchStatus()
    }

    public func hostTime() -> UInt64 { mach_absolute_time() }
    public func wallClock() -> Date { Date() }
    public func microphonePermission() -> PermissionStatus { Permissions.microphoneStatus() }
    public func systemAudioAccess() -> SystemAudioAccess { Permissions.systemAudioAccess() }
    public func devices() -> [AudioDeviceInfo] { AudioDeviceInfo.all() }
    public func defaultInputUID() -> String? { HAL.defaultInputDevice().flatMap(HAL.deviceUID) }
    public func defaultOutputUID() -> String? { HAL.defaultOutputDevice().flatMap(HAL.deviceUID) }

    public func makeMicrophoneSource(deviceUID: String) throws -> CaptureSource {
        guard let id = HAL.device(forUID: deviceUID) else {
            throw CoreAudioError(kAudioHardwareBadDeviceError, "no input device \(deviceUID)")
        }
        return MicrophoneSource(deviceID: id, uid: deviceUID, name: HAL.name(id), ringSeconds: ringSeconds)
    }

    public func makeTapSource(_ target: TapTarget) throws -> CaptureSource {
        ProcessTapSource(target: target, ringSeconds: ringSeconds)
    }

    public func ownProcessObjectID() -> UInt32? { HAL.processObject(forPID: getpid()) }

    public func resolveProcessObjects(pids: [Int32], bundleIDs: [String]) -> [UInt32] {
        let wantedPIDs = Set(pids)
        let wantedBundles = Set(bundleIDs.filter(TapTarget.isTapBundleID))
        guard let objects = try? HAL.processObjects() else { return [] }
        return objects.filter { object in
            if let pid = try? HAL.read(object, kAudioProcessPropertyPID, as: pid_t(-1)), wantedPIDs.contains(pid) { return true }
            if let bundle = try? HAL.readString(object, kAudioProcessPropertyBundleID), wantedBundles.contains(bundle) { return true }
            return false
        }
    }

    public func observeSystemAudio(queue: DispatchQueue, handler: @escaping (SystemAudioEvent) -> Void) -> AnyObject? {
        SystemAudioObserver(queue: queue, handler: handler)
    }

    public func availableDiskBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
