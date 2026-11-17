import CoreAudio
import Foundation
import KanAudio
import KanCore
import KanTestKit

private func sine(_ count: Int, rate: Double, frequency: Double = 440, amplitude: Float = 0.5, phase: Int = 0) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double(phase + $0) / rate)) }
}

private func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
}

/// Writes a WAV with an arbitrary format (for reader tests).
private func writeRawWAV(_ url: URL, formatTag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16, data: [UInt8],
                         trailingChunk: Bool = false) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let block = channels * (bits / 8)
    let trailer: [UInt8] = trailingChunk ? Array("LIST".utf8) + [4, 0, 0, 0] + Array("INFO".utf8) : []
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + data.count + trailer.count))
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(formatTag); u16(channels); u32(rate)
    u32(rate * UInt32(block)); u16(block); u16(bits)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(data.count)); d.append(contentsOf: data)
    d.append(contentsOf: trailer)
    try d.write(to: url)
}

func wavSuite() -> TestSuite {
    let suite = TestSuite("WAV")

    suite.test("round trip at 16-bit precision, written in odd chunks") {
        let dir = scratchDirectory("wav-roundtrip")
        let url = dir.appendingPathComponent("t.wav")
        let signal = sine(16_000, rate: 16_000) + [1.5, -1.5]          // last two clip
        let writer = try WAVWriter(url: url)
        var i = 0
        for n in [1, 7, 333, 4_801] + Array(repeating: 2_000, count: 10) where i < signal.count {
            let end = min(signal.count, i + n)
            try writer.write(Array(signal[i..<end]))
            i = end
        }
        try expectEqual(writer.frameCount, 16_002)
        try writer.close()
        try writer.close()                                                // idempotent
        try expectEqual(fileSize(url), 44 + 32_004)
        let header = try Data(contentsOf: url).prefix(44)
        try expectEqual(String(decoding: header.prefix(4), as: UTF8.self), "RIFF")
        let reader = try WAVReader(url: url)
        try expectEqual(reader.format, WAVReader.Format(sampleRate: 16_000, channels: 1, bitsPerSample: 16, isFloat: false, blockAlign: 2))
        try expectEqual(reader.frameCount, 16_002)
        try expect(!reader.headerIsStale)
        let back = try reader.readAllMono()
        var worst: Float = 0
        for k in 0..<16_000 { worst = max(worst, abs(back[k] - signal[k])) }
        try expect(worst <= 1.5 / 32_768, "max error \(worst)")
        try expectClose(Double(back[16_000]), 32_767.0 / 32_768, tolerance: 1e-6)
        try expectClose(Double(back[16_001]), -32_767.0 / 32_768, tolerance: 1e-6)
    }

    suite.test("crash safety: the header is rewritten while recording and stale headers are recovered") {
        let dir = scratchDirectory("wav-crash")
        let url = dir.appendingPathComponent("me.wav")
        let writer = try WAVWriter(url: url, headerUpdateInterval: 0.05)
        try writer.write(sine(8_000, rate: 16_000))
        try await Task.sleep(nanoseconds: 80_000_000)
        try writer.write(sine(8_000, rate: 16_000))                   // triggers a header update
        try writer.write(sine(4_000, rate: 16_000))                   // within the interval: header lags
        // "Crash": read the file while the writer still has it open.
        let stale = try WAVReader(url: url)
        try expectEqual(stale.headerFrameCount, 16_000)
        try expectEqual(stale.frameCount, 20_000, "recovered from the file length")
        try expect(stale.headerIsStale)
        try expectEqual(try WAVReader.repairHeader(at: url), true)
        let fixed = try WAVReader(url: url)
        try expectEqual(fixed.headerFrameCount, 20_000)
        try expect(!fixed.headerIsStale)
        try expectEqual(try WAVReader.repairHeader(at: url), false, "nothing left to repair")
        try writer.close()

        // A partial trailing frame (crash mid-write) is ignored and then cut off by the repair.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x12]))
        try handle.close()
        try expectEqual(try WAVReader(url: url).frameCount, 20_000)
        try expectEqual(try WAVReader.repairHeader(at: url), true)
        try expectEqual(fileSize(url), 44 + 40_000)

        // A header that was never updated (data size 0).
        let zero = dir.appendingPathComponent("zero.wav")
        let w2 = try WAVWriter(url: zero, headerUpdateInterval: 3_600)
        try w2.write(sine(1_600, rate: 16_000))
        let r2 = try WAVReader(url: zero)
        try expectEqual(r2.headerFrameCount, 0)
        try expectEqual(r2.frameCount, 1_600)
        try w2.close()
        try expectEqual(try WAVReader(url: zero).headerFrameCount, 1_600)
    }

    suite.test("truncation and silence") {
        let url = scratchDirectory("wav-trunc").appendingPathComponent("t.wav")
        let writer = try WAVWriter(url: url)
        try writer.write(sine(32_000, rate: 16_000))
        try writer.truncate(toFrames: 8_000)
        try expectEqual(writer.frameCount, 8_000)
        try expectEqual(fileSize(url), 44 + 16_000)
        try writer.truncate(toFrames: 9_000)                           // longer: no-op
        try expectEqual(writer.frameCount, 8_000)
        try writer.writeSilence(frames: 20_000)                        // more than one zero buffer
        try writer.write([0.25, 0.25])
        try writer.close()
        let samples = try readMono(url)
        try expectEqual(samples.count, 28_002)
        try expect(maxAbs(samples[8_000..<28_000]) == 0)
        try expectClose(Double(samples[28_001]), 0.25, tolerance: 1e-4)
        try expectClose(Double(samples[100]), Double(sine(101, rate: 16_000)[100]), tolerance: 1e-4, "audio before the cut is intact")
        try expectThrows("writing after close") { try writer.write([0.1]) }
    }

    suite.test("reads ffmpeg-made WAVs with a LIST chunk (Tests/Audio)") {
        let url = testAudioDirectory.appendingPathComponent("a1.wav")
        guard FileManager.default.fileExists(atPath: url.path) else { throw TestSkip("no test audio at \(url.path)") }
        let reader = try WAVReader(url: url)
        try expectEqual(reader.format.sampleRate, 16_000)
        try expectEqual(reader.format.channels, 1)
        try expectEqual(reader.frameCount, 116_564)
        try expect(!reader.headerIsStale)
        try expectClose(reader.duration, 7.285, tolerance: 0.01)
        let samples = try reader.readAllMono()
        try expectEqual(samples.count, 116_564)
        try expect(rms(samples[...]) > 0.01, "speech is audible")
    }

    suite.test("decodes 24-bit, float, 8-bit and stereo WAVs; trailing chunks are not audio") {
        let dir = scratchDirectory("wav-formats")
        let f24 = dir.appendingPathComponent("24.wav")
        // 0.5 and -0.25 in 24-bit little endian.
        try writeRawWAV(f24, formatTag: 1, channels: 1, rate: 48_000, bits: 24, data: [0x00, 0x00, 0x40, 0x00, 0x00, 0xE0])
        try expectEqual(try readMono(f24), [0.5, -0.25])
        let ffloat = dir.appendingPathComponent("float.wav")
        var floats: [UInt8] = []
        for v: Float in [0.125, -1] { withUnsafeBytes(of: v.bitPattern.littleEndian) { floats.append(contentsOf: $0) } }
        try writeRawWAV(ffloat, formatTag: 3, channels: 1, rate: 44_100, bits: 32, data: floats)
        try expectEqual(try readMono(ffloat), [0.125, -1])
        let f8 = dir.appendingPathComponent("8.wav")
        try writeRawWAV(f8, formatTag: 1, channels: 1, rate: 8_000, bits: 8, data: [128, 192, 64])
        try expectEqual(try readMono(f8), [0, 0.5, -0.5])
        let stereo = dir.appendingPathComponent("stereo.wav")
        var pcm: [UInt8] = []
        for v: Int16 in [16_384, 0, -16_384, -16_384] { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        try writeRawWAV(stereo, formatTag: 1, channels: 2, rate: 16_000, bits: 16, data: pcm, trailingChunk: true)
        let reader = try WAVReader(url: stereo)
        try expectEqual(reader.frameCount, 2, "the LIST chunk after data is not audio")
        try expect(!reader.headerIsStale)
        try expectEqual(try reader.readMono(maxFrames: 10), [0.25, -0.5])
        try expectEqual(try WAVReader.repairHeader(at: stereo), false)
        let junk = dir.appendingPathComponent("junk.wav")
        try Data("not a wav file at all".utf8).write(to: junk)
        try expectThrows { _ = try WAVReader(url: junk) }
    }

    return suite
}

func converterSuite() -> TestSuite {
    let suite = TestSuite("SampleRateConverter")

    func interleave(_ left: [Float], _ right: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: left.count * 2)
        for i in 0..<left.count {
            out[2 * i] = left[i]
            out[2 * i + 1] = right[i]
        }
        return out
    }

    func convertChunked(_ input: [Float], rate: Double, channels: Int, chunk: Int) throws -> [Float] {
        let c = try SampleRateConverter(inputRate: rate, inputChannels: channels)
        var out: [Float] = []
        var i = 0
        while i < input.count {
            let end = min(input.count, i + chunk * channels)
            out += c.convert(Array(input[i..<end]))
            i = end
        }
        return out + c.flush()
    }

    suite.test("48 kHz stereo → 16 kHz mono: exact length (±1) for any chunking, chunking-independent output") {
        let frames = 48_000 * 3 + 17
        let left = sine(frames, rate: 48_000, frequency: 440)
        let input = interleave(left, left)
        let reference = try convertChunked(input, rate: 48_000, channels: 2, chunk: frames)
        let expected = Double(frames) / 3
        try expect(abs(Double(reference.count) - expected) <= 1, "\(reference.count) vs \(expected)")
        for chunk in [1, 7, 333, 480, 4_801] {
            let out = try convertChunked(input, rate: 48_000, channels: 2, chunk: chunk)
            try expectEqual(out.count, reference.count, "chunk \(chunk)")
            var worst: Float = 0
            for k in 0..<out.count { worst = max(worst, abs(out[k] - reference[k])) }
            try expect(worst < 1e-3, "chunk \(chunk): max deviation \(worst)")
        }
    }

    suite.test("no duplicated audio: the output is the input signal at 16 kHz, in phase") {
        let frames = 48_000 * 2
        let input = sine(frames, rate: 48_000, frequency: 300, amplitude: 0.5)
        let out = try convertChunked(input, rate: 48_000, channels: 1, chunk: 480)
        let ideal = sine(out.count, rate: 16_000, frequency: 300, amplitude: 0.5)
        var err: Float = 0
        for k in 160..<(out.count - 160) { err = max(err, abs(out[k] - ideal[k])) }
        try expect(err < 0.01, "max error vs ideal \(err)")
        try expectEqual(out.count, 32_000)
    }

    suite.test("stereo is truly downmixed (average), not left-only") {
        let frames = 48_000
        let s = sine(frames, rate: 48_000, frequency: 500, amplitude: 0.6)
        let zeros = [Float](repeating: 0, count: frames)
        let mid = 2_000..<14_000
        let leftOnly = try convertChunked(interleave(s, zeros), rate: 48_000, channels: 2, chunk: 512)
        let rightOnly = try convertChunked(interleave(zeros, s), rate: 48_000, channels: 2, chunk: 512)
        let both = try convertChunked(interleave(s, s), rate: 48_000, channels: 2, chunk: 512)
        let opposite = try convertChunked(interleave(s, s.map { -$0 }), rate: 48_000, channels: 2, chunk: 512)
        try expectClose(Double(maxAbs(leftOnly[mid])), 0.3, tolerance: 0.01)
        try expectClose(Double(maxAbs(rightOnly[mid])), 0.3, tolerance: 0.01, "the right channel is not dropped")
        try expectClose(Double(maxAbs(both[mid])), 0.6, tolerance: 0.01)
        try expect(maxAbs(opposite[mid]) < 1e-4, "L = -R cancels: channels are averaged")
        let pairs: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        try expectEqual(pairs.withUnsafeBufferPointer { SampleRateConverter.downmix(interleaved: $0, channels: 2) }, [0.5, 0.5, 0])
    }

    suite.test("other rates (44.1, 24, 96, 8 kHz) and 16 kHz passthrough") {
        for rate in [44_100.0, 24_000, 96_000, 8_000] {
            let frames = Int(rate * 2) + 3
            let out = try convertChunked(sine(frames, rate: rate, frequency: 200), rate: rate, channels: 1, chunk: 441)
            let expected = Double(frames) * 16_000 / rate
            try expect(abs(Double(out.count) - expected) <= 1, "\(rate) Hz: \(out.count) vs \(expected)")
            try expectClose(Double(maxAbs(out[4_000..<12_000])), 0.5, tolerance: 0.02, "\(rate) Hz keeps the level")
        }
        let input = sine(1_000, rate: 16_000)
        let passthrough = try convertChunked(input, rate: 16_000, channels: 1, chunk: 77)
        try expectEqual(passthrough, input)
    }

    suite.test("flush ends the stream and resets the converter for reuse") {
        let c = try SampleRateConverter(inputRate: 48_000, inputChannels: 1)
        var first = c.convert(sine(48_000, rate: 48_000))
        first += c.flush()
        try expect(abs(first.count - 16_000) <= 1)
        try expectEqual(c.inputFrames, 0)
        var second = c.convert(sine(24_000, rate: 48_000))
        second += c.flush()
        try expect(abs(second.count - 8_000) <= 1, "\(second.count)")
        try expectThrows { _ = try SampleRateConverter(inputRate: 0, inputChannels: 1) }
    }

    return suite
}

