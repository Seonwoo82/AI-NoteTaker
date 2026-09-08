@testable import AudioPipeline
import AVFAudio
import Foundation
import Testing

@Test("Writer progress reports measured source peaks and freezes on pause")
func writerProgressReportsMeasuredSourcePeaksAndFreezesOnPause() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 1_024, channelCount: 3)
    let samples = Array(repeating: [Float(0.2), Float(0.4), Float(-0.3)], count: 512).flatMap { $0 }
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 512) }
    let writer = try RecordingWriter(inputSampleRate: 48_000, inputChannelCount: 3,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: [1, 2]),
        ring: ring, wake: DispatchSemaphore(value: 0), outputURL: temporaryDirectory().appendingPathComponent("meter.m4a"),
        microphoneGain: 1, systemGain: 1, diskSpaceChecker: AlwaysEnoughDiskSpace(), sinkFactory: MemorySinkFactory())
    try writer.start()
    defer { writer.requestStop(); _ = try? writer.join() }
    let deadline = Date().addingTimeInterval(1)
    while (writer.currentProgress?.duration ?? 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    let live = try #require(writer.currentProgress)
    #expect(live.microphonePeak == 0.2)
    #expect(live.systemPeak == 0.4)
    #expect(abs(live.duration - 512.0 / 48_000) < 0.000_001)
    _ = try writer.pause()
    let paused = try #require(writer.currentProgress)
    #expect(paused.duration == live.duration)
    #expect(paused.microphonePeak == 0)
    #expect(paused.systemPeak == 0)
}

@Test("Recording writer emits bounded mono live samples from recorded audio")
func recordingWriterEmitsBoundedMonoLiveSamplesFromRecordedAudio() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 65_536, channelCount: 1)
    let frames = 48_000
    let samples = Array<Float>(repeating: 0.25, count: frames)
    #expect(samples.withUnsafeBufferPointer { ring.write($0, frameCount: frames) } == frames)
    let collector = LiveAudioSampleCollector()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: temporaryDirectory().appendingPathComponent("live.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        liveAudioHandler: collector.append,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: MemorySinkFactory()
    )

    try writer.start()
    writer.requestStop()
    let output = try writer.join()

    let chunks = collector.chunks()
    #expect(output.stats.outputFramesWritten == UInt64(frames))
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.samples.count == 24_000 })
    #expect(chunks.map(\.sampleRate) == [48_000, 48_000])
    #expect(chunks.map(\.startTime) == [0, 0.5])
    #expect(chunks.flatMap(\.samples).allSatisfy { abs($0 - 0.25) < 0.000_001 })
}

@Test("Recording writer keeps live sample time continuous across pause and resume")
func recordingWriterKeepsLiveSampleTimeContinuousAcrossPauseAndResume() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 65_536, channelCount: 1)
    let firstSamples = Array<Float>(repeating: 0.1, count: 24_000)
    #expect(firstSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 24_000) } == 24_000)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = LiveAudioSampleCollector()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: directory.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        liveAudioHandler: collector.append,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: RotatingMemorySinkFactory()
    )

    try writer.start()
    _ = try writer.pause()
    let pausedSamples = Array<Float>(repeating: 0.8, count: 24_000)
    #expect(pausedSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 24_000) } == 24_000)
    try writer.resume(outputURL: directory.appendingPathComponent("001.m4a"))
    let secondSamples = Array<Float>(repeating: 0.2, count: 24_000)
    #expect(secondSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 24_000) } == 24_000)
    writer.requestStop()
    _ = try writer.join()

    let chunks = collector.chunks()
    #expect(chunks.map(\.startTime) == [0, 0.5])
    #expect(chunks[0].samples.allSatisfy { abs($0 - 0.1) < 0.000_001 })
    #expect(chunks[1].samples.allSatisfy { abs($0 - 0.2) < 0.000_001 })
}

@Test("Recording writer join before start throws without waiting")
func recordingWriterJoinBeforeStartThrowsWithoutWaiting() throws {
    let writer = try makeLifecycleWriter()

    #expect(throws: AudioCaptureError.fileWriteFailed("Recording writer not started")) {
        _ = try writer.join()
    }
}

@Test("Recording writer double start remains rejected")
func recordingWriterDoubleStartRemainsRejected() throws {
    let writer = try makeLifecycleWriter()

    try writer.start()
    #expect(throws: AudioCaptureError.fileWriteFailed("Recording writer already started")) {
        try writer.start()
    }
    writer.requestStop()
    _ = try writer.join()
    #expect(throws: AudioCaptureError.fileWriteFailed("Recording writer already started")) {
        try writer.start()
    }
}

@Test("Recording writer repeated join returns cached successful output")
func recordingWriterRepeatedJoinReturnsCachedSuccessfulOutput() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 1_024, channelCount: 1)
    let samples = sineWave(frameCount: 512, sampleRate: 48_000, frequency: 220, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 512) }
    let writer = try makeLifecycleWriter(ring: ring)

    try writer.start()
    writer.requestStop()
    let first = try writer.join()
    let second = try writer.join()

    #expect(first.url == second.url)
    #expect(first.duration == second.duration)
    #expect(first.sampleRate == second.sampleRate)
    #expect(first.channelCount == second.channelCount)
    #expect(first.bars == second.bars)
    #expect(first.stats == second.stats)
    #expect(first.warnings == second.warnings)
}

