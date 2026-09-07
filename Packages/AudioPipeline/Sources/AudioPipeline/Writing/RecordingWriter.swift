@preconcurrency import AVFAudio
import Dispatch
import Foundation
import Synchronization

public final class RecordingWriter: @unchecked Sendable {
    struct Control: Sendable {
        var shouldStop = false
        var commandRejection: AudioCaptureError?
        var commandQueue = RecordingWriterCommandQueue()
    }

    struct Hooks: Sendable {
        var beforeNormalRead: (@Sendable () -> Void)?
        var afterCommandLifecycleAccepted: (@Sendable () -> Void)?
    }

    private enum LifecycleState {
        case notStarted
        case starting(Thread)
        case running(Thread)
        case finished(Result<FinishedRecordingOutput, Error>)
    }

    static let chunkFrames = 1_024

    let inputSampleRate: Double
    let inputChannelCount: Int
    let layout: MixChannelLayout
    let ring: SPSCRingBuffer
    let wake: DispatchSemaphore
    let outputURL: URL
    let microphoneGain: Float
    let systemGain: Float
    let diskSpaceChecker: any DiskSpaceChecking
    let diskSpaceWatchdogIntervalFrames: UInt64
    let sinkFactory: any RecordingFileSinkFactory
    let control = Mutex(Control())
    var hooks = Hooks()
    // Written only by the non-realtime writer; UI polling never touches HAL IO.
    private let measuredProgress = Mutex(CaptureProgress(duration: 0, microphonePeak: 0, systemPeak: 0))
    public var currentProgress: CaptureProgress? { measuredProgress.withLock { $0 } }

    func updateProgress(frames: UInt64, microphone: Float, system: Float) {
        measuredProgress.withLock {
            $0 = CaptureProgress(duration: Double(frames) / RecordingFileSettings.outputSampleRate,
                microphonePeak: microphone, systemPeak: system)
        }
    }
    private let lifecycleLock = NSLock()
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let completionGroup = DispatchGroup()
    private let startupResult = LockedResultBox<Void>()
    private var lifecycleState: LifecycleState = .notStarted
    private var didLeaveCompletionGroup = false
    private var completionHandler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?

    public convenience init(
        inputSampleRate: Double,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        diskSpaceChecker: any DiskSpaceChecking = VolumeDiskSpaceChecker()
    ) throws {
        try self.init(
            inputSampleRate: inputSampleRate,
            inputChannelCount: inputChannelCount,
            layout: layout,
            ring: ring,
            wake: wake,
            outputURL: outputURL,
            microphoneGain: microphoneGain,
            systemGain: systemGain,
            diskSpaceChecker: diskSpaceChecker,
            diskSpaceWatchdogIntervalFrames: DiskSpaceMonitor.defaultWatchdogIntervalFrames,
            sinkFactory: AVAudioRecordingFileSinkFactory()
        )
    }

