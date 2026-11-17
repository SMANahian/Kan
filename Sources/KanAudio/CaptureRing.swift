import CoreAudio
import Darwin
import Foundation

/// Which buffers of an IOProc's input `AudioBufferList` belong to the stream being recorded.
/// Interleaved streams arrive as one buffer with N channels, non-interleaved ones as N buffers.
public struct InputLayout: Sendable, Equatable {
    public var firstBuffer: Int
    public var bufferCount: Int

    public init(firstBuffer: Int = 0, bufferCount: Int = 1) {
        self.firstBuffer = max(0, firstBuffer)
        self.bufferCount = max(1, bufferCount)
    }

    public static func forStream(_ format: AudioStreamBasicDescription, firstBuffer: Int = 0) -> InputLayout {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        return InputLayout(firstBuffer: firstBuffer, bufferCount: nonInterleaved ? Int(format.mChannelsPerFrame) : 1)
    }
}

/// Hands audio from a HAL IOProc (real-time thread) to a worker queue.
///
/// Single producer, single consumer. The producer side (`write`) is real-time safe: no allocation,
/// no ARC traffic, no blocking — it mixes the input to mono straight into preallocated storage under
/// `os_unfair_lock_trylock` and drops the buffer if the consumer momentarily holds the lock or the
/// ring is full. Every written buffer records an anchor (ring frame index ↔ HAL host time) so the
/// consumer can place audio on the session clock and see drops as host-time jumps.
///
/// The consumer side (`read`) must be called from one thread/queue at a time.
public final class CaptureRing: @unchecked Sendable {
    public struct Anchor: Sendable, Equatable, Codable {
        /// Ring frame index (source sample rate, since the ring was created) of the buffer's first frame.
        public var frame: Int64
        /// `AudioTimeStamp.mHostTime` of that frame.
        public var hostTime: UInt64

        public init(frame: Int64, hostTime: UInt64) {
            self.frame = frame
            self.hostTime = hostTime
        }
    }

    public struct Batch: Sendable {
        /// Mono samples at the ring's sample rate.
        public var samples: [Float]
        /// Ring frame index of `samples[0]`.
        public var firstFrame: Int64
        public var anchors: [Anchor]
        /// Host time of `samples[0]`, derived from the anchors (nil when the batch is empty).
        public var firstHostTime: UInt64?
        public var isEmpty: Bool { samples.isEmpty }
    }

    /// Mutable state shared by both sides. Lives in raw memory so the IOProc can reach it through a
    /// plain pointer (capturing a class reference would retain/release on the real-time thread).
    struct Core {
        var lock: UnsafeMutablePointer<os_unfair_lock>
        var samples: UnsafeMutablePointer<Float>
        var capacity: Int
        var anchors: UnsafeMutablePointer<Anchor>
        var anchorCapacity: Int
        // Guarded by `lock`.
        var writeFrame: Int64 = 0
        var readFrame: Int64 = 0
        var anchorWrite: Int = 0
        var anchorRead: Int = 0
        var droppedBuffers: Int = 0
        var callbacks: Int = 0
        var lastCallbackHostTime: UInt64 = 0
        // Touched only by the producer thread, folded into `droppedBuffers` under the lock.
        var producerPendingDrops: Int = 0
    }

    public let sampleRate: Double
    public let capacityFrames: Int
    let core: UnsafeMutablePointer<Core>
    private let scratch: UnsafeMutablePointer<Float>
    private let anchorScratch: UnsafeMutablePointer<Anchor>

    public init(sampleRate: Double, seconds: Double = 10, maxAnchors: Int = 8192) {
        self.sampleRate = sampleRate
        let capacity = max(1024, Int((max(0.5, seconds) * max(sampleRate, 8_000)).rounded(.up)))
        self.capacityFrames = capacity
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        let anchorCapacity = max(64, maxAnchors)
        let anchors = UnsafeMutablePointer<Anchor>.allocate(capacity: anchorCapacity)
        anchors.initialize(repeating: Anchor(frame: 0, hostTime: 0), count: anchorCapacity)
        core = .allocate(capacity: 1)
        core.initialize(to: Core(lock: lock, samples: samples, capacity: capacity, anchors: anchors, anchorCapacity: anchorCapacity))
        scratch = .allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
        anchorScratch = .allocate(capacity: anchorCapacity)
        anchorScratch.initialize(repeating: Anchor(frame: 0, hostTime: 0), count: anchorCapacity)
    }

    deinit {
        let c = core.pointee
        c.samples.deallocate()
        c.anchors.deallocate()
        c.lock.deinitialize(count: 1)
        c.lock.deallocate()
        core.deinitialize(count: 1)
        core.deallocate()
        scratch.deallocate()
        anchorScratch.deallocate()
    }

    // MARK: Producer (real-time safe)

    /// Mixes the layout's buffers to mono and appends them. Real-time safe.
    public func write(_ bufferList: UnsafePointer<AudioBufferList>, layout: InputLayout, hostTime: UInt64) {
        CaptureRing.write(core, bufferList, layout, hostTime)
    }