@Test("Recording writer repeated join returns cached failure")
func recordingWriterRepeatedJoinReturnsCachedFailure() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 2_048, channelCount: 1)
    let samples = sineWave(frameCount: 2_048, sampleRate: 48_000, frequency: 220, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 2_048) }
    let writer = try makeLifecycleWriter(ring: ring, sinkFactory: FailingSinkFactory())

    try writer.start()
    writer.requestStop()
    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic failure")) {
        _ = try writer.join()
    }
    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic failure")) {
        _ = try writer.join()
    }
}

@Test("Recording writer concurrent cleanup joins all observe one completion")
func recordingWriterConcurrentCleanupJoinsAllObserveOneCompletion() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 1_024, channelCount: 1)
    let samples = sineWave(frameCount: 256, sampleRate: 48_000, frequency: 220, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 256) }
    let writer = try makeLifecycleWriter(ring: ring)

    try writer.start()
    writer.requestStop()

    let joiners = 4
    let ready = DispatchGroup()
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let joinResults = JoinResults()

    for _ in 0..<joiners {
        ready.enter()
        finished.enter()
        DispatchQueue.global().async {
            ready.leave()
            release.wait()
            do {
                let output = try writer.join()
                joinResults.append(output)
            } catch {
                joinResults.append(error)
            }
            finished.leave()
        }
    }
    #expect(ready.wait(timeout: .now() + .seconds(1)) == .success)
    for _ in 0..<joiners { release.signal() }

    #expect(finished.wait(timeout: .now() + .seconds(3)) == .success)
    let capturedOutputs = joinResults.outputs()
    let capturedErrors = joinResults.errors()
    #expect(capturedErrors.isEmpty)
    #expect(capturedOutputs.count == joiners)
    let firstOutput = try #require(capturedOutputs.first)
    for output in capturedOutputs {
        #expect(output.url == firstOutput.url)
        #expect(output.duration == firstOutput.duration)
        #expect(output.sampleRate == firstOutput.sampleRate)
        #expect(output.channelCount == firstOutput.channelCount)
        #expect(output.bars == firstOutput.bars)
        #expect(output.stats == firstOutput.stats)
        #expect(output.warnings == firstOutput.warnings)
    }
}

@Test("Recording writer startup failure completes repeated joins")
func recordingWriterStartupFailureCompletesRepeatedJoins() throws {
    let writer = try makeLifecycleWriter(sinkFactory: OpenFailingSinkFactory())

    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic open failure")) {
        try writer.start()
    }
    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic open failure")) {
        _ = try writer.join()
    }
    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic open failure")) {
        _ = try writer.join()
    }
}

@Test("Recording writer pause closes a run and resume records the next run without paused frames")
func recordingWriterPauseClosesRunAndResumeRecordsNextRunWithoutPausedFrames() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8_192, channelCount: 1)
    let firstSamples = sineWave(frameCount: 1_024, sampleRate: 48_000, frequency: 220, amplitude: 0.2)
    #expect(firstSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 1_024) } == 1_024)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = RotatingMemorySinkFactory()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: directory.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: factory
    )

    try writer.start()
    let firstSegment = try writer.pause()
    let pausedSamples = sineWave(frameCount: 2_048, sampleRate: 48_000, frequency: 330, amplitude: 0.2)
    #expect(pausedSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 2_048) } == 2_048)
    try writer.resume(outputURL: directory.appendingPathComponent("001.m4a"))
    let secondSamples = sineWave(frameCount: 2_048, sampleRate: 48_000, frequency: 440, amplitude: 0.2)
    #expect(secondSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 2_048) } == 2_048)
    writer.requestStop()
    let output = try writer.join()

    #expect(firstSegment.url.lastPathComponent == "000.m4a")
    #expect(firstSegment.outputFramesWritten == 1_024)
    #expect(factory.openedURLs().map(\.lastPathComponent) == ["000.m4a", "001.m4a"])
    #expect(factory.closeCounts() == [1, 1])
    #expect(factory.writtenFrameCounts() == [1_024, 2_048])
    #expect(output.url.lastPathComponent == "001.m4a")
    #expect(output.stats.outputFramesWritten == 3_072)
    #expect(output.stats.inputFramesRead == 5_120)
    expect(output.duration, equals: Double(3_072) / 48_000, tolerance: 0.000_001)
}

@Test("Recording writer bounds normal reads when pause is queued after read decision")
func recordingWriterBoundsNormalReadsWhenPauseIsQueuedAfterReadDecision() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4_096, channelCount: 1)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = CapturingRotatingMemorySinkFactory(writeDelay: 0)
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: directory.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: factory
    )
    let enteredReadDecision = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let blockFirstRead = LockedBool(true)
    writer.hooks.beforeNormalRead = {
        guard blockFirstRead.takeIfSet() else { return }
        enteredReadDecision.signal()
        releaseRead.wait()
    }

    try writer.start()
    #expect(enteredReadDecision.wait(timeout: .now() + .seconds(1)) == .success)

    let prePauseSamples = Array<Float>(repeating: 0.1, count: 512)
    #expect(prePauseSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 512) } == 512)
    let pauseBoundary = ring.writeSequenceSnapshot
    let pauseFinished = DispatchGroup()
    let pauseResult = CommandResults<RecordingSegmentOutput>()
    pauseFinished.enter()
    DispatchQueue.global().async {
        do {
            pauseResult.append(try writer.pause(upToWriteSequence: pauseBoundary))
        } catch {
            pauseResult.append(error)
        }
        pauseFinished.leave()
    }
    #expect(waitUntil("pause command queued") {
        writer.control.withLock { !$0.commandQueue.isEmpty }
    })
    let postPauseSamples = Array<Float>(repeating: 0.9, count: 512)
    #expect(postPauseSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 512) } == 512)
    releaseRead.signal()

    #expect(pauseFinished.wait(timeout: .now() + .seconds(1)) == .success)
    writer.requestStop()
    _ = try writer.join()

    #expect(pauseResult.errors().isEmpty)
    let segment = try #require(pauseResult.outputs().first)
    #expect(segment.outputFramesWritten == 512)
    #expect(factory.maxAbsoluteSamples().first ?? 0 <= 0.11)
}

