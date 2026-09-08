import Foundation
import AVFAudio

actor MeetingAudioChunker: MeetingAudioChunking {
    private let chunkDuration: TimeInterval
    private let outputSampleRate: Double
    private let readFrameCapacity: AVAudioFrameCount

    init(
        chunkDuration: TimeInterval = 120,
        outputSampleRate: Double = 16_000,
        readFrameCapacity: AVAudioFrameCount = 65_536
    ) {
        self.chunkDuration = chunkDuration
        self.outputSampleRate = outputSampleRate
        self.readFrameCapacity = readFrameCapacity
    }

    func chunkCount(for url: URL) async throws -> Int {
        try Task.checkCancellation()
        let file = try openAudioFile(url)
        let duration = try duration(for: file)
        return Int(ceil(duration / chunkDuration))
    }

    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        try Task.checkCancellation()
        guard index >= 0 else {
            throw AIError(message: "오디오 청크 번호가 올바르지 않습니다.")
        }

        let file = try openAudioFile(url)
        let sourceDuration = try duration(for: file)
        let totalChunks = Int(ceil(sourceDuration / chunkDuration))
        guard index < totalChunks else {
            throw AIError(message: "요청한 오디오 구간이 녹음 길이를 벗어났습니다.")
        }

        let startTime = TimeInterval(index) * chunkDuration
        let duration = min(chunkDuration, sourceDuration - startTime)
        let sourceSampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((startTime * sourceSampleRate).rounded())
        let endFrame = min(file.length, AVAudioFramePosition(((startTime + duration) * sourceSampleRate).rounded()))
        let framesToRead = max(0, endFrame - startFrame)
        guard framesToRead > 0 else {
            throw AIError(message: "요청한 오디오 구간에 변환할 샘플이 없습니다.")
        }

        let data = try convertToWAVData(file: file, startFrame: startFrame, frameCount: framesToRead)
        return AudioChunk(data: data, format: "wav", startTime: startTime, duration: duration)
    }

    private func openAudioFile(_ url: URL) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AIError(message: "오디오 파일을 찾을 수 없습니다.")
        }

        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AIError(message: "오디오 파일을 읽을 수 없습니다. 파일이 손상되었거나 지원하지 않는 형식입니다.")
        }
    }

    private func duration(for file: AVAudioFile) throws -> TimeInterval {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AIError(message: "오디오 파일의 샘플레이트가 올바르지 않습니다.")
        }
        guard file.length > 0 else {
            throw AIError(message: "오디오 파일에 변환할 오디오가 없습니다.")
        }
        return Double(file.length) / sampleRate
    }

    private func convertToWAVData(
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition
    ) throws -> Data {
        try Task.checkCancellation()

        let sourceFormat = file.processingFormat
        guard let converterInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: converterInputFormat, to: outputFormat) else {
            throw AIError(message: "오디오 변환기를 준비하지 못했습니다.")
        }

        var outputSamples = Data()
        let readFrameCapacity = readFrameCapacity
        let outputFrameCapacity = AVAudioFrameCount(
            max(4_096, ceil(Double(readFrameCapacity) * outputSampleRate / sourceFormat.sampleRate) + 1_024)
        )
        let inputProvider = AudioConverterInputProvider(
            file: file,
            sourceFormat: sourceFormat,
            converterInputFormat: converterInputFormat,
            startFrame: startFrame,
            frameCount: frameCount,
            readFrameCapacity: readFrameCapacity
        )

        while true {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                throw AIError(message: "오디오 변환 버퍼를 준비하지 못했습니다.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                inputProvider.nextInput(outStatus: outStatus)
            }

            if let inputError = inputProvider.takeError() {
                if inputError is CancellationError {
                    throw inputError
                }
                throw AIError(message: "오디오 파일을 변환하는 중 읽기 오류가 발생했습니다.")
            }

            if let conversionError {
                throw AIError(message: "오디오를 WAV 형식으로 변환하지 못했습니다: \(conversionError.localizedDescription)")
            }

            if outputBuffer.frameLength > 0 {
                appendInt16PCM(from: outputBuffer, to: &outputSamples)
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return RIFFWAVData(pcmData: outputSamples, sampleRate: UInt32(outputSampleRate), channelCount: 1)
            case .error:
                throw AIError(message: "오디오를 WAV 형식으로 변환하지 못했습니다.")
            @unknown default:
                throw AIError(message: "알 수 없는 오디오 변환 상태가 발생했습니다.")
            }
        }
    }
}