func ringSuite() -> TestSuite {
    let suite = TestSuite("CaptureRing")

    suite.test("mono buffers come out in order with one anchor per buffer") {
        let ring = CaptureRing(sampleRate: 48_000, seconds: 1)
        let data = sine(1_440, rate: 48_000)
        for b in 0..<3 {
            data.withUnsafeBufferPointer { ring.write(mono: UnsafeBufferPointer(rebasing: $0[(b * 480)..<((b + 1) * 480)]), hostTime: UInt64(1_000 + b * 10)) }
        }
        let batch = ring.read()
        try expectEqual(batch.samples, data)
        try expectEqual(batch.firstFrame, 0)
        try expectEqual(batch.anchors, [.init(frame: 0, hostTime: 1_000), .init(frame: 480, hostTime: 1_010), .init(frame: 960, hostTime: 1_020)])
        try expectEqual(batch.firstHostTime, 1_000)
        try expect(ring.read().isEmpty)
        let stats = ring.stats
        try expectEqual(stats.callbacks, 3)
        try expectEqual(stats.lastCallbackHostTime, 1_020)
        try expectEqual(stats.framesWritten, 1_440)
    }

    suite.test("wraps around without losing samples; drops whole buffers when full") {
        let ring = CaptureRing(sampleRate: 8_000, seconds: 0.5)          // 4 000 frames
        try expectEqual(ring.capacityFrames, 4_000)
        let a = sine(3_000, rate: 8_000), b = sine(3_000, rate: 8_000, phase: 3_000)
        a.withUnsafeBufferPointer { ring.write(mono: $0, hostTime: 1) }
        try expectEqual(ring.read().samples, a)
        b.withUnsafeBufferPointer { ring.write(mono: $0, hostTime: 2) }
        let wrapped = ring.read()
        try expectEqual(wrapped.samples, b)
        try expectEqual(wrapped.firstFrame, 3_000)
        let chunk = [Float](repeating: 0.1, count: 1_500)
        for t in 0..<3 { chunk.withUnsafeBufferPointer { ring.write(mono: $0, hostTime: UInt64(10 + t)) } }
        try expectEqual(ring.stats.droppedBuffers, 1)
        let kept = ring.read()
        try expectEqual(kept.samples.count, 3_000)
        try expectEqual(kept.anchors.map(\.hostTime), [10, 11], "the dropped buffer has no anchor")
    }

    suite.test("interleaved stereo and non-interleaved buffers are mixed to mono") {
        let ring = CaptureRing(sampleRate: 48_000, seconds: 1)
        var interleaved: [Float] = [0.2, 0.4, -0.2, -0.6, 1, 0]
        interleaved.withUnsafeMutableBufferPointer { p in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress)))
            withUnsafePointer(to: &list) { ring.write($0, layout: InputLayout(), hostTime: 5) }
        }
        let mixed = ring.read().samples
        try expectEqual(mixed.count, 3)
        for (got, want) in zip(mixed, [Float(0.3), -0.4, 0.5]) { try expectClose(Double(got), Double(want), tolerance: 1e-6) }

        var left: [Float] = [1, 1, 1], right: [Float] = [0, 0.5, -1], third: [Float] = [9, 9, 9]
        let list = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(list.unsafeMutablePointer) }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                third.withUnsafeMutableBufferPointer { t in
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: UnsafeMutableRawPointer(l.baseAddress))
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: UnsafeMutableRawPointer(r.baseAddress))
                    list[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: UnsafeMutableRawPointer(t.baseAddress))
                    ring.write(list.unsafePointer, layout: InputLayout(firstBuffer: 0, bufferCount: 2), hostTime: 6)
                    ring.write(list.unsafePointer, layout: InputLayout(firstBuffer: 2, bufferCount: 1), hostTime: 7)
                }
            }
        }
        let planar = ring.read().samples
        try expectEqual(planar, [0.5, 0.75, 0, 9, 9, 9], "first stream averaged, then the third buffer alone")

        var format = AudioStreamBasicDescription()
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        format.mChannelsPerFrame = 2
        try expectEqual(InputLayout.forStream(format), InputLayout(firstBuffer: 0, bufferCount: 2))
        format.mFormatFlags = kAudioFormatFlagIsFloat
        try expectEqual(InputLayout.forStream(format), InputLayout(firstBuffer: 0, bufferCount: 1))
    }

    return suite
}

