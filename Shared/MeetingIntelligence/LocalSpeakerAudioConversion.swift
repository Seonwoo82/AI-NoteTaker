import Foundation
#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

nonisolated struct LocalSpeakerPCMWindow: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Double
    let startTime: Double

    var duration: Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0
            && startTime.isFinite && startTime >= 0
            && samples.allSatisfy(\.isFinite)
    }
}

nonisolated struct LocalSpeakerPCMWindowBuilder: Sendable {
    private let windowDuration: Double
    private let maximumBufferedDuration: Double
    private var sampleRate: Double?
    private var bufferedStartTime: Double?
    private var expectedNextInputTime: Double?
    private var samples: [Float] = []

    init(windowDuration: Double = 10, maximumBufferedDuration: Double = 12) {
        let validWindowDuration = windowDuration.isFinite && windowDuration > 0 ? windowDuration : 10
        let validMaximumDuration = maximumBufferedDuration.isFinite && maximumBufferedDuration > 0 ? maximumBufferedDuration : 12
        self.windowDuration = min(max(validWindowDuration, 0.1), 30)
        self.maximumBufferedDuration = min(max(self.windowDuration, validMaximumDuration), 60)
    }

    mutating func append(samples newSamples: [Float], sampleRate newSampleRate: Double, startTime: Double) -> [LocalSpeakerPCMWindow] {
        guard newSampleRate.isFinite, newSampleRate > 0,
              startTime.isFinite, startTime >= 0,
              !newSamples.isEmpty,
              newSamples.allSatisfy(\.isFinite) else {
            return []
        }

        if let sampleRate, let expectedNextInputTime {
            let toleratedFrameDuration = 1 / sampleRate
            if sampleRate != newSampleRate || abs(startTime - expectedNextInputTime) > toleratedFrameDuration {
                reset()
            }
        }

        if sampleRate == nil {
            sampleRate = newSampleRate
            bufferedStartTime = startTime
        }
        expectedNextInputTime = startTime + Double(newSamples.count) / newSampleRate
        samples.append(contentsOf: newSamples)

        guard let sampleRate, var nextWindowStart = bufferedStartTime else { return [] }
        let framesPerWindow = max(1, Int((sampleRate * windowDuration).rounded()))
        var emitted: [LocalSpeakerPCMWindow] = []
        while samples.count >= framesPerWindow {
            let windowSamples = Array(samples.prefix(framesPerWindow))
            let window = LocalSpeakerPCMWindow(samples: windowSamples, sampleRate: sampleRate, startTime: nextWindowStart)
            if window.isValid { emitted.append(window) }
            samples.removeFirst(framesPerWindow)
            nextWindowStart += Double(framesPerWindow) / sampleRate
        }
        bufferedStartTime = nextWindowStart
        trimOverflow()
        return emitted
    }

    mutating func finish() -> LocalSpeakerPCMWindow? {
        guard let sampleRate, let bufferedStartTime, !samples.isEmpty else { return nil }
        let window = LocalSpeakerPCMWindow(samples: samples, sampleRate: sampleRate, startTime: bufferedStartTime)
        reset()
        return window.isValid ? window : nil
    }

    mutating func reset() {
        sampleRate = nil
        bufferedStartTime = nil
        expectedNextInputTime = nil
        samples.removeAll(keepingCapacity: true)
    }

    private mutating func trimOverflow() {
        guard let sampleRate else { return }
        let maximumFrames = max(1, Int((sampleRate * maximumBufferedDuration).rounded()))
        if samples.count > maximumFrames {
            let dropped = samples.count - maximumFrames
            samples.removeFirst(dropped)
            if let bufferedStartTime {
                self.bufferedStartTime = bufferedStartTime + Double(dropped) / sampleRate
            }
        }
    }
}

#if canImport(AVFAudio)
nonisolated enum LocalSpeakerAudioConverter {
    static func convertMonoSamplesTo16k(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return [] }
        guard sampleRate != 16_000 else { return samples }

        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AIError(message: String(localized: "화자 분석용 오디오 변환기를 준비하지 못했습니다."))
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            inputBuffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }

        let outputCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(samples.count) * 16_000 / sampleRate)) + 1_024))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AIError(message: String(localized: "화자 분석용 오디오 버퍼를 준비하지 못했습니다."))
        }

        let inputProvider = LocalSpeakerSingleBufferInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextInput(outStatus: outStatus)
        }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw AIError(message: String(localized: "화자 분석용 오디오를 변환하지 못했습니다."))
        }
        return copyMonoSamples(from: outputBuffer)
    }

    static func copyMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: frameCount))
    }
}

nonisolated final class LocalSpeakerSingleBufferInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var hasProvidedInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextInput(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if hasProvidedInput {
            outStatus.pointee = .endOfStream
            return nil
        }
        hasProvidedInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}