@Test("Recording writer rejects command when stop wins after lifecycle check")
func recordingWriterRejectsCommandWhenStopWinsAfterLifecycleCheck() throws {
    let writer = try makeLifecycleWriter()
    let lifecycleAccepted = DispatchSemaphore(value: 0)
    let releaseEnqueue = DispatchSemaphore(value: 0)
    let blockFirstEnqueue = LockedBool(true)
    writer.hooks.afterCommandLifecycleAccepted = {
        guard blockFirstEnqueue.takeIfSet() else { return }
        lifecycleAccepted.signal()
        releaseEnqueue.wait()
    }
    try writer.start()

    let finished = DispatchGroup()
    let results = CommandResults<RecordingSegmentOutput>()
    finished.enter()
    DispatchQueue.global().async {
        do {
            results.append(try writer.pause())
        } catch {
            results.append(error)
        }
        finished.leave()
    }

    #expect(lifecycleAccepted.wait(timeout: .now() + .seconds(1)) == .success)
    writer.requestStop()
    _ = try writer.join()
    releaseEnqueue.signal()

    if finished.wait(timeout: .now() + .milliseconds(200)) != .success {
        let commands = writer.control.withLock { state in
            state.commandQueue.drain()
        }
        for command in commands {
            command.complete(with: AudioCaptureError.fileWriteFailed("test cleanup"))
        }
        #expect(finished.wait(timeout: .now() + .seconds(1)) == .success)
        Issue.record("pause caller was stranded after stop won the command publication race")
    }

    #expect(results.outputs().isEmpty)
    #expect(results.errors().containsAudioError(.fileWriteFailed("Recording writer already stopped")))
}

@Test("Recording writer command queue preserves every command in FIFO order")
func recordingWriterCommandQueuePreservesEveryCommandInFIFOOrder() throws {
    let first = PendingWriterCommand<RecordingSegmentOutput>()
    let second = PendingWriterCommand<Void>()
    var queue = RecordingWriterCommandQueue()

    queue.enqueue(.pause(first, boundary: 11))
    queue.enqueue(.resume(second, boundary: 22))

    switch queue.dequeue() {
    case .pause(let command, let boundary)?:
        #expect(command === first)
        #expect(boundary == 11)
    default:
        Issue.record("first command was not the queued pause")
    }
    switch queue.dequeue() {
    case .resume(let command, let boundary)?:
        #expect(command === second)
        #expect(boundary == 22)
    default:
        Issue.record("second command was not the queued resume")
    }
    if case nil = queue.dequeue() {
    } else {
        Issue.record("queue was not empty after both commands")
    }
}

@Test("Recording writer rejects duplicate pause and resume races")
func recordingWriterRejectsDuplicatePauseAndResumeRaces() throws {
    let writer = try makeLifecycleWriter()

    try writer.start()
    #expect(throws: AudioCaptureError.fileWriteFailed("Recording writer is not paused")) {
        try writer.resume(outputURL: temporaryDirectory().appendingPathComponent("001.m4a"))
    }
    _ = try writer.pause()
    #expect(throws: AudioCaptureError.fileWriteFailed("Recording writer is already paused")) {
        _ = try writer.pause()
    }
    writer.requestStop()
    _ = try writer.join()
}

@Test("Recording writer completes every concurrent duplicate pause caller")
func recordingWriterCompletesEveryConcurrentDuplicatePauseCaller() throws {
    let writer = try makeLifecycleWriter()
    try writer.start()

    let release = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let results = CommandResults<RecordingSegmentOutput>()
    for _ in 0..<2 {
        finished.enter()
        DispatchQueue.global().async {
            release.wait()
            do {
                results.append(try writer.pause())
            } catch {
                results.append(error)
            }
            finished.leave()
        }
    }

    release.signal()
    release.signal()
    #expect(finished.wait(timeout: .now() + .seconds(2)) == .success)
    writer.requestStop()
    _ = try writer.join()

    #expect(results.outputs().count == 1)
    let errors = results.errors()
    #expect(errors.count == 1)
    #expect(errors.containsAudioError(.fileWriteFailed("Recording writer is already paused")))
}

@Test("Recording writer completes every concurrent duplicate resume caller")
func recordingWriterCompletesEveryConcurrentDuplicateResumeCaller() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try makeLifecycleWriter(
        sinkFactory: RotatingMemorySinkFactory(),
        outputURL: directory.appendingPathComponent("000.m4a")
    )
    try writer.start()
    _ = try writer.pause()

    let release = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let results = CommandResults<Void>()
    for index in 0..<2 {
        finished.enter()
        DispatchQueue.global().async {
            release.wait()
            do {
                try writer.resume(outputURL: directory.appendingPathComponent("00\(index + 1).m4a"))
                results.append(())
            } catch {
                results.append(error)
            }
            finished.leave()
        }
    }

    release.signal()
    release.signal()
    #expect(finished.wait(timeout: .now() + .seconds(2)) == .success)
    writer.requestStop()
    _ = try writer.join()

    #expect(results.outputs().count == 1)
    let errors = results.errors()
    #expect(errors.count == 1)
    #expect(errors.containsAudioError(.fileWriteFailed("Recording writer is not paused")))
}