    internal init(
        inputSampleRate: Double,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        diskSpaceChecker: any DiskSpaceChecking,
        diskSpaceWatchdogIntervalFrames: UInt64 = DiskSpaceMonitor.defaultWatchdogIntervalFrames,
        sinkFactory: any RecordingFileSinkFactory
    ) throws {
        guard inputSampleRate.isFinite, inputSampleRate > 0, inputChannelCount > 0 else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }
        self.inputSampleRate = inputSampleRate
        self.inputChannelCount = inputChannelCount
        self.layout = layout
        self.ring = ring
        self.wake = wake
        self.outputURL = outputURL
        self.microphoneGain = microphoneGain
        self.systemGain = systemGain
        self.diskSpaceChecker = diskSpaceChecker
        self.diskSpaceWatchdogIntervalFrames = diskSpaceWatchdogIntervalFrames
        self.sinkFactory = sinkFactory
        completionGroup.enter()
    }

    public func start() throws {
        let writerThread = Thread { [self] in
            runOnWriterThread()
        }
        writerThread.name = "NoteTaker.RecordingWriter"
        writerThread.qualityOfService = .userInteractive

        lifecycleLock.lock()
        guard case .notStarted = lifecycleState else {
            lifecycleLock.unlock()
            throw AudioCaptureError.fileWriteFailed("Recording writer already started")
        }
        lifecycleState = .starting(writerThread)
        lifecycleLock.unlock()

        writerThread.start()
        startupSemaphore.wait()
        do {
            try startupResult.require().get()
        } catch {
            throw error
        }

        lifecycleLock.lock()
        if case .starting = lifecycleState {
            lifecycleState = .running(writerThread)
        }
        lifecycleLock.unlock()
    }

    public func requestStop() {
        rejectPendingCommands(with: AudioCaptureError.fileWriteFailed("Recording writer already stopped")) { state in
            state.shouldStop = true
        }
        wake.signal()
    }

    public func pause() throws -> RecordingSegmentOutput {
        try enqueue { command in
            .pause(command, boundary: ring.writeSequenceSnapshot)
        }
    }

    func pause(upToWriteSequence boundary: Int) throws -> RecordingSegmentOutput {
        try enqueue { command in
            .pause(command, boundary: boundary)
        }
    }

    public func resume(outputURL: URL) throws {
        let _: Void = try enqueue { command in
            command.outputURL = outputURL
            return .resume(command, boundary: ring.writeSequenceSnapshot)
        }
    }

    public func setCompletionHandler(_ handler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?) {
        lifecycleLock.lock()
        completionHandler = handler
        lifecycleLock.unlock()
    }

    public func join() throws -> FinishedRecordingOutput {
        lifecycleLock.lock()
        switch lifecycleState {
        case .notStarted:
            lifecycleLock.unlock()
            throw AudioCaptureError.fileWriteFailed("Recording writer not started")
        case let .finished(result):
            lifecycleLock.unlock()
            return try result.get()
        case .starting, .running:
            lifecycleLock.unlock()
        }

        completionGroup.wait()

        lifecycleLock.lock()
        guard case let .finished(result) = lifecycleState else {
            lifecycleLock.unlock()
            throw AudioCaptureError.fileWriteFailed("Recording writer result unavailable")
        }
        lifecycleLock.unlock()
        return try result.get()
    }

    private func runOnWriterThread() {
        var sink: (any RecordingFileSink)?
        var didSignalStartup = false
        do {
            let outputFormat = try AudioConverterDriver.makeInterleavedFloat32Format(
                sampleRate: RecordingFileSettings.outputSampleRate,
                channelCount: RecordingFileSettings.outputChannelCount
            )
            let openedSink = try sinkFactory.open(
                url: outputURL,
                settings: RecordingFileSettings.aacM4A,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            sink = openedSink
            startupResult.set(.success(()))
            didSignalStartup = true
            startupSemaphore.signal()

            sink = nil
            let output = try processAudio(outputFormat: outputFormat, initialSink: openedSink)
            rejectPendingCommands(with: AudioCaptureError.fileWriteFailed("Recording writer already stopped"))
            finish(.success(output), notifyCompletion: true)
        } catch {
            let mapped = mapError(error)
            sink?.close()
            rejectPendingCommands(with: mapped)
            if !didSignalStartup {
                startupResult.set(.failure(mapped))
                startupSemaphore.signal()
            }
            finish(.failure(mapped), notifyCompletion: didSignalStartup)
        }
    }

    private func finish(_ result: Result<FinishedRecordingOutput, Error>, notifyCompletion: Bool) {
        let handler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?
        lifecycleLock.lock()
        lifecycleState = .finished(result)
        let shouldLeave = !didLeaveCompletionGroup
        didLeaveCompletionGroup = true
        handler = notifyCompletion ? completionHandler : nil
        lifecycleLock.unlock()

        if shouldLeave {
            completionGroup.leave()
        }
        handler?(result)
    }

    private func mapError(_ error: Error) -> AudioCaptureError {
        if let audioError = error as? AudioCaptureError {
            return audioError
        }
        return AudioCaptureError.fileWriteFailed(String(describing: error))
    }

    private func enqueue<T>(
        _ makeAction: (PendingWriterCommand<T>) -> RecordingWriterCommand
    ) throws -> T {
        lifecycleLock.lock()
        switch lifecycleState {
        case .running:
            lifecycleLock.unlock()
        case .finished(.failure(let error)):
            lifecycleLock.unlock()
            throw error
        case .finished(.success):
            lifecycleLock.unlock()
            throw AudioCaptureError.fileWriteFailed("Recording writer already stopped")
        case .notStarted, .starting:
            lifecycleLock.unlock()
            throw AudioCaptureError.fileWriteFailed("Recording writer not running")
        }

        hooks.afterCommandLifecycleAccepted?()
        let command = PendingWriterCommand<T>()
        let rejection = control.withLock { state -> AudioCaptureError? in
            if let rejection = state.commandRejection {
                return rejection
            }
            state.commandQueue.enqueue(makeAction(command))
            return nil
        }
        if let rejection {
            throw rejection
        }
        wake.signal()
        command.semaphore.wait()
        return try command.result()
    }

    private func rejectPendingCommands(
        with error: AudioCaptureError,
        update: ((inout Control) -> Void)? = nil
    ) {
        let commands = control.withLock { state in
            update?(&state)
            state.commandRejection = error
            return state.commandQueue.drain()
        }
        for command in commands {
            command.complete(with: error)
        }
    }
}

enum RecordingWriterCommand: Sendable {
    case pause(PendingWriterCommand<RecordingSegmentOutput>, boundary: Int)
    case resume(PendingWriterCommand<Void>, boundary: Int)

    func complete(with error: Error) {
        switch self {
        case .pause(let command, _):
            command.complete(.failure(error))
        case .resume(let command, _):
            command.complete(.failure(error))
        }
    }
}

struct RecordingWriterCommandQueue: Sendable {
    private var commands: [RecordingWriterCommand] = []

    mutating func enqueue(_ command: RecordingWriterCommand) {
        commands.append(command)
    }

    mutating func dequeue() -> RecordingWriterCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func drain() -> [RecordingWriterCommand] {
        let drained = commands
        commands.removeAll()
        return drained
    }

    var isEmpty: Bool {
        commands.isEmpty
    }
}

final class PendingWriterCommand<Output>: @unchecked Sendable {
    var outputURL: URL?
    let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var storedResult: Result<Output, Error>?

    init(semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)) {
        self.semaphore = semaphore
    }

    func complete(_ result: Result<Output, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }

    func result() throws -> Output {
        lock.lock()
        let result = storedResult
        lock.unlock()
        guard let result else {
            throw AudioCaptureError.fileWriteFailed("Recording writer command result unavailable")
        }
        return try result.get()
    }
}
