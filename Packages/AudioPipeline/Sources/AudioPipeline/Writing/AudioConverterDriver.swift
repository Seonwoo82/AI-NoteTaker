@preconcurrency import AVFAudio
import Foundation

internal enum PCMBufferError: Error, Equatable, Sendable {
    case invalidFormat
    case missingInterleavedStorage
    case insufficientBufferCapacity
    case converterCreationFailed
    case converterFailed(String)
}

internal protocol ConverterStatusObserving: Sendable {
    func recordConverterStatus(_ status: AVAudioConverterOutputStatus)
}

internal final class ConverterInputState: @unchecked Sendable {
    private var suppliedBuffer: AVAudioPCMBuffer?
    private var didSupplyCurrentBuffer = true
    private var finalDrainRequested = false

    internal func supply(_ buffer: AVAudioPCMBuffer) {
        suppliedBuffer = buffer
        didSupplyCurrentBuffer = false
        finalDrainRequested = false
    }

    internal func beginFinalDrain() {
        suppliedBuffer = nil
        didSupplyCurrentBuffer = true
        finalDrainRequested = true
    }

    internal func nextBuffer(
        packetCount: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        _ = packetCount
        if let suppliedBuffer, !didSupplyCurrentBuffer {
            didSupplyCurrentBuffer = true
            status.pointee = .haveData
            return suppliedBuffer
        }
        status.pointee = finalDrainRequested ? .endOfStream : .noDataNow
        return nil
    }
}

internal final class AudioConverterDriver: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let state = ConverterInputState()
    private let observer: (any ConverterStatusObserving)?

    internal init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        observer: (any ConverterStatusObserving)? = nil
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PCMBufferError.converterCreationFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        self.converter = converter
        self.observer = observer
    }

    internal func convertLive(
        inputBuffer: AVAudioPCMBuffer,
        outputBuffer: AVAudioPCMBuffer,
        handleOutput: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        state.supply(inputBuffer)
        while true {
            outputBuffer.frameLength = 0
            let status = try convertOnce(outputBuffer: outputBuffer)
            if outputBuffer.frameLength > 0 {
                try handleOutput(outputBuffer)
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw PCMBufferError.converterFailed("AVAudioConverter returned error status")
            @unknown default:
                throw PCMBufferError.converterFailed("AVAudioConverter returned unknown status")
            }
        }
    }

    internal func drainFinal(
        outputBuffer: AVAudioPCMBuffer,
        handleOutput: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        state.beginFinalDrain()
        var dryWithoutOutputCount = 0
        while true {
            outputBuffer.frameLength = 0
            let status = try convertOnce(outputBuffer: outputBuffer)
            if outputBuffer.frameLength > 0 {
                dryWithoutOutputCount = 0
                try handleOutput(outputBuffer)
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                dryWithoutOutputCount += 1
                if dryWithoutOutputCount > 8 {
                    throw PCMBufferError.converterFailed("AVAudioConverter did not reach end of stream")
                }
                continue
            case .endOfStream:
                return
            case .error:
                throw PCMBufferError.converterFailed("AVAudioConverter returned error status")
            @unknown default:
                throw PCMBufferError.converterFailed("AVAudioConverter returned unknown status")
            }
        }
    }

    private func convertOnce(outputBuffer: AVAudioPCMBuffer) throws -> AVAudioConverterOutputStatus {
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { [state] packetCount, outStatus in
            state.nextBuffer(packetCount: packetCount, status: outStatus)
        }
        observer?.recordConverterStatus(status)
        if let conversionError {
            throw PCMBufferError.converterFailed(conversionError.localizedDescription)
        }
        return status
    }

    internal static func makeInterleavedFloat32Format(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw PCMBufferError.invalidFormat
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            throw PCMBufferError.invalidFormat
        }
        return format
    }

    internal static func makeBuffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw PCMBufferError.invalidFormat
        }
        return buffer
    }

    internal static func outputCapacity(inputFrames: Int, inputSampleRate: Double) -> AVAudioFrameCount {
        let ratio = RecordingFileSettings.outputSampleRate / inputSampleRate
        let converted = (Double(inputFrames) * ratio).rounded(.up)
        return AVAudioFrameCount(max(1_024, Int(converted) + 1_024))
    }

    internal static func copyInterleavedSamples(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int,
        into buffer: AVAudioPCMBuffer
    ) throws {
        guard frameCount >= 0, channelCount > 0 else {
            throw PCMBufferError.invalidFormat
        }
        let sampleCount = frameCount * channelCount
        guard samples.count >= sampleCount else {
            throw PCMBufferError.insufficientBufferCapacity
        }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard audioBuffers.count == 1,
              let data = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            throw PCMBufferError.missingInterleavedStorage
        }
        let capacitySamples = Int(buffer.frameCapacity) * Int(buffer.format.channelCount)
        guard capacitySamples >= sampleCount else {
            throw PCMBufferError.insufficientBufferCapacity
        }
        if sampleCount > 0 {
            guard let source = samples.baseAddress else {
                throw PCMBufferError.insufficientBufferCapacity
            }
            data.update(from: source, count: sampleCount)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
    }
}