@Test("Recording writer pause completes while producer continues and excludes post-request frames")
func recordingWriterPauseCompletesWhileProducerContinuesAndExcludesPostRequestFrames() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4_096, channelCount: 1)
    let prePauseSamples = Array<Float>(repeating: 0.1, count: 2_048)
    #expect(prePauseSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 2_048) } == 2_048)
    let pauseBoundary = ring.writeSequenceSnapshot
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = CapturingRotatingMemorySinkFactory(writeDelay: 0.003)
    let wake = DispatchSemaphore(value: 0)
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: wake,
        outputURL: directory.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: factory
    )

    try writer.start()

    let pauseFinished = DispatchGroup()
    let pauseResult = CommandResults<RecordingSegmentOutput>()
    pauseFinished.enter()
    DispatchQueue.global().async {
        do {
            pauseResult.append(try writer.pause(upToWriteSequence: pauseBoundary))
        } catch {
            pauseResult.append(error)
        }
        pauseFinished.leave()
    }

    let keepProducing = LockedBool(true)
    let producerFinished = DispatchGroup()
    producerFinished.enter()
    DispatchQueue.global().async {
        let postPauseSamples = Array<Float>(repeating: 0.9, count: 256)
        while keepProducing.get() {
            _ = postPauseSamples.withUnsafeBufferPointer { ring.write($0, frameCount: 256) }
            wake.signal()
        }
        producerFinished.leave()
    }

    #expect(pauseFinished.wait(timeout: .now() + .seconds(1)) == .success)
    keepProducing.set(false)
    #expect(producerFinished.wait(timeout: .now() + .seconds(1)) == .success)
    writer.requestStop()
    _ = try writer.join()

    #expect(pauseResult.errors().isEmpty)
    #expect(pauseResult.outputs().count == 1)
    #expect(factory.closeCounts().first == 1)
    #expect(factory.maxAbsoluteSamples().first ?? 0 <= 0.11)
}

private final class JoinResults: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOutputs: [FinishedRecordingOutput] = []
    private var recordedErrors: [Error] = []

    func append(_ output: FinishedRecordingOutput) {
        lock.lock()
        recordedOutputs.append(output)
        lock.unlock()
    }

    func append(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }

    func outputs() -> [FinishedRecordingOutput] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutputs
    }

    func errors() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }
}

private final class CommandResults<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOutputs: [Output] = []
    private var recordedErrors: [Error] = []

    func append(_ output: Output) {
        lock.lock()
        recordedOutputs.append(output)
        lock.unlock()
    }

    func append(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }

    func outputs() -> [Output] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutputs
    }

    func errors() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }
}

private final class LiveAudioSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChunks: [LiveAudioSamples] = []

    func append(_ chunk: LiveAudioSamples) {
        lock.lock()
        recordedChunks.append(chunk)
        lock.unlock()
    }

    func chunks() -> [LiveAudioSamples] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChunks
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func takeIfSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value else { return false }
        value = false
        return true
    }
}

private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    Issue.record("Timed out waiting for \(description)")
    return false
}

private extension Array where Element == Error {
    func containsAudioError(_ expected: AudioCaptureError) -> Bool {
        contains { error in
            guard let audioError = error as? AudioCaptureError else { return false }
            return audioError == expected
        }
    }
}

private func makeLifecycleWriter(
    ring: SPSCRingBuffer? = nil,
    sinkFactory: any RecordingFileSinkFactory = MemorySinkFactory(),
    outputURL: URL? = nil
) throws -> RecordingWriter {
    let writerRing = try ring ?? SPSCRingBuffer(capacityFrames: 1_024, channelCount: 1)
    let writerOutputURL = try outputURL ?? temporaryDirectory().appendingPathComponent("lifecycle.m4a")
    return try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: writerRing,
        wake: DispatchSemaphore(value: 0),
        outputURL: writerOutputURL,
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: sinkFactory
    )
}

private final class OpenFailingSinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        throw AudioCaptureError.fileWriteFailed("synthetic open failure")
    }
}

@Test("Real recording writer rejects an existing file without changing its bytes")
func realRecordingWriterRejectsExistingFileWithoutChangingBytes() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("existing.m4a")
    let originalBytes = Data([0x00, 0x11, 0x7f, 0x80, 0xfe, 0xff])
    try originalBytes.write(to: url)

    expectRealWriterOutputCollision(at: url)

    #expect(try Data(contentsOf: url) == originalBytes)
}

@Test("Real recording writer rejects an existing directory without replacing it")
func realRecordingWriterRejectsExistingDirectoryWithoutReplacingIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("existing.m4a", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

    expectRealWriterOutputCollision(at: url)

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test("Real recording writer rejects a symlink without changing its link or target")
func realRecordingWriterRejectsSymlinkWithoutChangingLinkOrTarget() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let targetURL = directory.appendingPathComponent("target.m4a")
    let url = directory.appendingPathComponent("linked-output.m4a")
    let originalBytes = Data([0xde, 0xad, 0xbe, 0xef])
    try originalBytes.write(to: targetURL)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: targetURL.path)

    expectRealWriterOutputCollision(at: url)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == targetURL.path)
    #expect(try Data(contentsOf: targetURL) == originalBytes)
}