    /// Appends mono samples. Real-time safe.
    public func write(mono: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        guard let base = mono.baseAddress else { return }
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(mono.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(mutating: base)))
        withUnsafePointer(to: &buffer) { CaptureRing.write(core, $0, InputLayout(), hostTime) }
    }

    /// The real-time entry point. Takes only plain pointers and values.
    @inline(__always)
    static func write(_ core: UnsafeMutablePointer<Core>, _ abl: UnsafePointer<AudioBufferList>,
                      _ layout: InputLayout, _ hostTime: UInt64) {
        guard os_unfair_lock_trylock(core.pointee.lock) else {
            core.pointee.producerPendingDrops &+= 1
            return
        }
        defer { os_unfair_lock_unlock(core.pointee.lock) }
        core.pointee.callbacks &+= 1
        core.pointee.lastCallbackHostTime = hostTime
        if core.pointee.producerPendingDrops > 0 {
            core.pointee.droppedBuffers &+= core.pointee.producerPendingDrops
            core.pointee.producerPendingDrops = 0
        }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let first = layout.firstBuffer
        let end = min(list.count, first + layout.bufferCount)
        guard first < end else { return }
        var frames = Int.max
        var totalChannels = 0
        for b in first..<end {
            let buffer = list[b]
            guard buffer.mData != nil else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            totalChannels += channels
        }
        guard frames > 0, frames != Int.max else { return }

        let capacity = core.pointee.capacity
        let used = Int(core.pointee.writeFrame - core.pointee.readFrame)
        guard frames <= capacity - used else {
            core.pointee.droppedBuffers &+= 1        // consumer stalled: drop the newest buffer
            return
        }

        let anchorCapacity = core.pointee.anchorCapacity
        core.pointee.anchors[core.pointee.anchorWrite % anchorCapacity] =
            Anchor(frame: core.pointee.writeFrame, hostTime: hostTime)
        core.pointee.anchorWrite &+= 1

        let scale = 1 / Float(totalChannels)
        let start = Int(core.pointee.writeFrame % Int64(capacity))
        let firstPart = min(frames, capacity - start)
        mix(into: core.pointee.samples + start, count: firstPart, sourceOffset: 0,
            list: list, first: first, end: end, scale: scale)
        if firstPart < frames {
            mix(into: core.pointee.samples, count: frames - firstPart, sourceOffset: firstPart,
                list: list, first: first, end: end, scale: scale)
        }
        core.pointee.writeFrame += Int64(frames)
    }

    @inline(__always)
    private static func mix(into dst: UnsafeMutablePointer<Float>, count: Int, sourceOffset: Int,
                            list: UnsafeMutableAudioBufferListPointer, first: Int, end: Int, scale: Float) {
        if end - first == 1, list[first].mNumberChannels <= 1, let data = list[first].mData {
            dst.update(from: data.assumingMemoryBound(to: Float.self) + sourceOffset, count: count)
            return
        }
        dst.update(repeating: 0, count: count)
        for b in first..<end {
            let buffer = list[b]
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let src = data.assumingMemoryBound(to: Float.self) + sourceOffset * channels
            if channels == 1 {
                for i in 0..<count { dst[i] += src[i] }
            } else {
                for i in 0..<count {
                    var sum: Float = 0
                    for c in 0..<channels { sum += src[i * channels + c] }
                    dst[i] += sum
                }
            }
        }
        for i in 0..<count { dst[i] *= scale }
    }

    // MARK: Consumer

    /// Takes everything written so far. The lock is held only for two memcpys.
    public func read() -> Batch {
        os_unfair_lock_lock(core.pointee.lock)
        let capacity = core.pointee.capacity
        let firstFrame = core.pointee.readFrame
        let count = Int(core.pointee.writeFrame - firstFrame)
        let start = Int(firstFrame % Int64(capacity))
        let firstPart = min(count, capacity - start)
        scratch.update(from: core.pointee.samples + start, count: firstPart)
        if firstPart < count { (scratch + firstPart).update(from: core.pointee.samples, count: count - firstPart) }
        core.pointee.readFrame += Int64(count)

        let anchorCapacity = core.pointee.anchorCapacity
        if core.pointee.anchorWrite - core.pointee.anchorRead > anchorCapacity {
            core.pointee.anchorRead = core.pointee.anchorWrite - anchorCapacity   // oldest were overwritten
        }
        let anchorCount = core.pointee.anchorWrite - core.pointee.anchorRead
        for i in 0..<anchorCount {
            anchorScratch[i] = core.pointee.anchors[(core.pointee.anchorRead + i) % anchorCapacity]
        }
        core.pointee.anchorRead = core.pointee.anchorWrite
        os_unfair_lock_unlock(core.pointee.lock)

        let samples = Array(UnsafeBufferPointer(start: scratch, count: count))
        let anchors = Array(UnsafeBufferPointer(start: anchorScratch, count: anchorCount))
        var firstHost: UInt64?
        if count > 0, let anchor = anchors.first(where: { $0.frame >= firstFrame }) {
            // Normally anchor.frame == firstFrame; extrapolate if older anchors were lost.
            firstHost = HostClock.offset(anchor.hostTime, by: -Double(anchor.frame - firstFrame) / sampleRate)
        }
        return Batch(samples: samples, firstFrame: firstFrame, anchors: anchors, firstHostTime: firstHost)
    }

    public struct Stats: Sendable, Equatable {
        public var callbacks: Int
        public var droppedBuffers: Int
        public var lastCallbackHostTime: UInt64
        public var framesWritten: Int64
    }

    public var stats: Stats {
        os_unfair_lock_lock(core.pointee.lock)
        defer { os_unfair_lock_unlock(core.pointee.lock) }
        return Stats(callbacks: core.pointee.callbacks, droppedBuffers: core.pointee.droppedBuffers,
                     lastCallbackHostTime: core.pointee.lastCallbackHostTime, framesWritten: core.pointee.writeFrame)
    }
}
