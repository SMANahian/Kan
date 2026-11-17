import Accelerate
import Darwin
import Foundation

public enum WAVError: Error, CustomStringConvertible, Sendable {
    case io(operation: String, errno: Int32)
    case diskFull(operation: String)
    case invalidFile(String)
    case unsupportedFormat(String)
    case closed

    public var description: String {
        switch self {
        case .io(let op, let code): return "\(op): \(String(cString: strerror(code)))"
        case .diskFull(let op): return "\(op): the disk is full"
        case .invalidFile(let why): return "not a WAV file: \(why)"
        case .unsupportedFormat(let why): return "unsupported WAV format: \(why)"
        case .closed: return "the WAV file is closed"
        }
    }

    public var isDiskFull: Bool {
        if case .diskFull = self { return true }
        return false
    }

    static func fromErrno(_ operation: String, _ code: Int32 = errno) -> WAVError {
        code == ENOSPC || code == EDQUOT ? .diskFull(operation: operation) : .io(operation: operation, errno: code)
    }
}

/// Writes 16-bit PCM WAV files incrementally.
///
/// Crash safety: the RIFF and data sizes in the header are rewritten (and the file fsync'ed) at
/// most every `headerUpdateInterval` seconds while writing, so after a crash at most that much audio
/// is missing from the header's point of view — and `WAVReader` / `WAVReader.repairHeader(at:)`
/// recover even that from the file length.
///
/// Not thread-safe: use from one queue.
public final class WAVWriter {
    public static let headerSize: Int64 = 44

    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public private(set) var frameCount: Int64 = 0
    public var headerUpdateInterval: TimeInterval
    public var syncOnHeaderUpdate: Bool

    private var fd: Int32
    private var lastHeaderUpdate = HostClock.now()
    private var scratch: [Int16] = []
    private var floatScratch: [Float] = []
    private static let zeros = [UInt8](repeating: 0, count: 32_768)

    public var blockAlign: Int { channels * 2 }
    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
    public var isClosed: Bool { fd < 0 }