func timelineSuite() -> TestSuite {
    let suite = TestSuite("Timeline (gap filling & drift)")
    let start: UInt64 = 1_000_000_000
    func host(_ s: Double) -> UInt64 { HostClock.offset(start, by: s) }

    suite.test("audio within the tolerance is written as is; exact placement pads any gap") {
        var t = TrackTimeline(startHostTime: start)
        try expectEqual(t.toleranceFrames, 1_600)
        try expectEqual(t.place(count: 160, firstSampleHostTime: host(0.05)), .init(padFrames: 0, dropFrames: 0, frame: 0))
        var exact = TrackTimeline(startHostTime: start)
        try expectEqual(exact.place(count: 160, firstSampleHostTime: host(0.05), exact: true), .init(padFrames: 800, dropFrames: 0, frame: 800))
        try expectEqual(exact.framesWritten, 960)
        try expectEqual(t.expectedFrame(atHostTime: host(-0.5)), -8_000)
    }

    suite.test("gaps beyond the tolerance are filled with silence, leads are dropped") {
        var t = TrackTimeline(startHostTime: start)
        _ = t.place(count: 16_000, firstSampleHostTime: host(0))          // 0…1 s
        let gap = t.place(count: 1_600, firstSampleHostTime: host(1.25))   // 250 ms rebuild gap
        try expectEqual(gap, .init(padFrames: 4_000, dropFrames: 0, frame: 20_000))
        try expectEqual(t.framesWritten, 21_600)
        let lead = t.place(count: 3_200, firstSampleHostTime: host(1.2))  // overlapping timestamps
        try expectEqual(lead.dropFrames, 2_400)
        try expectEqual(lead.frame, 21_600)
        try expectEqual(t.framesWritten, 22_400)
        let swallowed = t.place(count: 100, firstSampleHostTime: host(1.0))
        try expectEqual(swallowed.dropFrames, 100, "entirely before the write position")
        try expectEqual(t.framesWritten, 22_400)
        try expectEqual(t.padTo(frame: 24_000), 1_600)
        try expectEqual(t.padTo(frame: 10), 0)
        t.truncate(to: 5_000)
        try expectEqual(t.framesWritten, 5_000)
    }

    suite.test("drift: a slow device clock is padded, a fast one dropped; error stays within 100 ms") {
        for (hostPerBuffer, expectPads) in [(0.010_05, true), (0.009_95, false)] {
            var t = TrackTimeline(startHostTime: start)
            var pads: Int64 = 0, drops = 0, worst: Int64 = 0
            for k in 0..<6_000 {                                           // 60 s of 10 ms buffers
                let h = host(Double(k) * hostPerBuffer)
                let p = t.place(count: 160, firstSampleHostTime: h)
                pads += p.padFrames
                drops += p.dropFrames
                let error = abs(t.expectedFrame(atHostTime: h) - (p.frame - Int64(p.dropFrames)))
                worst = max(worst, error)
            }
            try expect(worst <= t.toleranceFrames + 160, "worst misalignment \(worst) frames")
            if expectPads {
                try expect(pads >= 3_200 && drops == 0, "slow clock: pads \(pads), drops \(drops)")
            } else {
                try expect(drops >= 3_200 && pads == 0, "fast clock: pads \(pads), drops \(drops)")
            }
        }
    }

    suite.test("level meter, dBFS and rebuild limiter") {
        var meter = LevelMeter()
        meter.add(rms: 0.5, elapsed: 0.05)
        try expectEqual(meter.level, 0.5, "instant attack")
        meter.add(rms: 0, elapsed: 0.3)
        try expectClose(Double(meter.level), 0.5 * exp(-1), tolerance: 0.01, "300 ms release")
        meter.add(rms: .nan, elapsed: 10)
        try expect(meter.level < 0.001)
        try expectClose(Double(LevelMeter.amplitude(dBFS: -50)), 0.003_162, tolerance: 1e-5)
        try expectClose(Double(LevelMeter.rms(sine(16_000, rate: 16_000, amplitude: 1))), 1 / 2.0.squareRoot(), tolerance: 1e-3)
        var limiter = RebuildLimiter(maxEvents: 5, windowSeconds: 60)
        for i in 0..<5 { try expect(limiter.allow(at: Double(i))) }
        try expect(!limiter.allow(at: 10))
        try expect(limiter.allow(at: 60.5), "refilled")
        // A burst of five, then one every 12 s: a used-up budget says when to try again.
        var paced = RebuildLimiter(maxEvents: 5, windowSeconds: 60)
        try expectEqual(paced.delay(at: 100), 0)
        for _ in 0..<5 { try expect(paced.allow(at: 100)) }
        try expect(!paced.allow(at: 100))
        try expectClose(paced.delay(at: 100), 12, tolerance: 1e-9)
        try expectClose(paced.delay(at: 106), 6, tolerance: 1e-9)
        try expect(!paced.allow(at: 111.9))
        try expect(paced.allow(at: 112), "after the delay it said")
        try expect(!paced.allow(at: 112))
        var count = 0
        for t in stride(from: 112.5, through: 172.0, by: 0.5) where paced.allow(at: t) { count += 1 }
        try expectEqual(count, 5, "one every 12 s afterwards: five per minute in the long run")
        var refused = RebuildLimiter(maxEvents: 0, windowSeconds: 60)
        try expect(refused.allow(at: 0), "at least one event")
        try expect(refused.delay(at: 0) > 0 && refused.delay(at: 0).isFinite)
    }

    suite.test("anchors.json model round-trips") {
        let anchors = RecordingAnchors(sampleRate: 16_000, startedAt: Date(timeIntervalSince1970: 1_700_000_000.25), startHostTime: 42,
                                       me: .init(file: "me.wav", frames: 10, sources: [.init(name: "mic", sampleRate: 48_000, startFrame: 0)],
                                                 anchors: [.init(frame: 0, hostTime: 42, seconds: 0)],
                                                 edits: [.init(kind: .silence, frame: 0, frames: 5, reason: "start")]))
        let data = try JSONEncoder.kanPretty.encode(anchors)
        let back = try JSONDecoder.kan.decode(RecordingAnchors.self, from: data)
        try expectEqual(back.me, anchors.me)
        try expectEqual(back.startHostTime, 42)
        try expectClose(back.startedAt.timeIntervalSince1970, 1_700_000_000.25, tolerance: 0.001)
    }

    return suite
}

