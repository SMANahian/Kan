import Foundation

/// Minimal RIFF/WAVE support for 16 kHz mono PCM16 files: header parsing (any chunk layout),
/// sample reading, streamed writing and header repair. Stateless and thread-safe.
enum WAV {
    static let sampleRate = 16_000
    static let bytesPerSample = 2

    struct Info: Equatable {
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var formatTag: Int
        /// Offset of the first sample byte.
        var dataOffset: Int
        /// Data size as the header states it.
        var dataSize: Int
        /// Offset of the 4-byte size field of the "data" chunk.
        var dataSizeFieldOffset: Int

        var bytesPerFrame: Int { max(1, channels * bitsPerSample / 8) }
        var duration: Double { sampleRate > 0 ? Double(dataSize / bytesPerFrame) / Double(sampleRate) : 0 }
        var isKanFormat: Bool { formatTag == 1 && channels == 1 && bitsPerSample == 16 && sampleRate == WAV.sampleRate }
    }

    /// Parses the header (reads at most the first 64 KB).
    static func info(of url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536) else { return nil }
        return info(header: head)
    }

    static func info(header data: Data) -> Info? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var offset = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (u16(body), u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data", let format {
                return Info(sampleRate: format.rate, channels: format.channels, bitsPerSample: format.bits,
                            formatTag: format.tag, dataOffset: body, dataSize: size, dataSizeFieldOffset: offset + 4)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    /// Duration in seconds (from the header).
    static func duration(of url: URL) -> Double? {
        info(of: url)?.duration
    }

    /// All samples of a 16 kHz mono PCM16 file, or nil for other formats.
    static func readSamples(_ url: URL) -> [Int16]? {
        guard let info = info(of: url), info.isKanFormat, let data = try? Data(contentsOf: url) else { return nil }
        let end = min(data.count, info.dataOffset + info.dataSize)
        guard end > info.dataOffset else { return [] }
        let count = (end - info.dataOffset) / bytesPerSample
        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { target in
            _ = data.copyBytes(to: target, from: info.dataOffset..<(info.dataOffset + count * bytesPerSample))
        }
        return samples.map { Int16(littleEndian: $0) }
    }

    /// The canonical 44-byte header for `dataBytes` of 16 kHz mono PCM16.
    static func header(dataBytes: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * bytesPerSample); append16(bytesPerSample); append16(16)
        append("data"); append32(dataBytes)
        return data
    }

    /// Streams 16 kHz mono PCM16 to a file; `finish()` writes the final sizes. Not thread-safe.
    final class Writer {
        private let handle: FileHandle
        private(set) var frames = 0

        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: WAV.header(dataBytes: 0))
        }

        func write(_ samples: [Int16]) throws {
            guard !samples.isEmpty else { return }
            let data = samples.withUnsafeBufferPointer { buffer in
                Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
            }
            try handle.write(contentsOf: data)
            frames += samples.count
        }

        func finish() throws {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAV.header(dataBytes: frames * WAV.bytesPerSample))
            try handle.close()
        }
    }

    /// After a crash the header can lag the file by the last few seconds of audio: extend the data
    /// size to cover every complete frame actually written (only when "data" is the last chunk).
    /// Returns true when the header was changed.
    @discardableResult
    static func repairHeader(_ url: URL) -> Bool {
        guard let info = info(of: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        else { return false }
        let available = (size - info.dataOffset) / info.bytesPerFrame * info.bytesPerFrame
        guard available > info.dataSize, available <= Int(UInt32.max) - 64 else { return false }
        if followedByChunk(url, at: info.dataOffset + info.dataSize) { return false }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(info.dataOffset - 8 + available).littleEndian) { Data($0) })
            try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(available).littleEndian) { Data($0) })
            return true
        } catch {
            return false
        }
    }

    /// True when another RIFF chunk ("LIST", "id3 "…) starts at `offset` rather than more samples.
    private static func followedByChunk(_ url: URL, at offset: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        return bytes.allSatisfy { (0x20...0x7E).contains($0) }
    }
}