@Test("Real recording writer rejects a dangling symlink without creating its target")
func realRecordingWriterRejectsDanglingSymlinkWithoutCreatingTarget() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let targetURL = directory.appendingPathComponent("missing-target.m4a")
    let url = directory.appendingPathComponent("dangling-output.m4a")
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: targetURL.path)

    expectRealWriterOutputCollision(at: url)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == targetURL.path)
    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
}

@Test("Real recording writer removes its owned reservation when file initialization fails")
func realRecordingWriterRemovesOwnedReservationWhenFileInitializationFails() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("initialization-failure.m4a")
    let factory = AVAudioRecordingFileSinkFactory(fileOpener: { openedURL, _, _, _ in
        try Data("partial-stage".utf8).write(to: openedURL, options: .withoutOverwriting)
        #expect(FileManager.default.fileExists(atPath: openedURL.path))
        throw SyntheticFileInitializationError()
    })

    do {
        _ = try factory.open(
            url: url,
            settings: RecordingFileSettings.aacM4A,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        Issue.record("writer unexpectedly initialized the file")
    } catch is SyntheticFileInitializationError {
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("Real recording writer initialization failure never removes a replacement inode")
func realRecordingWriterInitializationFailureNeverRemovesReplacementInode() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("replacement.m4a")
    let replacementBytes = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
    let replacementURL = LockedTestURL()
    let factory = AVAudioRecordingFileSinkFactory(fileOpener: { openedURL, _, _, _ in
        let stagedDirectory = openedURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: stagedDirectory)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        let foreignURL = stagedDirectory.appendingPathComponent("foreign")
        try replacementBytes.write(to: foreignURL, options: .withoutOverwriting)
        replacementURL.set(foreignURL)
        throw SyntheticFileInitializationError()
    })

    do {
        _ = try factory.open(
            url: url,
            settings: RecordingFileSettings.aacM4A,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        Issue.record("writer unexpectedly initialized the file")
    } catch is SyntheticFileInitializationError {
        let foreignURL = try #require(replacementURL.get())
        #expect(try Data(contentsOf: foreignURL) == replacementBytes)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private struct SyntheticFileInitializationError: Error {}

private final class LockedTestURL: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    func set(_ value: URL) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func expectRealWriterOutputCollision(
    at url: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let sink = try AVAudioRecordingFileSinkFactory().open(
            url: url,
            settings: RecordingFileSettings.aacM4A,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        sink.close()
        Issue.record("writer unexpectedly opened existing output", sourceLocation: sourceLocation)
    } catch AudioCaptureError.outputAlreadyExists(let path) {
        #expect(path == url.path, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

@Test("Recording writer drains direct 48 kHz mono input into readable stereo AAC")
func recordingWriterDrainsDirect48kMonoInputIntoReadableStereoAAC() throws {
    let frameCount = 4_800
    let samples = sineWave(frameCount: frameCount, sampleRate: 48_000, frequency: 440, amplitude: 0.25)
    let ring = try SPSCRingBuffer(capacityFrames: frameCount, channelCount: 1)
    let accepted = samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) }
    #expect(accepted == frameCount)

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("direct.m4a")
    let wake = DispatchSemaphore(value: 0)
    let capturingFactory = CapturingSinkFactory(wrapping: AVAudioRecordingFileSinkFactory())
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: wake,
        outputURL: url,
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: capturingFactory
    )

    try writer.start()
    wake.signal()
    writer.requestStop()
    let output = try writer.join()

    #expect(output.url == url)
    expect(output.duration, equals: 0.1, tolerance: 0.000_001)
    #expect(output.sampleRate == 48_000)
    #expect(output.channelCount == 2)
    #expect(output.bars.count == 10)
    #expect(output.stats.inputFramesRead == UInt64(frameCount))
    #expect(output.stats.outputFramesWritten == UInt64(frameCount))
    #expect(output.stats.fileWriteCalls > 0)
    #expect(output.stats.barsEmitted == 10)
    #expect(output.stats.ringDroppedFrames == 0)
    #expect(output.stats.ringOverflowCount == 0)
    #expect(ring.availableFrames == 0)
    #expect(output.warnings.isEmpty)

    let preEncode = capturingFactory.capturedSamples()
    #expect(preEncode.count == frameCount * 2)
    for frame in 0..<frameCount {
        expect(preEncode[frame * 2], equals: samples[frame], tolerance: 0.000_001)
        expect(preEncode[frame * 2 + 1], equals: samples[frame], tolerance: 0.000_001)
    }

    let decoded = try readInterleavedFloat32(url)
    #expect(decoded.sampleRate == 48_000)
    #expect(decoded.channelCount == 2)
    #expect(decoded.samples.count >= frameCount * 2)
    #expect(correlation(decoded.samples, channel: 0, channelCount: 2, reference: samples) > 0.90)
    #expect(correlation(decoded.samples, channel: 1, channelCount: 2, reference: samples) > 0.90)
}

private final class CapturingSinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    private let wrapped: any RecordingFileSinkFactory
    private let lock = NSLock()
    private var samples: [Float] = []

    init(wrapping wrapped: any RecordingFileSinkFactory) {
        self.wrapped = wrapped
    }

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        let sink = try wrapped.open(
            url: url,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: interleaved
        )
        return CapturingSink(wrapped: sink) { [weak self] buffer in
            self?.append(buffer)
        }
    }

    func capturedSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let extracted = extractInterleavedSamples(buffer)
        lock.lock()
        samples.append(contentsOf: extracted)
        lock.unlock()
    }
}

