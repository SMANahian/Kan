import AVFoundation
import Foundation
import KanCore

public enum AudioArchiverError: Error, CustomStringConvertible {
    case noAudio(URL)
    case encodingFailed(String, String)
    case verificationFailed(String, String)

    public var description: String {
        switch self {
        case .noAudio(let dir): return "no me.wav / them.wav in \(dir.path)"
        case .encodingFailed(let file, let why): return "encoding \(file) failed: \(why)"
        case .verificationFailed(let file, let why): return "\(file) failed verification: \(why)"
        }
    }
}

/// Compresses kept call audio: me.wav / them.wav → AAC-LC me.m4a / them.m4a (mono, 16 kHz,
/// ~32 kbps ≈ 14 MB per hour per track). Each m4a is written under a temporary name, re-opened and
/// its duration compared with the WAV before the WAV is deleted, so a failure never loses audio.
/// Implements `AudioArchiving`.
///
/// Thread-safe (stateless); encoding runs on a background queue.
public final class AudioArchiver: AudioArchiving, @unchecked Sendable {
    public let bitRate: Int
    public let sampleRate: Double
    /// Allowed difference between WAV and m4a duration.
    public let durationTolerance: TimeInterval

    public init(bitRate: Int = 32_000, sampleRate: Double = 16_000, durationTolerance: TimeInterval = 0.1) {
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.durationTolerance = durationTolerance
    }

    public func archive(directory: URL) async throws -> AudioAssets {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.archiveNow(directory: directory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAudio(in directory: URL) throws {
        let fm = FileManager.default
        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A,
                     AudioArchiver.partialName(KanPaths.CallFile.meM4A), AudioArchiver.partialName(KanPaths.CallFile.themM4A)] {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
        }
        KanLog.info("deleted audio in \(directory.lastPathComponent)", category: "archive")
    }

    /// Synchronous archive (the async API runs this on a background queue).
    public func archiveNow(directory: URL) throws -> AudioAssets {
        let fm = FileManager.default
        var names: [AudioChannel: String] = [:]
        var bytes: Int64 = 0
        for (channel, wav, m4a) in [(AudioChannel.me, KanPaths.CallFile.meWAV, KanPaths.CallFile.meM4A),
                                    (AudioChannel.them, KanPaths.CallFile.themWAV, KanPaths.CallFile.themM4A)] {
            let wavURL = directory.appendingPathComponent(wav)
            let m4aURL = directory.appendingPathComponent(m4a)
            if fm.fileExists(atPath: wavURL.path) {
                let reader = try WAVReader(url: wavURL)
                if reader.frameCount == 0 {
                    // Nothing to keep (e.g. trimmed to zero): drop the empty track.
                    try fm.removeItem(at: wavURL)
                    continue
                }
                try encode(reader, to: m4aURL)
                try fm.removeItem(at: wavURL)
                names[channel] = m4a
            } else if fm.fileExists(atPath: m4aURL.path) {
                names[channel] = m4a                                    // archived earlier
            } else {
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: m4aURL.path))?[.size] as? NSNumber
            bytes += size?.int64Value ?? 0
        }
        guard !names.isEmpty else { throw AudioArchiverError.noAudio(directory) }
        KanLog.info("archived \(directory.lastPathComponent): \(names.values.sorted()) (\(bytes / 1024) KB)", category: "archive")
        return AudioAssets(meFile: names[.me], themFile: names[.them], format: "m4a", sizeBytes: bytes)
    }

    private func encode(_ reader: WAVReader, to destination: URL) throws {
        let fm = FileManager.default
        let name = destination.lastPathComponent
        let partial = destination.deletingLastPathComponent().appendingPathComponent(AudioArchiver.partialName(name))
        try? fm.removeItem(at: partial)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let converter = reader.format.sampleRate == sampleRate ? nil
            : try SampleRateConverter(inputRate: reader.format.sampleRate, inputChannels: 1, outputRate: sampleRate)
        var written: Int64 = 0
        do {
            let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            func append(_ samples: [Float]) throws {
                guard !samples.isEmpty else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw AudioArchiverError.encodingFailed(name, "cannot allocate a buffer")
                }
                samples.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try file.write(from: buffer)
                written += Int64(samples.count)
            }
            while true {
                let chunk = try reader.readMono(maxFrames: 32_768)
                if chunk.isEmpty { break }
                try append(converter?.convert(chunk) ?? chunk)
            }
            if let converter { try append(converter.flush()) }
            file.close()
        } catch let error as AudioArchiverError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw AudioArchiverError.encodingFailed(name, "\(error)")
        }

        // Verify by reading the result back.
        let expected = Double(written) / sampleRate
        do {
            let check = try AVAudioFile(forReading: partial)
            let duration = Double(check.length) / check.fileFormat.sampleRate
            guard abs(duration - expected) <= durationTolerance else {
                throw AudioArchiverError.verificationFailed(name, String(format: "duration %.3f s, expected %.3f s", duration, expected))
            }
        } catch let error as AudioArchiverError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw AudioArchiverError.verificationFailed(name, "\(error)")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
    }

    /// "me.m4a" → "me.partial.m4a" (AVAudioFile infers the container from the extension).
    static func partialName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base).partial.\((name as NSString).pathExtension)"
    }
}
