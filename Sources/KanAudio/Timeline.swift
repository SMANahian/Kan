import Accelerate
import Foundation

/// Contents of `anchors.json`: how each 16 kHz track maps to host time, plus every place where the
/// recorder inserted silence or dropped audio to keep the two tracks on one clock.
///
/// Track frame `f` was captured at about `startHostTime + f / sampleRate` seconds (host clock).
/// Anchors record the exact correspondence at the start of every source stream, after every
/// correction and every ~5 s; interpolate between neighbours for sub-sample alignment.
public struct RecordingAnchors: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Sample rate of me.wav / them.wav.
    public var sampleRate: Double
    public var startedAt: Date
    /// `mach_absolute_time()` at `startedAt` (frame 0 of both tracks).
    public var startHostTime: UInt64
    public var hostTicksPerSecond: Double
    public var me: Track?
    public var them: Track?

    public struct Track: Codable, Sendable, Equatable {
        public var file: String
        public var frames: Int64
        public var sources: [Source]
        public var anchors: [Anchor]
        public var edits: [Edit]

        public init(file: String, frames: Int64 = 0, sources: [Source] = [], anchors: [Anchor] = [], edits: [Edit] = []) {
            self.file = file
            self.frames = frames
            self.sources = sources
            self.anchors = anchors
            self.edits = edits
        }
    }

    /// One capture stream feeding the track (a mic device, a process tap; a new one after each rebuild).
    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        public var sampleRate: Double
        public var startFrame: Int64

        public init(name: String, sampleRate: Double, startFrame: Int64) {
            self.name = name
            self.sampleRate = sampleRate
            self.startFrame = startFrame
        }
    }

    public struct Anchor: Codable, Sendable, Equatable {
        /// Track frame (16 kHz).
        public var frame: Int64
        /// Host time at which that frame was captured.
        public var hostTime: UInt64
        /// Host-clock seconds since `startHostTime` (redundant, for readers that don't do host math).
        public var seconds: Double

        public init(frame: Int64, hostTime: UInt64, seconds: Double) {
            self.frame = frame
            self.hostTime = hostTime
            self.seconds = seconds
        }
    }

    public struct Edit: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case silence, drop }
        public var kind: Kind
        /// Track frame where silence was inserted / where the dropped audio would have started.
        public var frame: Int64
        public var frames: Int64
        /// "start", "gap", "pause", "noSource", "drift", "stop", "trim".
        public var reason: String

        public init(kind: Kind, frame: Int64, frames: Int64, reason: String) {
            self.kind = kind
            self.frame = frame
            self.frames = frames
            self.reason = reason
        }
    }

    public init(version: Int = RecordingAnchors.currentVersion, sampleRate: Double, startedAt: Date, startHostTime: UInt64,
                hostTicksPerSecond: Double = HostClock.ticksPerSecond, me: Track? = nil, them: Track? = nil) {
        self.version = version
        self.sampleRate = sampleRate
        self.startedAt = startedAt
        self.startHostTime = startHostTime
        self.hostTicksPerSecond = hostTicksPerSecond
        self.me = me
        self.them = them
    }
}

/// Keeps one track on the session clock: frame `f` of the file belongs to host time
/// `startHostTime + f / sampleRate`. Pure value type.
///
/// Audio is placed where its host time says it belongs. A lag beyond `toleranceFrames` (a gap from a
/// rebuild, a device switch, dropped buffers, slow device clock) is filled with silence; a lead beyond
/// it (fast device clock, overlapping timestamps after a restart) is corrected by dropping samples.
/// Within the tolerance nothing is touched, so normal IO jitter never edits the audio.
public struct TrackTimeline: Sendable, Equatable {
    public let sampleRate: Double
    public let startHostTime: UInt64
    public let toleranceFrames: Int64
    public private(set) var framesWritten: Int64 = 0

    public struct Placement: Sendable, Equatable {
        /// Silence to write before the audio.
        public var padFrames: Int64
        /// Samples to skip from the start of the audio.
        public var dropFrames: Int
        /// Track frame at which the first kept sample lands.
        public var frame: Int64

        public init(padFrames: Int64, dropFrames: Int, frame: Int64) {
            self.padFrames = padFrames
            self.dropFrames = dropFrames
            self.frame = frame
        }
    }

    public init(sampleRate: Double = 16_000, startHostTime: UInt64, toleranceSeconds: Double = 0.1) {
        self.sampleRate = sampleRate
        self.startHostTime = startHostTime
        self.toleranceFrames = Int64((toleranceSeconds * sampleRate).rounded())
    }

    /// Track frame that belongs to `hostTime` (negative before the session start).
    public func expectedFrame(atHostTime hostTime: UInt64) -> Int64 {
        Int64((HostClock.seconds(from: startHostTime, to: hostTime) * sampleRate).rounded())
    }