private final class CapturingSink: RecordingFileSink, @unchecked Sendable {
    private let wrapped: any RecordingFileSink
    private let capture: @Sendable (AVAudioPCMBuffer) -> Void

    var processingFormat: AVAudioFormat { wrapped.processingFormat }

    init(wrapped: any RecordingFileSink, capture: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.wrapped = wrapped
        self.capture = capture
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        capture(buffer)
        try wrapped.write(buffer)
    }

    func close() {
        wrapped.close()
    }
}

private struct AlwaysEnoughDiskSpace: DiskSpaceChecking {
    func availableCapacity(at url: URL) throws -> Int64 { 1_000_000_000 }
}

private struct DecodedSamples {
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]
}

private func readInterleavedFloat32(_ url: URL) throws -> DecodedSamples {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else {
        throw TestFailure("could not allocate decode buffer")
    }
    try file.read(into: buffer)
    return DecodedSamples(
        sampleRate: file.fileFormat.sampleRate,
        channelCount: Int(file.fileFormat.channelCount),
        samples: extractInterleavedSamples(buffer)
    )
}

private func extractInterleavedSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let audioBufferList = buffer.audioBufferList.pointee
    guard audioBufferList.mNumberBuffers == 1 else { return [] }
    let audioBuffer = audioBufferList.mBuffers
    guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { return [] }
    let sampleCount = Int(buffer.frameLength) * Int(buffer.format.channelCount)
    return Array(UnsafeBufferPointer(start: data, count: sampleCount))
}

private func sineWave(
    frameCount: Int,
    sampleRate: Double,
    frequency: Double,
    amplitude: Float
) -> [Float] {
    (0..<frameCount).map { frame in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
    }
}

private func correlation(
    _ interleaved: [Float],
    channel: Int,
    channelCount: Int,
    reference: [Float]
) -> Double {
    let frames = min(reference.count, interleaved.count / channelCount)
    guard frames > 0 else { return 0 }
    var dot = 0.0
    var actualEnergy = 0.0
    var referenceEnergy = 0.0
    for frame in 0..<frames {
        let actual = Double(interleaved[frame * channelCount + channel])
        let expected = Double(reference[frame])
        dot += actual * expected
        actualEnergy += actual * actual
        referenceEnergy += expected * expected
    }
    guard actualEnergy > 0, referenceEnergy > 0 else { return 0 }
    return dot / sqrt(actualEnergy * referenceEnergy)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func expect(
    _ actual: Double,
    equals expected: Double,
    tolerance: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
}

private func expect(
    _ actual: Float,
    equals expected: Float,
    tolerance: Float,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Test("Recording writer continuously converts input rates to 48 kHz output before final drain")
func recordingWriterContinuouslyConvertsInputRatesTo48kOutputBeforeFinalDrain() throws {
    for sampleRate in [16_000.0, 44_100.0, 96_000.0] {
        let seconds = 0.2
        let frameCount = Int((sampleRate * seconds).rounded())
        let samples = stereoFixture(frameCount: frameCount, sampleRate: sampleRate)
        let ring = try SPSCRingBuffer(capacityFrames: frameCount, channelCount: 2)
        let accepted = samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) }
        #expect(accepted == frameCount)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memoryFactory = MemorySinkFactory()
        let wake = DispatchSemaphore(value: 0)
        let writer = try RecordingWriter(
            inputSampleRate: sampleRate,
            inputChannelCount: 2,
            layout: MixChannelLayout(microphoneChannels: [0], systemChannels: [1]),
            ring: ring,
            wake: wake,
            outputURL: directory.appendingPathComponent("src-\(Int(sampleRate)).m4a"),
            microphoneGain: 1,
            systemGain: 1,
            diskSpaceChecker: AlwaysEnoughDiskSpace(),
            sinkFactory: memoryFactory
        )

        try writer.start()
        wake.signal()
        writer.requestStop()
        let output = try writer.join()

        let expectedOutputFrames = UInt64((RecordingFileSettings.outputSampleRate * seconds).rounded())
        #expect(output.stats.outputFramesWritten >= expectedOutputFrames - 1_024)
        #expect(output.stats.outputFramesWritten <= expectedOutputFrames + 1_024)
        expect(output.duration, equals: seconds, tolerance: 1_024 / RecordingFileSettings.outputSampleRate)
        #expect(output.stats.inputFramesRead == UInt64(frameCount))
        #expect(ring.availableFrames == 0)
        #expect(output.sampleRate == 48_000)
        #expect(output.channelCount == 2)
        #expect(output.bars.reduce(0) { $0 + $1.frameCount } == frameCount)
        #expect(memoryFactory.statuses().contains(.endOfStream))
    }
}


