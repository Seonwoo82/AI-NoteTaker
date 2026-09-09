import AVFoundation
import Foundation

nonisolated enum ObservedVoiceRecordingError: Error, Equatable, LocalizedError, Sendable {
    case invalidInputFormat
    case workerQueueOverflow

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return String(localized: "The microphone input format changed before recording could finish.")
        case .workerQueueOverflow:
            return String(localized: "The recording could not process microphone audio quickly enough.")
        }
    }
}

@MainActor
final class ObservedVoiceRecordingSession: NSObject, VoiceRecordingSession {
    let canPause = true

    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private let outputURL: URL
    private let startedAt: Date
    private let sampleRate: Double
    private let audioWorker: ObservedVoiceAudioWorker
    private let notificationObservers: [NSObjectProtocol]
    private var interruptionHandler: (@MainActor @Sendable () async -> Void)?
    private var writtenFrames: AVAudioFramePosition = 0
    private var isFinished = false

    private init(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        outputURL: URL,
        startedAt: Date,
        sampleRate: Double,
        audioWorker: ObservedVoiceAudioWorker,
        notificationObservers: [NSObjectProtocol],
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.engine = engine
        self.inputNode = inputNode
        self.outputURL = outputURL
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.audioWorker = audioWorker
        self.notificationObservers = notificationObservers
        self.interruptionHandler = interruptionHandler
    }

