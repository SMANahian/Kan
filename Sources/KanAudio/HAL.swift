import CoreAudio
import Darwin
import Foundation
import os

// Thin helpers over the Core Audio HAL C API, shared by KanAudio and KanDetect.
//
// None of these functions may be called from a real-time IO thread: they read HAL properties,
// allocate and may block on coreaudiod.

/// A failed Core Audio call.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String { "\(operation) failed: \(HAL.fourCC(status))" }

    /// '!hog' — returned e.g. when changing a tap without the System Audio Recording permission.
    public var isPermissionError: Bool { status == kAudioDevicePermissionsError }
}

public enum HAL {
    public static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    public static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    /// "'nope'" for four-character codes, the decimal value otherwise.
    public static func fourCC(_ status: OSStatus) -> String {
        let v = UInt32(bitPattern: status)
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)' (\(status))"
        }
        return "\(status)"
    }

    /// Four-character code as text ("ispk"), used for selectors, transport types and data sources.
    public static func code(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) { return s }
        return String(v)
    }

    public static func address(_ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    @inline(__always)
    public static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(status, operation()) }
    }

    public static func hasProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        return AudioObjectHasProperty(object, &a)
    }

    /// Reads a fixed-size plain-data property (UInt32, Float64, pid_t, AudioObjectID, ASBD…).
    public static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               as initial: T) throws -> T {
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        try check(status, "get \(code(selector)) of object \(object)")
        return value
    }

    public static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        try read(object, selector, scope: scope, as: UInt32(0))
    }

    /// Missing or unreadable properties read as false.
    public static func readBool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        ((try? readUInt32(object, selector, scope: scope)) ?? 0) != 0
    }

    public static func readFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> Float64 {
        try read(object, selector, scope: scope, as: Float64(0))
    }

    /// Reads a CFString property. The HAL hands out a +1 reference, which we take over.
    public static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        try check(status, "get string \(code(selector)) of object \(object)")
        return value.map { $0.takeRetainedValue() as String } ?? ""
    }

    public static func readObjectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "size of \(code(selector))")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        if count == 0 { return [] }
        var list = [AudioObjectID](repeating: unknownObject, count: count)
        try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &list), "get \(code(selector))")
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    public static func readASBD(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> AudioStreamBasicDescription {
        try read(object, selector, scope: scope, as: AudioStreamBasicDescription())
    }

    // MARK: System object

    public static func defaultInputDevice() -> AudioDeviceID? {
        let id = (try? read(systemObject, kAudioHardwarePropertyDefaultInputDevice, as: unknownObject)) ?? unknownObject
        return id == unknownObject ? nil : id
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        let id = (try? read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, as: unknownObject)) ?? unknownObject
        return id == unknownObject ? nil : id
    }

    public static func allDevices() -> [AudioDeviceID] {
        (try? readObjectIDs(systemObject, kAudioHardwarePropertyDevices)) ?? []
    }

    public static func deviceUID(_ device: AudioDeviceID) -> String? {
        guard let uid = try? readString(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        return uid
    }

    public static func name(_ object: AudioObjectID) -> String {
        (try? readString(object, kAudioObjectPropertyName)) ?? "?"
    }

    /// kAudioHardwarePropertyTranslateUIDToDevice; nil when no such device exists.
    public static func device(forUID uid: String) -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var out = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &out)
        }
        return status == noErr && out != unknownObject ? out : nil
    }

    /// kAudioHardwarePropertyTranslatePIDToProcessObject; nil when the PID is not (yet) a Core Audio client.
    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var out = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &out)
        return status == noErr && out != unknownObject ? out : nil
    }

    /// Every Core Audio client process object (macOS 14.2+).
    public static func processObjects() throws -> [AudioObjectID] {
        try readObjectIDs(systemObject, kAudioHardwarePropertyProcessObjectList)
    }

    // MARK: Devices and streams

    public static func streams(of device: AudioDeviceID, input: Bool) -> [AudioStreamID] {
        (try? readObjectIDs(device, kAudioDevicePropertyStreams,
                            scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)) ?? []
    }

    /// Total channel count in the given direction (from the stream configuration).
    public static func channelCount(of device: AudioDeviceID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration,
                        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Virtual format of the first stream in a direction — what an IOProc on the device receives.
    public static func firstStreamVirtualFormat(_ device: AudioDeviceID, input: Bool) throws -> (stream: AudioStreamID, format: AudioStreamBasicDescription) {
        guard let first = streams(of: device, input: input).first else {
            throw CoreAudioError(kAudioHardwareBadStreamError, "device \(device) has no \(input ? "input" : "output") streams")
        }
        return (first, try readASBD(first, kAudioStreamPropertyVirtualFormat))
    }
}

