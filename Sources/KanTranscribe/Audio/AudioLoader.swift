import Accelerate
import AVFoundation
import Foundation
import KanCore

/// Reads any file `AVAudioFile` understands (WAV, CAF, AIFF, m4a/AAC, MP3, …) as 16 kHz mono Float32.
///
/// Multi-channel audio is averaged (a true downmix: AVAudioConverter alone would keep only the
/// first channel). Resampling streams the file through one AVAudioConverter in pull mode: every
/// input callback reads the *next* block from the file, and end of file is reported as
/// `.endOfStream` so the converter flushes its tail. (Answering `.haveData` with the same buffer
/// again duplicates audio.) Stateless and thread-safe.
public enum AudioLoader {
    public static let sampleRate = 16_000.0

    /// Frames read from the file per block.
    static let blockFrames: AVAudioFrameCount = 1 << 16

    public static func load(_ url: URL) throws -> [Float] {
        let file = try open(url)
        let source = file.processingFormat
        guard source.channelCount > 0, source.sampleRate > 0 else {
            throw TranscriptionError.audioUnreadable("\(url.lastPathComponent): unsupported audio format")
        }
        guard file.length > 0 else { return [] }

        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: blockFrames),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                             channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: blockFrames)
        else {
            throw TranscriptionError.audioUnreadable("\(url.lastPathComponent): could not allocate audio buffers")
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate) + 4096)

        /// Reads and downmixes the next block into `monoBuffer`; false at end of file.
        func readBlock() throws -> Bool {
            guard file.framePosition < file.length else { return false }
            try file.read(into: readBuffer, frameCount: blockFrames)
            guard readBuffer.frameLength > 0 else { return false }
            downmix(readBuffer, into: monoBuffer)
            return true
        }

        do {
            if abs(source.sampleRate - sampleRate) < 0.5 {
                while try readBlock() { append(monoBuffer, to: &output) }
                return output
            }
            try resample(from: monoFormat, readBlock: readBlock, monoBuffer: monoBuffer, into: &output,
                         name: url.lastPathComponent)
            return output
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.audioUnreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Duration in seconds, read from the header (no decoding).
    public static func duration(of url: URL) throws -> Double {
        let file = try open(url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.audioUnreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func resample(from monoFormat: AVAudioFormat, readBlock: @escaping () throws -> Bool,
                                 monoBuffer: AVAudioPCMBuffer, into output: inout [Float], name: String) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: target)
        else {
            throw TranscriptionError.audioUnreadable("\(name): no converter from \(monoFormat.sampleRate) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let capacity = AVAudioFrameCount(Double(blockFrames) * sampleRate / monoFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw TranscriptionError.audioUnreadable("\(name): could not allocate the conversion buffer")
        }

        var reachedEnd = false
        var readError: Error?
        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if !reachedEnd {
                    do {
                        if try readBlock() {
                            inputStatus.pointee = .haveData
                            return monoBuffer
                        }
                    } catch {
                        readError = error
                    }
                    reachedEnd = true
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let readError { throw readError }
            append(outBuffer, to: &output)
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                // Only reachable after end of stream; anything else would loop forever.
                if reachedEnd { return }
            case .endOfStream:
                return
            case .error:
                throw TranscriptionError.audioUnreadable(
                    "\(name): conversion failed (\(conversionError?.localizedDescription ?? "unknown error"))")
            @unknown default:
                throw TranscriptionError.audioUnreadable("\(name): unexpected converter status")
            }
        }
    }

    /// Averages all channels of `input` into the mono `output` buffer.
    static func downmix(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames > 0, let source = input.floatChannelData, let destination = output.floatChannelData?[0] else {
            output.frameLength = 0
            return
        }
        if input.format.isInterleaved {
            // One buffer with channels interleaved: average with a stride.
            let data = source[0]
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                destination[frame] = sum / Float(channels)
            }
        } else {
            destination.update(from: source[0], count: frames)
            if channels > 1 {
                for channel in 1..<channels {
                    vDSP_vadd(destination, 1, source[channel], 1, destination, 1, vDSP_Length(frames))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frames))
            }
        }
        output.frameLength = AVAudioFrameCount(frames)
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return }
        output.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

extension AudioLoader {
    /// Root-mean-square level of `samples` in dBFS (−120 for digital silence).
    public static func rmsDecibels<C: Collection>(_ samples: C) -> Double where C.Element == Float {
        guard !samples.isEmpty else { return -120 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }

    /// True when every sample is exactly zero (what a process tap delivers without permission).
    public static func isDigitalSilence(_ samples: [Float]) -> Bool {
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buffer.count))
        }
        return peak == 0
    }
}