@Test("Recording writer writes converted input rates as readable stereo 48 kHz AAC")
func recordingWriterWritesConvertedInputRatesAsReadableStereo48kAAC() throws {
    for sampleRate in [16_000.0, 44_100.0, 96_000.0] {
        let seconds = 0.2
        let frameCount = Int((sampleRate * seconds).rounded())
        let samples = stereoFixture(frameCount: frameCount, sampleRate: sampleRate)
        let ring = try SPSCRingBuffer(capacityFrames: frameCount, channelCount: 2)
        let accepted = samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) }
        #expect(accepted == frameCount)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("src-actual-\(Int(sampleRate)).m4a")
        let writer = try RecordingWriter(
            inputSampleRate: sampleRate,
            inputChannelCount: 2,
            layout: MixChannelLayout(microphoneChannels: [0], systemChannels: [1]),
            ring: ring,
            wake: DispatchSemaphore(value: 0),
            outputURL: url,
            microphoneGain: 1,
            systemGain: 1,
            diskSpaceChecker: AlwaysEnoughDiskSpace()
        )

        try writer.start()
        writer.requestStop()
        let output = try writer.join()
        let decoded = try readInterleavedFloat32(url)

        let expectedOutputFrames = UInt64((RecordingFileSettings.outputSampleRate * seconds).rounded())
        #expect(output.stats.outputFramesWritten >= expectedOutputFrames - 1_024)
        #expect(output.stats.outputFramesWritten <= expectedOutputFrames + 1_024)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.channelCount == 2)
        #expect(output.bars.reduce(0) { $0 + $1.frameCount } == frameCount)
        #expect(ring.availableFrames == 0)
    }
}

@Test("Recording writer low disk error closes readable partial AAC file after frames exist")
func recordingWriterLowDiskErrorClosesReadablePartialAACFileAfterFramesExist() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4_096, channelCount: 1)
    let samples = sineWave(frameCount: 4_096, sampleRate: 48_000, frequency: 330, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 4_096) }
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("low-disk-actual.m4a")
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: url,
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: SequenceDiskSpaceChecker([100_000_000, 10_000_000]),
        diskSpaceWatchdogIntervalFrames: 1,
        sinkFactory: AVAudioRecordingFileSinkFactory()
    )

    try writer.start()
    writer.requestStop()
    do {
        _ = try writer.join()
        Issue.record("join unexpectedly succeeded")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = attributes[.size] as? Int ?? 0
        #expect(byteCount > 0)
        _ = try AVAudioFile(forReading: url)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("Recording writer closes sink and surfaces file write errors")
func recordingWriterClosesSinkAndSurfacesFileWriteErrors() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 2_048, channelCount: 1)
    let samples = sineWave(frameCount: 2_048, sampleRate: 48_000, frequency: 220, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 2_048) }
    let failingFactory = FailingSinkFactory()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: temporaryDirectory().appendingPathComponent("failed.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: failingFactory
    )

    try writer.start()
    writer.requestStop()
    do {
        _ = try writer.join()
        Issue.record("join unexpectedly succeeded")
    } catch AudioCaptureError.fileWriteFailed {
        #expect(failingFactory.sinkClosed())
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("Recording writer closes resumed sink when the resumed run fails")
func recordingWriterClosesResumedSinkWhenResumedRunFails() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 2_048, channelCount: 1)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = FailingSecondOpenSinkFactory()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: directory.appendingPathComponent("000.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: factory
    )

    try writer.start()
    _ = try writer.pause()
    try writer.resume(outputURL: directory.appendingPathComponent("001.m4a"))
    let samples = sineWave(frameCount: 1_024, sampleRate: 48_000, frequency: 440, amplitude: 0.2)
    #expect(samples.withUnsafeBufferPointer { ring.write($0, frameCount: 1_024) } == 1_024)
    writer.wake.signal()
    writer.requestStop()

    #expect(throws: AudioCaptureError.fileWriteFailed("synthetic failure")) {
        _ = try writer.join()
    }
    #expect(factory.failingSinkClosed())
}

@Test("Recording writer disk watchdog closes gracefully and keeps a partial file after frames exist")
func recordingWriterDiskWatchdogClosesGracefullyAndKeepsPartialFileAfterFramesExist() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4_096, channelCount: 1)
    let samples = sineWave(frameCount: 4_096, sampleRate: 48_000, frequency: 330, amplitude: 0.2)
    _ = samples.withUnsafeBufferPointer { ring.write($0, frameCount: 4_096) }
    let factory = MemorySinkFactory()
    let writer = try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 1,
        layout: MixChannelLayout(microphoneChannels: [0], systemChannels: []),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: temporaryDirectory().appendingPathComponent("low-disk.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: SequenceDiskSpaceChecker([100_000_000, 10_000_000]),
        diskSpaceWatchdogIntervalFrames: 1,
        sinkFactory: factory
    )

    try writer.start()
    writer.requestStop()
    do {
        _ = try writer.join()
        Issue.record("join unexpectedly succeeded")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(factory.closeCount() == 1)
        #expect(factory.writtenFrameCount() > 0)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private final class MemorySinkFactory: RecordingFileSinkFactory, ConverterStatusObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var sink = MemorySink()
    private var converterStatuses: [AVAudioConverterOutputStatus] = []

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        sink
    }

    func recordConverterStatus(_ status: AVAudioConverterOutputStatus) {
        lock.lock()
        converterStatuses.append(status)
        lock.unlock()
    }

    func statuses() -> [AVAudioConverterOutputStatus] {
        lock.lock()
        defer { lock.unlock() }
        return converterStatuses
    }

    func writtenFrameCount() -> Int {
        sink.writtenFrameCount()
    }

    func closeCount() -> Int {
        sink.closeCount()
    }
}