    /// Creates (or truncates) the file and writes a header for an empty data chunk.
    public init(url: URL, sampleRate: Int = 16_000, channels: Int = 1, headerUpdateInterval: TimeInterval = 2,
                syncOnHeaderUpdate: Bool = true) throws {
        guard sampleRate > 0, channels > 0 else { throw WAVError.unsupportedFormat("\(channels) ch at \(sampleRate) Hz") }
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.headerUpdateInterval = headerUpdateInterval
        self.syncOnHeaderUpdate = syncOnHeaderUpdate
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WAVError.fromErrno("create \(url.lastPathComponent)") }
        do {
            try writeAll(WAVWriter.header(sampleRate: sampleRate, channels: channels, dataBytes: 0), "write WAV header")
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit {
        if fd >= 0 { try? close() }
    }

    /// Appends interleaved samples in -1…1 (values outside are clipped).
    public func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try write($0) }
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard fd >= 0 else { throw WAVError.closed }
        let count = (samples.count / channels) * channels
        guard count > 0, let base = samples.baseAddress else { return }
        if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
        if floatScratch.count < count { floatScratch = [Float](repeating: 0, count: count) }
        floatScratch.withUnsafeMutableBufferPointer { tmp in
            guard let t = tmp.baseAddress else { return }
            var low: Float = -1, high: Float = 1, scale: Float = 32_767
            vDSP_vclip(base, 1, &low, &high, t, 1, vDSP_Length(count))
            vDSP_vsmul(t, 1, &scale, t, 1, vDSP_Length(count))
            scratch.withUnsafeMutableBufferPointer { out in
                if let o = out.baseAddress { vDSP_vfixr16(t, 1, o, 1, vDSP_Length(count)) }
            }
        }
        try scratch.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            try appendBytes(p, count * 2, frames: Int64(count / channels), "write audio")
        }
    }

    /// Appends digital silence.
    public func writeSilence(frames: Int64) throws {
        guard fd >= 0 else { throw WAVError.closed }
        var remaining = max(0, frames) * Int64(blockAlign)
        while remaining > 0 {
            let n = Int(min(remaining, Int64(WAVWriter.zeros.count)))
            let chunkFrames = Int64(n / blockAlign)
            try WAVWriter.zeros.withUnsafeBytes { raw in
                guard let p = raw.baseAddress else { return }
                try appendBytes(p, n, frames: chunkFrames, "write silence")
            }
            remaining -= Int64(n)
        }
    }

    /// Drops everything after `frames` (no-op when the file is already that short).
    public func truncate(toFrames frames: Int64) throws {
        guard fd >= 0 else { throw WAVError.closed }
        let target = max(0, frames)
        guard target < frameCount else { return }
        guard ftruncate(fd, off_t(WAVWriter.headerSize + target * Int64(blockAlign))) == 0 else {
            throw WAVError.fromErrno("truncate \(url.lastPathComponent)")
        }
        guard lseek(fd, 0, SEEK_END) >= 0 else { throw WAVError.fromErrno("seek \(url.lastPathComponent)") }
        frameCount = target
        try updateHeader()
    }

    /// Rewrites the RIFF and data sizes for the frames written so far.
    public func updateHeader() throws {
        guard fd >= 0 else { throw WAVError.closed }
        let dataBytes = UInt32(clamping: frameCount * Int64(blockAlign))
        try pwriteUInt32(dataBytes &+ 36, at: 4)
        try pwriteUInt32(dataBytes, at: 40)
        if syncOnHeaderUpdate { _ = fsync(fd) }
        lastHeaderUpdate = HostClock.now()
    }

    /// Final header update, fsync and close. Idempotent.
    public func close() throws {
        guard fd >= 0 else { return }
        defer {
            Darwin.close(fd)
            fd = -1
        }
        let saved = syncOnHeaderUpdate
        syncOnHeaderUpdate = true
        try updateHeader()
        syncOnHeaderUpdate = saved
    }

    // MARK: Header layout

    public static func header(sampleRate: Int, channels: Int, dataBytes: UInt32) -> [UInt8] {
        var h: [UInt8] = []
        h.reserveCapacity(44)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(dataBytes &+ 36)
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                                      // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2))                      // byte rate
        u16(UInt16(channels * 2))                                   // block align
        u16(16)                                                     // bits per sample
        h.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return h
    }

    // MARK: I/O

    private func appendBytes(_ p: UnsafeRawPointer, _ count: Int, frames: Int64, _ op: String) throws {
        do {
            try writeAll(p, count, op)
        } catch {
            // Keep the file on a frame boundary that matches `frameCount`.
            _ = ftruncate(fd, off_t(WAVWriter.headerSize + frameCount * Int64(blockAlign)))
            _ = lseek(fd, 0, SEEK_END)
            throw error
        }
        frameCount += frames
        if HostClock.seconds(HostClock.now() &- lastHeaderUpdate) >= headerUpdateInterval {
            try updateHeader()
        }
    }

    private func writeAll(_ bytes: [UInt8], _ op: String) throws {
        try bytes.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            try writeAll(p, raw.count, op)
        }
    }

    private func writeAll(_ p: UnsafeRawPointer, _ count: Int, _ op: String) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, p + offset, count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw WAVError.fromErrno("\(op) \(url.lastPathComponent)")
            }
            offset += n
        }
    }

    private func pwriteUInt32(_ value: UInt32, at offset: off_t) throws {
        var le = value.littleEndian
        let n = withUnsafeBytes(of: &le) { pwrite(fd, $0.baseAddress, 4, offset) }
        guard n == 4 else { throw WAVError.fromErrno("update header of \(url.lastPathComponent)") }
    }
}

/// Reads PCM WAV files (8/16/24/32-bit integer or 32-bit float, any channel count).
///
/// Lenient about crashed recordings: when the header's data size is zero, larger than the file, or
/// smaller than the file with no further chunk after it, the size is taken from the file length.
///
/// Not thread-safe: use from one queue.
public final class WAVReader {
    public struct Format: Sendable, Equatable {
        public var sampleRate: Double
        public var channels: Int
        public var bitsPerSample: Int
        public var isFloat: Bool
        public var blockAlign: Int

        public init(sampleRate: Double, channels: Int, bitsPerSample: Int, isFloat: Bool, blockAlign: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitsPerSample = bitsPerSample
            self.isFloat = isFloat
            self.blockAlign = blockAlign
        }
    }

