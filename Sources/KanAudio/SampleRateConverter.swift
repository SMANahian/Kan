import AVFoundation
import Accelerate
import Foundation
import KanCore

public enum SampleRateConverterError: Error, CustomStringConvertible {
    case unsupportedFormat(rate: Double, channels: Int)

    public var description: String {
        switch self {
        case .unsupportedFormat(let rate, let channels): return "cannot convert \(channels) ch at \(rate) Hz to 16 kHz mono"
        }
    }
}

/// Streaming conversion of interleaved Float32 audio at any rate and channel count to mono at
/// `outputRate` (16 kHz by default) — one instance per continuous stream.
///
/// * Channels are averaged ("true" downmix). `AVAudioConverter` keeps only the left channel unless
///   told otherwise, so the downmix is done here, before resampling.
/// * Each input chunk is handed to `AVAudioConverter` exactly once and the input block then answers
///   `.noDataNow`. The common snippet that keeps answering `.haveData` with the same buffer
///   duplicates audio (1.4× the expected output, measured).
/// * The default prime method gives zero leading latency; `flush()` drains the filter tail, so the
///   total output is `inputFrames × outputRate / inputRate` within one sample, for any chunking.
///
/// Not thread-safe: use from one queue.
public final class SampleRateConverter {
    public let inputRate: Double
    public let inputChannels: Int
    public let outputRate: Double
    public private(set) var inputFrames: Int64 = 0
    public private(set) var outputFrames: Int64 = 0

    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let chunkFrames: Int = 8_192

    public init(inputRate: Double, inputChannels: Int = 1, outputRate: Double = 16_000) throws {
        guard inputRate >= 1_000, inputRate <= 768_000, outputRate >= 1_000, inputChannels >= 1,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunkFrames)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity:
                AVAudioFrameCount((Double(chunkFrames) * outputRate / inputRate).rounded(.up)) + 1_024)
        else { throw SampleRateConverterError.unsupportedFormat(rate: inputRate, channels: inputChannels) }
        self.inputRate = inputRate
        self.inputChannels = inputChannels
        self.outputRate = outputRate
        self.inputBuffer = inBuffer
        self.outputBuffer = outBuffer
        if inputRate == outputRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw SampleRateConverterError.unsupportedFormat(rate: inputRate, channels: inputChannels)
            }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = c
        }
    }

    public var ratio: Double { outputRate / inputRate }

    /// Converts interleaved samples (`count` must be a multiple of `inputChannels`).
    public func convert(_ interleaved: [Float]) -> [Float] {
        interleaved.withUnsafeBufferPointer { convert(interleaved: $0) }
    }

    public func convert(interleaved: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = interleaved.count / inputChannels
        guard frames > 0, let base = interleaved.baseAddress else { return [] }
        if inputChannels == 1 { return convertMono(UnsafeBufferPointer(start: base, count: frames)) }
        let mono = SampleRateConverter.downmix(interleaved: UnsafeBufferPointer(start: base, count: frames * inputChannels),
                                               channels: inputChannels)
        return mono.withUnsafeBufferPointer { convertMono($0) }
    }

    /// Ends the stream: returns the filter's remaining output and resets for reuse.
    public func flush() -> [Float] {
        var result: [Float] = []
        if let converter {
            var status: AVAudioConverterOutputStatus
            repeat {
                outputBuffer.frameLength = 0
                var error: NSError?
                status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if status == .error {
                    KanLog.warning("sample-rate converter flush failed: \(error.map { "\($0)" } ?? "?")", category: "audio")
                    break
                }
                appendOutput(to: &result)
            } while status == .haveData
            converter.reset()
        }
        // Guarantee the documented length even if the converter rounds differently.
        // (`outputFrames` already includes what the flush produced.)
        let expected = Int64((Double(inputFrames) * ratio).rounded())
        let produced = outputFrames
        if produced < expected - 1 {
            result.append(contentsOf: repeatElement(0, count: Int(expected - produced)))
        } else if produced > expected + 1 {
            result.removeLast(min(result.count, Int(produced - expected)))
        }
        inputFrames = 0
        outputFrames = 0
        return result
    }

    /// Averages interleaved channels.
    public static func downmix(interleaved: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 1 else { return Array(interleaved) }
        let frames = interleaved.count / channels
        guard frames > 0, let base = interleaved.baseAddress else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { out in
            guard let dst = out.baseAddress else { return }
            for c in 0..<channels {
                // dst += src[c], src[c + channels], …
                vDSP_vadd(base + c, vDSP_Stride(channels), dst, 1, dst, 1, vDSP_Length(frames))
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
        }
        return mono
    }

    private func convertMono(_ mono: UnsafeBufferPointer<Float>) -> [Float] {
        guard let base = mono.baseAddress, !mono.isEmpty else { return [] }
        inputFrames += Int64(mono.count)
        guard let converter, let inData = inputBuffer.floatChannelData?[0] else {
            outputFrames += Int64(mono.count)
            return Array(mono)
        }
        var result: [Float] = []
        result.reserveCapacity(Int((Double(mono.count) * ratio).rounded(.up)) + 16)
        var offset = 0
        while offset < mono.count {
            let n = min(chunkFrames, mono.count - offset)
            inData.update(from: base + offset, count: n)
            inputBuffer.frameLength = AVAudioFrameCount(n)
            offset += n
            var supplied = false
            let input = inputBuffer
            var status: AVAudioConverterOutputStatus
            repeat {
                outputBuffer.frameLength = 0
                var error: NSError?
                status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow     // NOT .endOfStream: that would end the stream
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if status == .error {
                    KanLog.warning("sample-rate conversion failed: \(error.map { "\($0)" } ?? "?")", category: "audio")
                    break
                }
                appendOutput(to: &result)
            } while status == .haveData
        }
        return result
    }

    private func appendOutput(to result: inout [Float]) {
        let produced = Int(outputBuffer.frameLength)
        guard produced > 0, let data = outputBuffer.floatChannelData?[0] else { return }
        result.append(contentsOf: UnsafeBufferPointer(start: data, count: produced))
        outputFrames += Int64(produced)
    }
}
