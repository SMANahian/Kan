import Foundation

/// Post-call removal of the remote voices that leak into the microphone over loudspeakers.
///
/// With speakers the mic also hears "them" 10–300 ms later. Kan never uses Apple's voice processing
/// (it ducks the call app by 8–30 dB); instead, after the call:
///  1. estimate the acoustic lag (call → mic) by cross-correlating 10 ms log-energy envelopes,
///  2. mark mic frames whose envelope tracks the lagged call envelope and that aren't louder than
///     the predicted echo (no double talk),
///  3. mute runs of echo frames (≥ 0.3 s) and turn isolated echo frames down, before VAD/ASR on the
///     mic track, so the echo is neither detected as speech nor heard inside a decode chunk.
/// `EchoDedup` then flags mic segments that still repeat what the remote side was saying at that moment.
///
/// When there is no echo (headphones), no lag with a clear correlation is found and nothing changes.
/// Pure functions; thread-safe.
public enum EchoGate {
    /// 10 ms at 16 kHz.
    public static let hopSamples = 160
    /// Largest lag searched: 400 ms.
    public static let maxLagFrames = 40

    public struct Report: Sendable, Equatable {
        /// Estimated call → mic delay, nil when no echo was found.
        public var lagSeconds: Double?
        public var correlation: Float
        public var flaggedFrames: Int
        public var totalFrames: Int
        /// Echo stretches that were muted.
        public var mutedRanges: [TimeRange] = []

        public var flaggedFraction: Double { totalFrames > 0 ? Double(flaggedFrames) / Double(totalFrames) : 0 }
    }

    /// Detects echo in `mic` (16 kHz, same clock as `call`): mutes runs of echo frames and multiplies
    /// the remaining isolated echo frames by `attenuation`.
    @discardableResult
    public static func suppress(mic: inout [Float], call: [Float], attenuation: Float = 0.1) -> Report {
        let micEnvelope = logEnergyEnvelope(mic)
        let callEnvelope = logEnergyEnvelope(call)
        guard let (lag, correlation) = estimateLag(mic: micEnvelope, call: callEnvelope) else {
            return Report(lagSeconds: nil, correlation: 0, flaggedFrames: 0, totalFrames: micEnvelope.count)
        }
        let mask = echoMask(micEnvelope: micEnvelope, callEnvelope: callEnvelope, lag: lag)
        apply(mask: mask, to: &mic, attenuation: attenuation)
        let runs = echoRanges(mask: mask)
        let count = mic.count
        mic.withUnsafeMutableBufferPointer { samples in
            for range in runs {
                let start = max(0, Int(range.start * AudioLoader.sampleRate))
                let end = min(count, Int(range.end * AudioLoader.sampleRate))
                if start < end { for s in start..<end { samples[s] = 0 } }
            }
        }
        return Report(lagSeconds: Double(lag * hopSamples) / AudioLoader.sampleRate, correlation: correlation,
                      flaggedFrames: mask.lazy.filter { $0 }.count, totalFrames: mask.count, mutedRanges: runs)
    }

    /// Stretches of echo: runs of flagged frames, bridged over gaps shorter than `bridge` seconds
    /// (frames the mask missed) and kept when at least `minimumLength` long. Scattered false
    /// positives inside the user's own speech don't form such runs.
    public static func echoRanges(mask: [Bool], hop: Int = hopSamples, bridge: Double = 0.2,
                                  minimumLength: Double = 0.3) -> [TimeRange] {
        let frame = Double(hop) / AudioLoader.sampleRate
        var runs: [TimeRange] = []
        var start: Int?
        for (index, flagged) in mask.enumerated() {
            if flagged, start == nil { start = index }
            if !flagged, let first = start {
                runs.append(TimeRange(Double(first) * frame, Double(index) * frame))
                start = nil
            }
        }
        if let first = start { runs.append(TimeRange(Double(first) * frame, Double(mask.count) * frame)) }
        var bridged: [TimeRange] = []
        for run in runs {
            if let last = bridged.last, run.start - last.end < bridge {
                bridged[bridged.count - 1] = TimeRange(last.start, run.end)
            } else {
                bridged.append(run)
            }
        }
        return bridged.filter { $0.duration >= minimumLength }
    }

    /// 10·log10(mean square) per hop; digital silence is −100 dB.
    public static func logEnergyEnvelope(_ x: [Float], hop: Int = hopSamples) -> [Float] {
        guard hop > 0, x.count >= hop else { return [] }
        let frames = x.count / hop
        var envelope = [Float](repeating: -100, count: frames)
        x.withUnsafeBufferPointer { samples in
            for frame in 0..<frames {
                var energy: Float = 0
                let base = frame * hop
                for j in 0..<hop {
                    let v = samples[base + j]
                    energy += v * v
                }
                envelope[frame] = 10 * log10(energy / Float(hop) + 1e-10)
            }
        }
        return envelope
    }