func deviceSuite() -> TestSuite {
    let suite = TestSuite("Devices, loudspeaker & mic choice")

    suite.test("loudspeaker classification") {
        func route(_ d: AudioDeviceInfo) -> OutputRoute { LoudspeakerClassifier.route(of: d) }
        try expectEqual(route(FakeDevices.builtInSpeakers), .builtInSpeakers)
        try expect(LoudspeakerClassifier.isLoudspeaker(FakeDevices.builtInSpeakers))
        let jack = AudioDeviceInfo(uid: "jack", name: "MacBook Pro Speakers", transport: .builtIn, outputChannels: 2, outputDataSource: "hdpn")
        try expectEqual(route(jack), .headphones, "data source wins over the name")
        let external = AudioDeviceInfo(uid: "ext", name: "External Headphones", transport: .builtIn, outputChannels: 2)
        try expectEqual(route(external), .headphones)
        let usbTerminal = AudioDeviceInfo(uid: "u", name: "USB Audio Device", transport: .usb, outputChannels: 2, outputTerminalTypes: ["770"])
        try expectEqual(route(usbTerminal), .usbHeadset, "USB-class terminal 0x302 = headphones")
        try expectEqual(route(FakeDevices.airPods), .bluetoothHeadphones)
        try expect(!LoudspeakerClassifier.isLoudspeaker(FakeDevices.airPods))
        let buds = AudioDeviceInfo(uid: "b", name: "Galaxy Buds2", transport: .bluetoothLE, outputChannels: 2)
        try expectEqual(route(buds), .bluetoothHeadphones)
        let bose = AudioDeviceInfo(uid: "q", name: "Bose QC45", transport: .bluetooth, outputChannels: 2)
        try expectEqual(route(bose), .bluetoothHeadphones, "unknown Bluetooth devices are assumed worn")
        let jbl = AudioDeviceInfo(uid: "j", name: "JBL Flip 6", transport: .bluetooth, outputChannels: 2)
        try expectEqual(route(jbl), .bluetoothSpeaker)
        for t in [AudioTransport.hdmi, .displayPort, .airPlay] {
            try expect(LoudspeakerClassifier.isLoudspeaker(AudioDeviceInfo(uid: "x", name: "LG Monitor", transport: t, outputChannels: 2)), "\(t)")
        }
        let headset = AudioDeviceInfo(uid: "h", name: "Jabra Evolve2 65", transport: .usb, inputChannels: 1, outputChannels: 2)
        try expectEqual(route(headset), .usbHeadset)
        let speakerphone = AudioDeviceInfo(uid: "s", name: "Jabra Speak 750", transport: .usb, inputChannels: 1, outputChannels: 2)
        try expectEqual(route(speakerphone), .usbSpeaker)
        let studio = AudioDeviceInfo(uid: "sd", name: "Studio Display Speakers", transport: .usb, outputChannels: 2)
        try expectEqual(route(studio), .usbSpeaker)
        try expectEqual(route(FakeDevices.zoomVirtual), .virtual)
    }

    suite.test("loudspeaker suspicion follows the call app's devices, else the default output") {
        let devices = [FakeDevices.builtInSpeakers, FakeDevices.airPods, FakeDevices.zoomVirtual]
        func suspected(_ uids: [String], _ fallback: String?) -> Bool {
            LoudspeakerClassifier.isLoudspeakerSuspected(outputUIDs: uids, devices: devices, defaultOutputUID: fallback)
        }
        try expect(suspected([FakeDevices.builtInSpeakers.uid], FakeDevices.airPods.uid))
        try expect(!suspected([FakeDevices.airPods.uid], FakeDevices.builtInSpeakers.uid))
        try expect(suspected([], FakeDevices.builtInSpeakers.uid), "no app devices: the default output")
        try expect(!suspected([], FakeDevices.airPods.uid))
        try expect(suspected([FakeDevices.zoomVirtual.uid], FakeDevices.builtInSpeakers.uid), "virtual devices are skipped")
        try expect(suspected([FakeDevices.airPods.uid, FakeDevices.builtInSpeakers.uid], nil), "any loud device")
        try expect(!suspected(["gone"], nil))
    }

    suite.test("microphone choice: the call app's physical input, else the default input") {
        let dead = AudioDeviceInfo(uid: "dead", name: "Old USB Mic", transport: .usb, inputChannels: 1, isAlive: false)
        let devices = [FakeDevices.builtInMic, FakeDevices.airPods, FakeDevices.zoomVirtual, dead]
        let def = FakeDevices.builtInMic.uid
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: [FakeDevices.airPods.uid], devices: devices, defaultInputUID: def),
                        .init(uid: FakeDevices.airPods.uid, followsDefault: false))
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: [FakeDevices.zoomVirtual.uid, FakeDevices.airPods.uid], devices: devices,
                                                  defaultInputUID: def)?.uid, FakeDevices.airPods.uid, "virtual devices are skipped")
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: ["dead", "missing"], devices: devices, defaultInputUID: def),
                        .init(uid: def, followsDefault: true))
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: [], devices: devices, defaultInputUID: FakeDevices.zoomVirtual.uid)?.uid,
                        FakeDevices.zoomVirtual.uid, "the user's chosen default is respected even if virtual")
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: [], devices: devices, defaultInputUID: nil),
                        .init(uid: def, followsDefault: true))
        try expect(MicrophoneSelector.choose(preferredUIDs: [], devices: [FakeDevices.builtInSpeakers], defaultInputUID: nil) == nil)
        // Voice-processing clients (corespeechd, WebRTC) list the speakers' echo-reference stream as an
        // input device: a device without input channels is never a microphone.
        try expectEqual(MicrophoneSelector.choose(preferredUIDs: [FakeDevices.builtInSpeakers.uid, FakeDevices.usbMic.uid],
                                                  devices: [FakeDevices.builtInSpeakers, FakeDevices.usbMic, FakeDevices.builtInMic],
                                                  defaultInputUID: def), .init(uid: FakeDevices.usbMic.uid, followsDefault: false))
        try expectEqual(MicrophoneSelector.firstPhysicalInput(among: [FakeDevices.zoomVirtual.uid, "dead", FakeDevices.airPods.uid],
                                                              devices: devices), FakeDevices.airPods.uid)
        try expect(MicrophoneSelector.firstPhysicalInput(among: [FakeDevices.zoomVirtual.uid, "missing"], devices: devices) == nil)
    }

    suite.test("tap targets: the app's own bundle ids, never shared WebKit ones; system audio excludes Kan") {
        let safari = AppActivity(app: AppIdentity(bundleID: "com.apple.Safari", name: "Safari", pid: 10), category: .browser,
                                 micActive: true, outputActive: true, processObjectIDs: [7, 3, 7],
                                 processBundleIDs: ["com.apple.WebKit.GPU", "com.apple.Safari", ""])
        let target = TapTarget.app(safari)
        try expectEqual(target.scope, .processes)
        try expectEqual(target.processObjectIDs, [3, 7])
        try expectEqual(target.bundleIDs, ["com.apple.Safari"])
        let all = TapTarget.systemAudio(excluding: 42)
        try expectEqual(all.scope, .systemAudio)
        try expectEqual(all.processObjectIDs, [42])
        try expectEqual(all.bundleIDs, [KanPaths.bundleIdentifier])
        try expectEqual(TapTarget.systemAudio(excluding: nil).processObjectIDs, [])
    }

    suite.test("System Audio Recording: a grant made after Kan saw a denial needs a relaunch") {
        try expectEqual(SystemAudioAccess(status: .granted, deniedSinceLaunch: false), .granted, "granted at launch or through Kan's prompt")
        try expectEqual(SystemAudioAccess(status: .granted, deniedSinceLaunch: true), .grantedPendingRelaunch,
                        "macOS never prompts again after a denial: this grant came from System Settings")
        for status in [PermissionStatus.denied, .notDetermined, .unknown] {
            for denied in [false, true] {
                try expectEqual(SystemAudioAccess(status: status, deniedSinceLaunch: denied), .notGranted, "\(status)")
            }
        }
    }

    suite.test("System Settings deep links") {
        try expectEqual(Permissions.settingsURL(for: .systemAudio, macOS26: true)?.absoluteString,
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        try expectEqual(Permissions.settingsURL(for: .systemAudio, macOS26: false)?.absoluteString,
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        try expectEqual(Permissions.settingsURL(for: .microphone)?.query, "Privacy_Microphone")
        try expectEqual(Permissions.settingsURL(for: .accessibility)?.query, "Privacy_Accessibility")
        try expectEqual(Permissions.settingsURL(for: .automation)?.query, "Privacy_Automation")
        try expectEqual(Permissions.settingsURL(for: .calendar)?.query, "Privacy_Calendars")
        try expectEqual(ScriptableBrowsers.family(bundleID: "com.brave.Browser"), .chromium)
        try expectEqual(ScriptableBrowsers.family(bundleID: "company.thebrowser.dia"), .chromium)
        try expectEqual(ScriptableBrowsers.family(bundleID: "com.apple.Safari"), .safari)
        try expect(ScriptableBrowsers.family(bundleID: "app.zen-browser.zen") == nil, "Zen has no tab scripting")
    }

    return suite
}