nonisolated enum LocalSpeakerAudioFileWindows {
    static func readMonoWindows(
        from url: URL,
        targetSampleRate: Double,
        readFrameCapacity: AVAudioFrameCount = 65_536,
        process: (LocalSpeakerPCMWindow) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AIError(message: String(localized: "화자 분석할 오디오 파일을 찾을 수 없습니다."))
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AIError(message: String(localized: "화자 분석할 오디오 파일을 읽을 수 없습니다."))
        }

        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0, file.length > 0 else {
            throw AIError(message: String(localized: "화자 분석할 오디오 파일의 길이 또는 샘플레이트가 올바르지 않습니다."))
        }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate, channels: sourceFormat.channelCount, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AIError(message: String(localized: "화자 분석용 오디오 변환기를 준비하지 못했습니다."))
        }

        let inputProvider = LocalSpeakerAudioFileInputProvider(
            file: file,
            sourceFormat: sourceFormat,
            converterInputFormat: inputFormat,
            readFrameCapacity: readFrameCapacity
        )
        let outputFrameCapacity = AVAudioFrameCount(max(4_096, ceil(Double(readFrameCapacity) * targetSampleRate / sourceFormat.sampleRate) + 1_024))
        var builder = LocalSpeakerPCMWindowBuilder(windowDuration: 10, maximumBufferedDuration: 12)
        var nextTargetStartTime = 0.0

        while true {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                throw AIError(message: String(localized: "화자 분석용 오디오 버퍼를 준비하지 못했습니다."))
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, outStatus in
                inputProvider.nextInput(packetCount: packetCount, outStatus: outStatus)
            }
            if let inputError = inputProvider.takeError() { throw inputError }
            if let conversionError { throw conversionError }

            let samples = LocalSpeakerAudioConverter.copyMonoSamples(from: outputBuffer)
            if !samples.isEmpty {
                let windows = builder.append(samples: samples, sampleRate: targetSampleRate, startTime: nextTargetStartTime)
                nextTargetStartTime += Double(samples.count) / targetSampleRate
                for window in windows {
                    try Task.checkCancellation()
                    try process(window)
                }
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                if let tail = builder.finish(), !tail.samples.isEmpty { try process(tail) }
                return
            case .error:
                throw AIError(message: String(localized: "화자 분석용 오디오를 변환하지 못했습니다."))
            @unknown default:
                throw AIError(message: String(localized: "알 수 없는 화자 분석 오디오 변환 상태가 발생했습니다."))
            }
        }
    }
}

nonisolated final class LocalSpeakerAudioFileInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let sourceFormat: AVAudioFormat
    private let converterInputFormat: AVAudioFormat
    private let readFrameCapacity: AVAudioFrameCount
    private var reachedEnd = false
    private var inputError: Error?

    init(file: AVAudioFile, sourceFormat: AVAudioFormat, converterInputFormat: AVAudioFormat, readFrameCapacity: AVAudioFrameCount) {
        self.file = file
        self.sourceFormat = sourceFormat
        self.converterInputFormat = converterInputFormat
        self.readFrameCapacity = readFrameCapacity
    }

    func nextInput(packetCount: AVAudioPacketCount, outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !reachedEnd else {
            outStatus.pointee = .endOfStream
            return nil
        }
        do {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            guard remaining > 0 else {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            let frames = min(readFrameCapacity, AVAudioFrameCount(remaining), AVAudioFrameCount(packetCount))
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converterInputFormat, frameCapacity: frames) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            try file.read(into: sourceBuffer, frameCount: frames)
            guard sourceBuffer.frameLength > 0 else {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            try downmixIfNeeded(source: sourceBuffer, destination: convertedBuffer)
            outStatus.pointee = .haveData
            return convertedBuffer
        } catch {
            inputError = error
            reachedEnd = true
            outStatus.pointee = .endOfStream
            return nil
        }
    }

    func takeError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let error = inputError
        inputError = nil
        return error
    }

    private func downmixIfNeeded(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) throws {
        destination.frameLength = source.frameLength
        guard source.format.commonFormat == .pcmFormatFloat32,
              let sourceChannels = source.floatChannelData,
              let destinationChannel = destination.floatChannelData?[0] else {
            throw AIError(message: String(localized: "지원하지 않는 화자 분석 오디오 형식입니다."))
        }
        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }
        if channelCount == 1 {
            destinationChannel.update(from: sourceChannels[0], count: frameCount)
            return
        }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sourceChannels[channel][frame]
            }
            destinationChannel[frame] = sum / Float(channelCount)
        }
    }
}
#else
nonisolated enum LocalSpeakerAudioConverter {
    static func convertMonoSamplesTo16k(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate == 16_000 else {
            throw AIError(message: String(localized: "이 플랫폼에서는 화자 분석용 오디오 변환을 지원하지 않습니다."))
        }
        return samples
    }
}

nonisolated enum LocalSpeakerAudioFileWindows {
    static func readMonoWindows(
        from url: URL,
        targetSampleRate: Double,
        readFrameCapacity: Int = 65_536,
        process: (LocalSpeakerPCMWindow) throws -> Void
    ) throws {
        throw AIError(message: String(localized: "이 플랫폼에서는 화자 분석용 오디오 파일 읽기를 지원하지 않습니다."))
    }
}
#endif