    /// Lag (envelope frames, call → mic) with the highest Pearson correlation, nil if below
    /// `minCorrelation`.
    ///
    /// Only frames where the call is playing (> `activeAboveDB`) count: echo exists only then, and in
    /// a normal conversation the user talks while the remote side is silent, which would otherwise
    /// swamp the correlation.
    public static func estimateLag(mic: [Float], call: [Float], minCorrelation: Float = 0.3,
                                   activeAboveDB: Float = -50) -> (lag: Int, correlation: Float)? {
        let n = min(mic.count, call.count)
        guard n > maxLagFrames * 4 else { return nil }
        let active = (0..<(n - maxLagFrames)).filter { call[$0] > activeAboveDB }
        guard active.count >= 200 else { return nil }   // at least 2 s of remote audio
        var best = (lag: 0, correlation: Float(-1))
        mic.withUnsafeBufferPointer { m in
            call.withUnsafeBufferPointer { c in
                for lag in 0...maxLagFrames {
                    let r = pearson(active.lazy.map { (Double(m[$0 + lag]), Double(c[$0])) }, count: active.count)
                    if r > best.correlation { best = (lag, r) }
                }
            }
        }
        return best.correlation >= minCorrelation ? best : nil
    }

    /// Pearson correlation of `count` (x, y) pairs.
    static func pearson<S: Sequence>(_ pairs: S, count: Int) -> Float where S.Element == (Double, Double) {
        guard count > 2 else { return 0 }
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for (x, y) in pairs {
            sa += x
            sb += y
            saa += x * x
            sbb += y * y
            sab += x * y
        }
        let n = Double(count)
        let covariance = sab - sa * sb / n
        let varianceA = saa - sa * sa / n
        let varianceB = sbb - sb * sb / n
        guard varianceA > 1e-9, varianceB > 1e-9 else { return 0 }
        return Float(covariance / (varianceA * varianceB).squareRoot())
    }

    /// True for each 10 ms mic frame that is (mostly) echo of the call track.
    ///
    /// Predicted echo level = call level + the typical coupling (median mic − call over call-active
    /// frames). A frame is echo when its 0.5 s neighbourhood correlates with the lagged call
    /// envelope (≥ `correlationThreshold`), the call is active and the mic is not louder than the
    /// predicted echo + `doubleTalkMarginDB` (louder means the user is talking too).
    public static func echoMask(micEnvelope mic: [Float], callEnvelope call: [Float], lag: Int, window: Int = 50,
                                correlationThreshold: Float = 0.6, doubleTalkMarginDB: Float = 1.5) -> [Bool] {
        let n = mic.count
        var mask = [Bool](repeating: false, count: n)
        let limit = min(n, call.count + lag)
        guard lag >= 0, window > 1, limit > lag else { return mask }

        var differences: [Float] = []
        for i in lag..<limit where call[i - lag] > -45 { differences.append(mic[i] - call[i - lag]) }
        guard !differences.isEmpty else { return mask }
        differences.sort()
        let coupling = differences[differences.count / 2]

        mic.withUnsafeBufferPointer { m in
            call.withUnsafeBufferPointer { c in
                var i = lag
                while i + window <= limit {
                    if pearson(m, i, c, i - lag, count: window) >= correlationThreshold {
                        for k in 0..<window {
                            let callLevel = c[i - lag + k]
                            if callLevel > -50 && m[i + k] <= callLevel + coupling + doubleTalkMarginDB {
                                mask[i + k] = true
                            }
                        }
                    }
                    i += window / 2
                }
            }
        }
        return mask
    }

    /// Multiplies the samples of every flagged frame by `attenuation` (0 = mute).
    public static func apply(mask: [Bool], to mic: inout [Float], attenuation: Float, hop: Int = hopSamples) {
        let count = mic.count
        mic.withUnsafeMutableBufferPointer { samples in
            for (frame, isEcho) in mask.enumerated() where isEcho {
                let start = frame * hop
                let end = min(count, start + hop)
                guard start < end else { continue }
                for s in start..<end { samples[s] *= attenuation }
            }
        }
    }

    static func pearson(_ a: UnsafeBufferPointer<Float>, _ aStart: Int, _ b: UnsafeBufferPointer<Float>, _ bStart: Int,
                        count n: Int) -> Float {
        guard n > 2, aStart >= 0, bStart >= 0, aStart + n <= a.count, bStart + n <= b.count else { return 0 }
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for i in 0..<n {
            let x = Double(a[aStart + i]), y = Double(b[bStart + i])
            sa += x
            sb += y
            saa += x * x
            sbb += y * y
            sab += x * y
        }
        let count = Double(n)
        let covariance = sab - sa * sb / count
        let varianceA = saa - sa * sa / count
        let varianceB = sbb - sb * sb / count
        guard varianceA > 1e-9, varianceB > 1e-9 else { return 0 }
        return Float(covariance / (varianceA * varianceB).squareRoot())
    }
}