private final class MemorySink: RecordingFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var closes = 0
    let processingFormat: AVAudioFormat

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            preconditionFailure("test could not create interleaved Float32 format")
        }
        processingFormat = format
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        frames += Int(buffer.frameLength)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
    }

    func writtenFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func closeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }
}

private final class RotatingMemorySinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [MemorySink] = []
    private var urls: [URL] = []

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        lock.lock()
        defer { lock.unlock() }
        let sink = MemorySink()
        sinks.append(sink)
        urls.append(url)
        return sink
    }

    func openedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func writtenFrameCounts() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sinks.map { $0.writtenFrameCount() }
    }

    func closeCounts() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sinks.map { $0.closeCount() }
    }
}

private final class CapturingRotatingMemorySinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [CapturingMemorySink] = []
    private let writeDelay: TimeInterval

    init(writeDelay: TimeInterval) {
        self.writeDelay = writeDelay
    }

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        lock.lock()
        defer { lock.unlock() }
        let sink = CapturingMemorySink(writeDelay: writeDelay)
        sinks.append(sink)
        return sink
    }

    func closeCounts() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sinks.map { $0.closeCount() }
    }

    func maxAbsoluteSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return sinks.map { $0.maxAbsoluteSample() }
    }
}

private final class CapturingMemorySink: RecordingFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0
    private var maxSample: Float = 0
    private let writeDelay: TimeInterval
    let processingFormat: AVAudioFormat

    init(writeDelay: TimeInterval) {
        self.writeDelay = writeDelay
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            preconditionFailure("test could not create interleaved Float32 format")
        }
        processingFormat = format
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        if writeDelay > 0 {
            Thread.sleep(forTimeInterval: writeDelay)
        }
        guard let data = buffer.floatChannelData?[0] else { return }
        let sampleCount = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        var localMax: Float = 0
        for sampleIndex in 0..<sampleCount {
            localMax = max(localMax, abs(data[sampleIndex]))
        }
        lock.lock()
        maxSample = max(maxSample, localMax)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
    }

    func closeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    func maxAbsoluteSample() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return maxSample
    }
}

private final class FailingSinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    private let sink = FailingSink()

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        sink
    }

    func sinkClosed() -> Bool { sink.isClosed() }
}

private final class FailingSecondOpenSinkFactory: RecordingFileSinkFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var openCount = 0
    private let firstSink = MemorySink()
    private let secondSink = FailingSink()

    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        lock.lock()
        defer { lock.unlock() }
        openCount += 1
        if openCount == 1 {
            return firstSink
        }
        return secondSink
    }

    func failingSinkClosed() -> Bool {
        secondSink.isClosed()
    }
}

private final class FailingSink: RecordingFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    let processingFormat: AVAudioFormat

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            preconditionFailure("test could not create interleaved Float32 format")
        }
        processingFormat = format
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        throw AudioCaptureError.fileWriteFailed("synthetic failure")
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

private final class SequenceDiskSpaceChecker: DiskSpaceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) {
        self.values = values
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first ?? 0
    }
}

private func stereoFixture(frameCount: Int, sampleRate: Double) -> [Float] {
    var samples = Array<Float>(repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        samples[frame * 2] = 0.2 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        samples[frame * 2 + 1] = 0.1 * Float(cos(2 * Double.pi * 220 * Double(frame) / sampleRate))
    }
    return samples
}

@Test("Recording writer flags silent finite system channel only in final output")
func recordingWriterFlagsSilentSystemChannelOnlyInFinalOutput() throws {
    let frameCount = 1_024
    let ring = try SPSCRingBuffer(capacityFrames: frameCount, channelCount: 2)
    let samples = Array<Float>(repeating: 0, count: frameCount * 2)
    #expect(samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) } == frameCount)
    let writer = try makeSystemLayoutWriter(ring: ring)

    try writer.start()
    writer.requestStop()
    let output = try writer.join()

    #expect(output.stats.systemPeak == 0)
    #expect(output.warnings == [.systemAudioWasSilent])
}

@Test("Recording writer omits silent warning when any finite system sample is nonzero")
func recordingWriterOmitsSilentWarningForNonzeroSystemChannel() throws {
    let frameCount = 1_024
    let ring = try SPSCRingBuffer(capacityFrames: frameCount, channelCount: 2)
    var samples = Array<Float>(repeating: 0, count: frameCount * 2)
    samples[17] = 0.25
    #expect(samples.withUnsafeBufferPointer { ring.write($0, frameCount: frameCount) } == frameCount)
    let writer = try makeSystemLayoutWriter(ring: ring)

    try writer.start()
    writer.requestStop()
    let output = try writer.join()

    #expect(output.stats.systemPeak == 0.25)
    #expect(!output.warnings.contains(.systemAudioWasSilent))
}

private func makeSystemLayoutWriter(ring: SPSCRingBuffer) throws -> RecordingWriter {
    try RecordingWriter(
        inputSampleRate: 48_000,
        inputChannelCount: 2,
        layout: MixChannelLayout(microphoneChannels: [], systemChannels: [0, 1]),
        ring: ring,
        wake: DispatchSemaphore(value: 0),
        outputURL: temporaryDirectory().appendingPathComponent("system-layout.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        diskSpaceChecker: AlwaysEnoughDiskSpace(),
        sinkFactory: MemorySinkFactory()
    )
}