    public let url: URL
    public let format: Format
    /// Byte offset of the first sample.
    public let dataOffset: Int64
    /// Frames actually present (see the type comment).
    public let frameCount: Int64
    /// Frames according to the header's data chunk size.
    public let headerFrameCount: Int64
    public private(set) var position: Int64 = 0

    private let handle: FileHandle

    public var duration: TimeInterval { Double(frameCount) / format.sampleRate }
    public var headerIsStale: Bool { headerFrameCount != frameCount }

    public init(url: URL) throws {
        self.url = url
        let layout = try WAVReader.parse(url: url)
        format = layout.format
        dataOffset = layout.dataOffset
        frameCount = layout.effectiveDataBytes / Int64(layout.format.blockAlign)
        headerFrameCount = Int64(layout.declaredDataBytes) / Int64(layout.format.blockAlign)
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(dataOffset))
        } catch {
            throw WAVError.io(operation: "open \(url.lastPathComponent)", errno: Int32((error as NSError).code))
        }
    }

    deinit { try? handle.close() }

    public func seek(toFrame frame: Int64) throws {
        let f = min(max(0, frame), frameCount)
        try handle.seek(toOffset: UInt64(dataOffset + f * Int64(format.blockAlign)))
        position = f
    }

    /// Reads up to `maxFrames` interleaved frames as Float (-1…1). Empty at the end.
    public func read(maxFrames: Int) throws -> [Float] {
        let frames = Int(min(Int64(max(0, maxFrames)), frameCount - position))
        guard frames > 0 else { return [] }
        let bytes = frames * format.blockAlign
        guard let data = try handle.read(upToCount: bytes), !data.isEmpty else { return [] }
        let gotFrames = data.count / format.blockAlign
        position += Int64(gotFrames)
        return WAVReader.decode(data, frames: gotFrames, format: format)
    }

    /// Reads up to `maxFrames` frames mixed down to mono.
    public func readMono(maxFrames: Int) throws -> [Float] {
        let interleaved = try read(maxFrames: maxFrames)
        guard format.channels > 1 else { return interleaved }
        return interleaved.withUnsafeBufferPointer { SampleRateConverter.downmix(interleaved: $0, channels: format.channels) }
    }

    /// The whole file (from the current position) as mono samples.
    public func readAllMono() throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(Int(frameCount - position))
        while true {
            let chunk = try readMono(maxFrames: 65_536)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Rewrites the RIFF/data sizes of a WAV whose header is stale (e.g. after a crash while
    /// recording) and drops a trailing partial frame. Returns true if the file was changed.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Bool {
        let layout = try parse(url: url)
        let blockAlign = Int64(layout.format.blockAlign)
        let wholeBytes = (layout.effectiveDataBytes / blockAlign) * blockAlign
        let expectedRIFF = UInt32(clamping: layout.dataOffset - 8 + wholeBytes)
        guard layout.dataIsLastChunk,
              Int64(layout.declaredDataBytes) != wholeBytes || layout.declaredRIFFBytes != expectedRIFF
                || layout.fileSize != layout.dataOffset + wholeBytes else { return false }
        let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw WAVError.fromErrno("open \(url.lastPathComponent)") }
        defer { Darwin.close(fd) }
        if layout.fileSize != layout.dataOffset + wholeBytes {
            guard ftruncate(fd, off_t(layout.dataOffset + wholeBytes)) == 0 else {
                throw WAVError.fromErrno("truncate \(url.lastPathComponent)")
            }
        }
        func put(_ value: UInt32, at offset: Int64) throws {
            var le = value.littleEndian
            let n = withUnsafeBytes(of: &le) { pwrite(fd, $0.baseAddress, 4, off_t(offset)) }
            guard n == 4 else { throw WAVError.fromErrno("repair \(url.lastPathComponent)") }
        }
        try put(expectedRIFF, at: 4)
        try put(UInt32(clamping: wholeBytes), at: layout.dataOffset - 4)
        _ = fsync(fd)
        return true
    }

    // MARK: Parsing

    struct Layout {
        var format: Format
        var dataOffset: Int64
        var declaredDataBytes: UInt32
        var declaredRIFFBytes: UInt32
        var effectiveDataBytes: Int64
        var dataIsLastChunk: Bool
        var fileSize: Int64
    }

    static func parse(url: URL) throws -> Layout {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw WAVError.io(operation: "open \(url.lastPathComponent)", errno: Int32((error as NSError).code))
        }
        defer { try? handle.close() }
        let fileSize = Int64((try? handle.seekToEnd()) ?? 0)
        func bytes(at offset: Int64, _ count: Int) -> Data? {
            guard offset >= 0, offset + Int64(count) <= fileSize else { return nil }
            try? handle.seek(toOffset: UInt64(offset))
            guard let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        guard let riff = bytes(at: 0, 12),
              String(decoding: riff.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: riff.suffix(4), as: UTF8.self) == "WAVE" else {
            throw WAVError.invalidFile("\(url.lastPathComponent) has no RIFF/WAVE header")
        }
        let riffBytes = riff.u32(at: 4)
        var format: Format?
        var offset: Int64 = 12
        while offset + 8 <= fileSize, let chunk = bytes(at: offset, 8) {
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = chunk.u32(at: 4)
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, let fmt = bytes(at: body, Int(min(size, 64))) else {
                    throw WAVError.invalidFile("short fmt chunk")
                }
                var tag = fmt.u16(at: 0)
                if tag == 0xFFFE, fmt.count >= 26 { tag = fmt.u16(at: 24) }   // WAVE_FORMAT_EXTENSIBLE sub-format
                let channels = Int(fmt.u16(at: 2))
                let rate = Double(fmt.u32(at: 4))
                let blockAlign = Int(fmt.u16(at: 12))
                let bits = Int(fmt.u16(at: 14))
                let isFloat = tag == 3
                guard tag == 1 || isFloat else { throw WAVError.unsupportedFormat("format tag \(tag)") }
                guard channels > 0, rate > 0, blockAlign == channels * ((bits + 7) / 8),
                      (isFloat && bits == 32) || (!isFloat && [8, 16, 24, 32].contains(bits)) else {
                    throw WAVError.unsupportedFormat("\(channels) ch, \(bits) bit, block \(blockAlign)")
                }
                format = Format(sampleRate: rate, channels: channels, bitsPerSample: bits, isFloat: isFloat, blockAlign: blockAlign)
            } else if id == "data" {
                guard let format else { throw WAVError.invalidFile("data chunk before fmt chunk") }
                let available = fileSize - body
                var effective = Int64(size)
                var isLast = true
                if size == 0 || size == UInt32.max || Int64(size) > available {
                    effective = available                                  // header never (fully) updated
                } else if Int64(size) < available {
                    // Either another chunk follows, or audio was written after the last header update.
                    let next = body + Int64(size) + Int64(size & 1)
                    if let following = bytes(at: next, 8),
                       following.prefix(4).allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
                       next + 8 + Int64(following.u32(at: 4)) <= fileSize {
                        isLast = false
                    } else {
                        effective = available
                    }
                }
                return Layout(format: format, dataOffset: body, declaredDataBytes: size, declaredRIFFBytes: riffBytes,
                              effectiveDataBytes: max(0, effective), dataIsLastChunk: isLast, fileSize: fileSize)
            }
            offset = body + Int64(size) + Int64(size & 1)
        }
        throw WAVError.invalidFile("\(url.lastPathComponent) has no data chunk")
    }

    static func decode(_ data: Data, frames: Int, format: Format) -> [Float] {
        let count = frames * format.channels
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress, let src = raw.baseAddress else { return }
                switch (format.bitsPerSample, format.isFloat) {
                case (16, false):
                    let s = src.assumingMemoryBound(to: Int16.self)
                    vDSP_vflt16(s, 1, d, 1, vDSP_Length(count))
                    var scale: Float = 1 / 32_768
                    vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(count))
                case (32, true):
                    d.update(from: src.assumingMemoryBound(to: Float.self), count: count)
                case (32, false):
                    let s = src.assumingMemoryBound(to: Int32.self)
                    for i in 0..<count { d[i] = Float(Int32(littleEndian: s[i])) / 2_147_483_648 }
                case (24, false):
                    let b = src.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<count {
                        let v = Int32(b[3 * i]) | (Int32(b[3 * i + 1]) << 8) | (Int32(Int8(bitPattern: b[3 * i + 2])) << 16)
                        d[i] = Float(v) / 8_388_608
                    }
                default: // 8-bit unsigned
                    let b = src.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<count { d[i] = (Float(b[i]) - 128) / 128 }
                }
            }
        }
        return out
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
}