    static func start(
        outputURL: URL,
        liveAudioHandler: @escaping LiveAudioSampleHandler,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> ObservedVoiceRecordingSession {
        try await prepareAudioSession()
        var observers: [NSObjectProtocol] = []
        var shouldDeactivateSession = true
        defer {
            if shouldDeactivateSession { cleanupFailedStart(observers: observers) }
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began
            else { return }

            Task { @MainActor in
                await interruptionHandler()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            Task { @MainActor in
                await interruptionHandler()
            }
        })
        #endif

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        try validateInputFormat(inputFormat)
        let sampleRate = inputFormat.sampleRate
        let channelCount = Int(inputFormat.channelCount)
        let file = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        let worker = ObservedVoiceAudioWorker(
            audioFile: file,
            sampleRate: sampleRate,
            liveAudioHandler: liveAudioHandler,
            failureHandler: {
                Task { @MainActor in
                    await interruptionHandler()
                }
            }
        )
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await interruptionHandler()
            }
        })

        let session = ObservedVoiceRecordingSession(
            engine: engine,
            inputNode: inputNode,
            outputURL: outputURL,
            startedAt: Date(),
            sampleRate: sampleRate,
            audioWorker: worker,
            notificationObservers: observers,
            interruptionHandler: interruptionHandler
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat,
            block: Self.makeTapHandler(worker: worker)
        )

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            _ = try? worker.finish()
            throw error
        }
        shouldDeactivateSession = false
        return session
    }

    // The worker is thread-safe; the callback itself must also be created
    // outside MainActor because AVFAudio invokes it on its audio queue.
    nonisolated static func makeTapHandler(worker: ObservedVoiceAudioWorker) -> AVAudioNodeTapBlock {
        { buffer, _ in worker.consume(buffer) }
    }

    func pause() {
        engine.pause()
    }

    func resume() throws {
        guard !isFinished else {
            throw VoiceRecorderError.encoderFailed
        }
        try engine.start()
    }

    func finish() async throws -> VoiceRecordingResult {
        guard !isFinished else {
            throw VoiceRecorderError.encoderFailed
        }
        isFinished = true
        engine.stop()
        inputNode.removeTap(onBus: 0)
        writtenFrames = try audioWorker.finish()
        cleanup()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VoiceRecorderError.fileMissingAfterFinish
        }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let fallbackDuration = writtenFrames > 0
            ? Double(writtenFrames) / sampleRate
            : Date().timeIntervalSince(startedAt)
        return VoiceRecordingResult(
            duration: duration.isFinite && duration > 0 ? duration : fallbackDuration,
            warnings: []
        )
    }

    func cancel() async {
        interruptionHandler = nil
        isFinished = true
        engine.stop()
        inputNode.removeTap(onBus: 0)
        _ = try? audioWorker.finish()
        cleanup()
        try? FileManager.default.removeItem(at: outputURL)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func cleanup() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionHandler = nil
    }

    nonisolated static func validateInputFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved
        else {
            throw ObservedVoiceRecordingError.invalidInputFormat
        }
    }

    nonisolated fileprivate static func targetFrames(sampleRate: Double) -> Int {
        max(1, Int(sampleRate * 0.5))
    }

    private static func prepareAudioSession() async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw VoiceRecorderError.microphonePermissionDenied
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #else
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw VoiceRecorderError.microphonePermissionDenied
        }
        #endif
    }

    private static func cleanupFailedStart(observers: [NSObjectProtocol]) {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

nonisolated final class ObservedVoiceAudioWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.seonwoo.notetaker.observed-voice-audio")
    private let sampleRate: Double
    private let liveAudioHandler: LiveAudioSampleHandler
    private let failureHandler: @Sendable () -> Void
    private let maxPendingBuffers: Int
    private let processingGate: DispatchSemaphore?
    private let targetFrames: Int
    private var audioFile: AVAudioFile?
    private var writtenFrames: AVAudioFramePosition = 0
    private var emittedFrames = 0
    private var pendingSamples: [Float] = []
    private var pendingBuffers = 0
    private var isAcceptingBuffers = true
    private var terminalError: Error?

    init(
        audioFile: AVAudioFile,
        sampleRate: Double,
        liveAudioHandler: @escaping LiveAudioSampleHandler,
        failureHandler: @escaping @Sendable () -> Void,
        maxPendingBuffers: Int = 8,
        processingGate: DispatchSemaphore? = nil
    ) {
        self.audioFile = audioFile
        self.sampleRate = sampleRate
        self.liveAudioHandler = liveAudioHandler
        self.failureHandler = failureHandler
        self.maxPendingBuffers = max(1, maxPendingBuffers)
        self.processingGate = processingGate
        self.targetFrames = ObservedVoiceRecordingSession.targetFrames(sampleRate: sampleRate)
        self.pendingSamples.reserveCapacity(targetFrames)
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let copiedBuffer: AVAudioPCMBuffer
        lock.lock()
        guard isAcceptingBuffers, terminalError == nil else {
            lock.unlock()
            return
        }
        guard pendingBuffers < maxPendingBuffers else {
            lock.unlock()
            fail(ObservedVoiceRecordingError.workerQueueOverflow)
            return
        }
        do {
            copiedBuffer = try Self.copy(buffer)
        } catch {
            lock.unlock()
            fail(error)
            return
        }
        pendingBuffers += 1
        lock.unlock()

        let owned = OwnedRecordingPCMBuffer(value: copiedBuffer)
        queue.async { [weak self] in
            self?.process(owned.value)
        }
    }

    func finish() throws -> AVAudioFramePosition {
        lock.lock()
        isAcceptingBuffers = false
        lock.unlock()

        queue.sync {}

        lock.lock()
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        let startTime = Double(emittedFrames) / sampleRate
        emittedFrames += samples.count
        audioFile = nil
        let frames = writtenFrames
        let error = terminalError
        lock.unlock()

        if !samples.isEmpty {
            liveAudioHandler(LiveAudioSamples(
                samples: samples,
                sampleRate: sampleRate,
                startTime: startTime
            ))
        }
        if let error {
            throw error
        }
        return frames
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        processingGate?.wait()
        defer {
            lock.lock()
            pendingBuffers -= 1
            lock.unlock()
        }

        lock.lock()
        guard let audioFile else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try audioFile.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            let chunks = liveAudioChunks(from: buffer)
            for chunk in chunks {
                liveAudioHandler(chunk)
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        var shouldNotify = false
        lock.lock()
        if terminalError == nil {
            terminalError = error
            isAcceptingBuffers = false
            shouldNotify = true
        }
        lock.unlock()
        if shouldNotify {
            failureHandler()
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try ObservedVoiceRecordingSession.validateInputFormat(buffer.format)
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw ObservedVoiceRecordingError.invalidInputFormat
        }
        copiedBuffer.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw ObservedVoiceRecordingError.invalidInputFormat
        }
        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                throw ObservedVoiceRecordingError.invalidInputFormat
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copiedBuffer
    }

    private func liveAudioChunks(from buffer: AVAudioPCMBuffer) -> [LiveAudioSamples] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let value = channelData[channel][frame]
                if value.isFinite {
                    sum += value
                }
            }
            pendingSamples.append(sum / Float(channelCount))
        }

        var chunks: [LiveAudioSamples] = []
        while pendingSamples.count >= targetFrames {
            let samples = Array(pendingSamples[..<targetFrames])
            pendingSamples.removeFirst(targetFrames)
            chunks.append(LiveAudioSamples(
                samples: samples,
                sampleRate: sampleRate,
                startTime: Double(emittedFrames) / sampleRate
            ))
            emittedFrames += samples.count
        }
        return chunks
    }
}

// The tap deep-copies this buffer before transfer; only the serial writer reads it.
nonisolated private struct OwnedRecordingPCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}