/// Host time (mach_absolute_time) conversions. The HAL stamps every IO buffer with this clock.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Host ticks per second (24 MHz on Apple Silicon).
    public static var ticksPerSecond: Double { 1e9 * Double(timebase.denom) / Double(timebase.numer) }

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }

    /// Signed seconds from `start` to `end`.
    public static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? seconds(end - start) : -seconds(start - end)
    }

    public static func ticks(_ seconds: Double) -> UInt64 {
        seconds <= 0 ? 0 : UInt64((seconds * ticksPerSecond).rounded())
    }

    /// `base` moved by a signed number of seconds (clamped at zero).
    public static func offset(_ base: UInt64, by seconds: Double) -> UInt64 {
        if seconds >= 0 { return base &+ ticks(seconds) }
        let back = ticks(-seconds)
        return back >= base ? 0 : base - back
    }
}

/// A HAL property listener registered through the C function-pointer API.
///
/// `AudioObjectRemovePropertyListenerBlock` never matches a Swift closure (Swift re-bridges the
/// closure to a new block on every call, so removal silently does nothing — verified on macOS 26.6.2).
/// The C API with a context pointer removes deterministically.
///
/// The handler runs on `queue`. Thread-safe; `invalidate()` may be called from any thread and is
/// idempotent (also called from deinit).
public final class HALListener: @unchecked Sendable {
    private final class Box {
        let queue: DispatchQueue
        let handler: () -> Void
        let active = OSAllocatedUnfairLock(initialState: true)
        init(queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            self.handler = handler
        }
    }

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
        box.queue.async {
            if box.active.withLock({ $0 }) { box.handler() }
        }
        return noErr
    }

    public let object: AudioObjectID
    public let selector: AudioObjectPropertySelector
    private var address: AudioObjectPropertyAddress
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?    // guarded by `lock`

    public init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                queue: DispatchQueue, handler: @escaping () -> Void) throws {
        self.object = object
        self.selector = selector
        self.address = HAL.address(selector, scope)
        let context = Unmanaged.passRetained(Box(queue: queue, handler: handler)).toOpaque()
        let status = AudioObjectAddPropertyListener(object, &address, HALListener.proc, context)
        guard status == noErr else {
            Unmanaged<Box>.fromOpaque(context).release()
            throw CoreAudioError(status, "add listener \(HAL.code(selector)) on object \(object)")
        }
        lock.withLock { self.context = context }
    }

    public func invalidate() {
        let taken: UnsafeMutableRawPointer? = lock.withLock {
            defer { self.context = nil }
            return self.context
        }
        guard let context = taken else { return }
        let box = Unmanaged<Box>.fromOpaque(context)
        box.takeUnretainedValue().active.withLock { $0 = false }
        var a = address
        let status = AudioObjectRemovePropertyListener(object, &a, HALListener.proc, context)
        // A notification may be in flight on a HAL thread; release the context a little later.
        // If removal failed for another reason, leaking the tiny box is the safe choice.
        if status == noErr || status == kAudioHardwareBadObjectError {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { box.release() }
        }
    }

    deinit { invalidate() }
}