    /// Decides where `count` samples whose first sample was captured at `hostTime` go, and advances.
    /// `exact` ignores the tolerance — for the first samples of a new stream or after real-time
    /// padding, which are discontinuities anyway.
    public mutating func place(count: Int, firstSampleHostTime hostTime: UInt64, exact: Bool = false) -> Placement {
        let gap = expectedFrame(atHostTime: hostTime) - framesWritten
        let tolerance = exact ? 0 : toleranceFrames
        if gap > tolerance {
            framesWritten += gap
            let frame = framesWritten
            framesWritten += Int64(count)
            return Placement(padFrames: gap, dropFrames: 0, frame: frame)
        }
        if gap < -tolerance {
            let drop = Int(min(Int64(count), -gap))
            let frame = framesWritten
            framesWritten += Int64(count - drop)
            return Placement(padFrames: 0, dropFrames: drop, frame: frame)
        }
        let frame = framesWritten
        framesWritten += Int64(count)
        return Placement(padFrames: 0, dropFrames: 0, frame: frame)
    }

    /// Appends samples that directly continue the previous ones (e.g. a converter's flushed tail).
    public mutating func appendContiguous(_ count: Int) {
        framesWritten += Int64(max(0, count))
    }

    /// Silence needed to bring the track up to `frame`; advances by that amount.
    public mutating func padTo(frame: Int64) -> Int64 {
        let pad = max(0, frame - framesWritten)
        framesWritten += pad
        return pad
    }

    public mutating func truncate(to frames: Int64) {
        framesWritten = min(framesWritten, max(0, frames))
    }
}

/// Smoothed RMS level for a meter: instant attack, ~300 ms release.
public struct LevelMeter: Sendable, Equatable {
    public private(set) var level: Float = 0
    public var releaseSeconds: Double

    public init(releaseSeconds: Double = 0.3) {
        self.releaseSeconds = releaseSeconds
    }

    public mutating func add(rms: Float, elapsed: Double) {
        let r = min(max(rms.isFinite ? rms : 0, 0), 1)
        if r >= level {
            level = r
        } else {
            let k = Float(1 - exp(-max(0, elapsed) / releaseSeconds))
            level += (r - level) * k
        }
    }

    public mutating func decay(elapsed: Double) { add(rms: 0, elapsed: elapsed) }

    public mutating func reset() { level = 0 }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(base, 1, &value, vDSP_Length(samples.count))
        return value
    }

    public static func rms(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { rms($0) } }

    /// 10^(dB/20): -50 dBFS ≈ 0.00316.
    public static func amplitude(dBFS: Double) -> Float { Float(pow(10, dBFS / 20)) }
}

/// Paces rebuilds: creating and destroying aggregates makes the HAL re-publish properties, and
/// reacting to every notification can snowball into rebuild storms that stall coreaudiod.
///
/// A token bucket: a burst of up to `maxEvents`, then one every `windowSeconds / maxEvents`, so at
/// most `maxEvents` per window in the long run. A caller that is refused waits `delay(at:)` and tries
/// again — a used-up budget slows recovery down, it never ends it.
public struct RebuildLimiter: Sendable, Equatable {
    public let maxEvents: Int
    public let windowSeconds: Double
    private var tokens: Double
    private var updatedAt: Double?

    public init(maxEvents: Int = 5, windowSeconds: Double = 60) {
        self.maxEvents = max(1, maxEvents)
        self.windowSeconds = max(0, windowSeconds)
        self.tokens = Double(self.maxEvents)
    }

    /// Seconds between two attempts once the burst is used up.
    public var interval: Double { windowSeconds / Double(maxEvents) }

    /// Records an attempt at `now` (seconds on any monotonic clock) if the budget allows it.
    public mutating func allow(at now: Double) -> Bool {
        refill(at: now)
        guard tokens >= 1 - RebuildLimiter.epsilon else { return false }
        tokens = max(0, tokens - 1)
        return true
    }

    /// Seconds from `now` until `allow(at:)` succeeds (0 when it would now).
    public func delay(at now: Double) -> Double {
        var copy = self
        copy.refill(at: now)
        return copy.tokens >= 1 - RebuildLimiter.epsilon ? 0 : (1 - copy.tokens) * interval
    }

    private static let epsilon = 1e-9

    private mutating func refill(at now: Double) {
        guard let last = updatedAt else {
            updatedAt = now
            return
        }
        guard now > last else { return }
        tokens = interval > 0 ? min(Double(maxEvents), tokens + (now - last) / interval) : Double(maxEvents)
        updatedAt = now
    }
}