// AVAudioConverter's input block is @Sendable; this locked owner serializes mutable file/read state.
nonisolated private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let sourceFormat: AVAudioFormat
    private let converterInputFormat: AVAudioFormat
    private let readFrameCapacity: AVAudioFrameCount
    private var remainingSourceFrames: AVAudioFramePosition
    private var reachedEndOfInput = false
    private var inputError: Error?

    init(
        file: AVAudioFile,
        sourceFormat: AVAudioFormat,
        converterInputFormat: AVAudioFormat,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        readFrameCapacity: AVAudioFrameCount
    ) {
        self.file = file
        self.sourceFormat = sourceFormat
        self.converterInputFormat = converterInputFormat
        self.remainingSourceFrames = frameCount
        self.readFrameCapacity = readFrameCapacity
        self.file.framePosition = startFrame
    }

    nonisolated func nextInput(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if reachedEndOfInput || remainingSourceFrames <= 0 {
            outStatus.pointee = .endOfStream
            return nil
        }

        do {
            try Task.checkCancellation()
            let framesThisRead = min(AVAudioFrameCount(remainingSourceFrames), readFrameCapacity)
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesThisRead),
                  let convertedInput = AVAudioPCMBuffer(pcmFormat: converterInputFormat, frameCapacity: framesThisRead)
            else {
                outStatus.pointee = .noDataNow
                return nil
            }
            try file.read(into: sourceBuffer, frameCount: framesThisRead)
            guard sourceBuffer.frameLength > 0 else {
                reachedEndOfInput = true
                outStatus.pointee = .endOfStream
                return nil
            }
            remainingSourceFrames -= AVAudioFramePosition(sourceBuffer.frameLength)
            try downmixToMonoFloat(source: sourceBuffer, destination: convertedInput)
            outStatus.pointee = .haveData
            return convertedInput
        } catch {
            inputError = error
            reachedEndOfInput = true
            outStatus.pointee = .endOfStream
            return nil
        }
    }

    nonisolated func takeError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let error = inputError
        inputError = nil
        return error
    }
}

nonisolated private func downmixToMonoFloat(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) throws {
    destination.frameLength = source.frameLength
    guard source.frameLength > 0 else { return }

    switch source.format.commonFormat {
    case .pcmFormatFloat32:
        downmixFloat32(source: source, destination: destination)
    case .pcmFormatInt16:
        downmixInt16(source: source, destination: destination)
    case .pcmFormatInt32:
        downmixInt32(source: source, destination: destination)
    default:
        throw AIError(message: "지원하지 않는 오디오 채널 형식입니다.")
    }
}

nonisolated private func downmixFloat32(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) {
    guard let destinationChannel = destination.floatChannelData?[0] else { return }
    let frameCount = Int(source.frameLength)
    let channelCount = Int(source.format.channelCount)
    if source.format.isInterleaved, let sourceData = source.floatChannelData?[0] {
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += sourceData[frameIndex * channelCount + channelIndex]
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    } else if let sourceChannels = source.floatChannelData {
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += sourceChannels[channelIndex][frameIndex]
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    }
}

nonisolated private func downmixInt16(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) {
    guard let sourceChannels = source.int16ChannelData,
          let destinationChannel = destination.floatChannelData?[0]
    else { return }
    let frameCount = Int(source.frameLength)
    let channelCount = Int(source.format.channelCount)
    if source.format.isInterleaved {
        let sourceData = sourceChannels[0]
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(sourceData[frameIndex * channelCount + channelIndex]) / Float(Int16.max)
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    } else {
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(sourceChannels[channelIndex][frameIndex]) / Float(Int16.max)
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    }
}

nonisolated private func downmixInt32(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) {
    guard let sourceChannels = source.int32ChannelData,
          let destinationChannel = destination.floatChannelData?[0]
    else { return }
    let frameCount = Int(source.frameLength)
    let channelCount = Int(source.format.channelCount)
    if source.format.isInterleaved {
        let sourceData = sourceChannels[0]
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(sourceData[frameIndex * channelCount + channelIndex]) / Float(Int32.max)
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    } else {
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(sourceChannels[channelIndex][frameIndex]) / Float(Int32.max)
            }
            destinationChannel[frameIndex] = sum / Float(channelCount)
        }
    }
}

nonisolated private func appendInt16PCM(from buffer: AVAudioPCMBuffer, to data: inout Data) {
    guard let channel = buffer.floatChannelData?[0] else { return }
    for frameIndex in 0..<Int(buffer.frameLength) {
        let clipped = min(1, max(-1, channel[frameIndex]))
        let scaled = clipped < 0 ? clipped * Float(Int(Int16.max) + 1) : clipped * Float(Int16.max)
        var sample = Int16(scaled.rounded()).littleEndian
        Swift.withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
}

nonisolated private func RIFFWAVData(pcmData: Data, sampleRate: UInt32, channelCount: UInt16) -> Data {
    let bitsPerSample: UInt16 = 16
    let blockAlign = channelCount * bitsPerSample / 8
    let byteRate = sampleRate * UInt32(blockAlign)
    let dataSize = UInt32(pcmData.count)
    let riffSize = 36 + dataSize

    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(riffSize)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channelCount)
    data.appendLittleEndian(sampleRate)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(dataSize)
    data.append(pcmData)
    return data
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
