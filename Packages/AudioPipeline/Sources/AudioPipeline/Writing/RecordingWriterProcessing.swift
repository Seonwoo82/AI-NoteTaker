@preconcurrency import AVFAudio
import Dispatch
import Foundation

extension RecordingWriter {
    func processAudio(
        outputFormat: AVAudioFormat,
        initialSink: any RecordingFileSink
    ) throws -> FinishedRecordingOutput {
        var initialSinkNeedsClose = true
        defer {
            if initialSinkNeedsClose {
                initialSink.close()
            }
        }
        var inputSamples = Array<Float>(repeating: 0, count: Self.chunkFrames * inputChannelCount)
        var mixedSamples = Array<Float>(repeating: 0, count: Self.chunkFrames * 2)
        let mixedInputFormat = try AudioConverterDriver.makeInterleavedFloat32Format(
            sampleRate: inputSampleRate,
            channelCount: RecordingFileSettings.outputChannelCount
        )
        var barAccumulator = try BarAccumulator(sampleRate: inputSampleRate)
        var bars: [AudioBar] = []
        var inputFramesRead: UInt64 = 0
        var outputFramesWritten: UInt64 = 0
        var fileWriteCalls: UInt64 = 0
        var microphonePeak: Float = 0
        var systemPeak: Float = 0
        var activeSegment = try SegmentPipeline(
            url: outputURL,
            sink: initialSink,
            inputSampleRate: inputSampleRate,
            mixedInputFormat: mixedInputFormat,
            outputFormat: outputFormat,
            diskSpaceChecker: diskSpaceChecker,
            diskSpaceWatchdogIntervalFrames: diskSpaceWatchdogIntervalFrames,
            observer: sinkFactory as? ConverterStatusObserving
        )
        initialSinkNeedsClose = false
        var writerMode = WriterMode.recording
        var lastSegmentURL = outputURL

        do {
            writerLoop: while true {
                if case let .pauseDraining(boundary, command) = writerMode {
                    let read = inputSamples.withUnsafeMutableBufferPointer { destination in
                        ring.read(into: destination, maxFrames: Self.chunkFrames, upToWriteSequence: boundary)
                    }

                    if read > 0 {
                        inputFramesRead += UInt64(read)
                        try inputSamples.withUnsafeBufferPointer { inputBuffer in
                            let inputChunk = UnsafeBufferPointer(rebasing: inputBuffer[..<(read * inputChannelCount)])
                            let peaks = SourceLevelMeter.peaks(
                                input: inputChunk,
                                frameCount: read,
                                inputChannelCount: inputChannelCount,
                                layout: layout,
                                microphoneGain: microphoneGain,
                                systemGain: systemGain
                            )
                            microphonePeak = max(microphonePeak, peaks.microphone)
                            systemPeak = max(systemPeak, peaks.system)
                            try mixAndWrite(
                                inputChunk: inputChunk,
                                readFrames: read,
                                mixedSamples: &mixedSamples,
                                barAccumulator: &barAccumulator,
                                segment: &activeSegment,
                                bars: &bars,
                                outputFramesWritten: &outputFramesWritten,
                                fileWriteCalls: &fileWriteCalls
                            )
                            updateProgress(frames: outputFramesWritten, microphone: peaks.microphone, system: peaks.system)
                        }
                        continue
                    }

                    do {
                        let segmentOutputBeforeDrain = activeSegment.outputFramesWritten
                        let segmentWritesBeforeDrain = activeSegment.fileWriteCalls
                        let segment = try activeSegment.close()
                        outputFramesWritten += activeSegment.outputFramesWritten - segmentOutputBeforeDrain
                        fileWriteCalls += activeSegment.fileWriteCalls - segmentWritesBeforeDrain
                        lastSegmentURL = activeSegment.url
                        writerMode = .paused
                        updateProgress(frames: outputFramesWritten, microphone: 0, system: 0)
                        command.complete(.success(segment))
                    } catch {
                        command.complete(.failure(error))
                        throw error
                    }
                    continue
                }

                switch nextWriterWork() {
                case .command(let action):
                    switch action {
                    case .pause(let command, let boundary):
                        if case .paused = writerMode {
                            command.complete(.failure(AudioCaptureError.fileWriteFailed("Recording writer is already paused")))
                        } else {
                            writerMode = .pauseDraining(boundary: boundary, command: command)
                        }
                    case .resume(let command, let boundary):
                        if case .recording = writerMode {
                            command.complete(.failure(AudioCaptureError.fileWriteFailed("Recording writer is not paused")))
                        } else if let url = command.outputURL {
                            do {
                                discardPausedFrames(
                                    upToWriteSequence: boundary,
                                    inputSamples: &inputSamples,
                                    inputFramesRead: &inputFramesRead
                                )
                                let sink = try sinkFactory.open(
                                    url: url,
                                    settings: RecordingFileSettings.aacM4A,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: true
                                )
                                do {
                                    activeSegment = try SegmentPipeline(
                                        url: url,
                                        sink: sink,
                                        inputSampleRate: inputSampleRate,
                                        mixedInputFormat: mixedInputFormat,
                                        outputFormat: outputFormat,
                                        diskSpaceChecker: diskSpaceChecker,
                                        diskSpaceWatchdogIntervalFrames: diskSpaceWatchdogIntervalFrames,
                                        observer: sinkFactory as? ConverterStatusObserving
                                    )
                                } catch {
                                    sink.close()
                                    throw error
                                }
                                lastSegmentURL = url
                                writerMode = .recording
                                command.complete(.success(()))
                            } catch {
                                command.complete(.failure(error))
                                throw error
                            }
                        } else {
                            command.complete(.failure(AudioCaptureError.fileWriteFailed("Recording writer resume output unavailable")))
                        }
                    }
                    continue
                case .read(let shouldStop, let boundary):
                    hooks.beforeNormalRead?()
                    let read = inputSamples.withUnsafeMutableBufferPointer { destination in
                        ring.read(into: destination, maxFrames: Self.chunkFrames, upToWriteSequence: boundary)
                    }

                    if read > 0 {
                        inputFramesRead += UInt64(read)
                        if case .paused = writerMode {
                            continue
                        }
                        try inputSamples.withUnsafeBufferPointer { inputBuffer in
                            let inputChunk = UnsafeBufferPointer(rebasing: inputBuffer[..<(read * inputChannelCount)])
                            let peaks = SourceLevelMeter.peaks(
                                input: inputChunk,
                                frameCount: read,
                                inputChannelCount: inputChannelCount,
                                layout: layout,
                                microphoneGain: microphoneGain,
                                systemGain: systemGain
                            )
                            microphonePeak = max(microphonePeak, peaks.microphone)
                            systemPeak = max(systemPeak, peaks.system)
                            try mixAndWrite(
                                inputChunk: inputChunk,
                                readFrames: read,
                                mixedSamples: &mixedSamples,
                                barAccumulator: &barAccumulator,
                                segment: &activeSegment,
                                bars: &bars,
                                outputFramesWritten: &outputFramesWritten,
                                fileWriteCalls: &fileWriteCalls
                            )
                            updateProgress(frames: outputFramesWritten, microphone: peaks.microphone, system: peaks.system)
                        }
                        continue
                    }

                    if shouldStop {
                        break writerLoop
                    }
                    _ = wake.wait(timeout: .now() + .milliseconds(100))
                }
            }

            if case .recording = writerMode {
                let segmentOutputBeforeDrain = activeSegment.outputFramesWritten
                let segmentWritesBeforeDrain = activeSegment.fileWriteCalls
                _ = try activeSegment.close()
                outputFramesWritten += activeSegment.outputFramesWritten - segmentOutputBeforeDrain
                fileWriteCalls += activeSegment.fileWriteCalls - segmentWritesBeforeDrain
            }

            return finishOutput(
                url: lastSegmentURL,
                bars: &bars,
                barAccumulator: &barAccumulator,
                inputFramesRead: inputFramesRead,
                outputFramesWritten: outputFramesWritten,
                fileWriteCalls: fileWriteCalls,
                microphonePeak: microphonePeak,
                systemPeak: systemPeak
            )
        } catch {
            activeSegment.closeAfterFailure()
            throw error
        }
    }

    private func mixAndWrite(
        inputChunk: UnsafeBufferPointer<Float>,
        readFrames: Int,
        mixedSamples: inout [Float],
        barAccumulator: inout BarAccumulator,
        segment: inout SegmentPipeline,
        bars: inout [AudioBar],
        outputFramesWritten: inout UInt64,
        fileWriteCalls: inout UInt64
    ) throws {
        try mixedSamples.withUnsafeMutableBufferPointer { mixedBuffer in
            let mixedChunk = UnsafeMutableBufferPointer(rebasing: mixedBuffer[..<(readFrames * 2)])
            MixKernel.mix(
                input: inputChunk,
                frameCount: readFrames,
                inputChannelCount: inputChannelCount,
                layout: layout,
                microphoneGain: microphoneGain,
                systemGain: systemGain,
                output: mixedChunk
            )
            let immutableMixed = UnsafeBufferPointer(mixedChunk)
            barAccumulator.ingest(immutableMixed, frameCount: readFrames, channelCount: 2)
            bars.append(contentsOf: barAccumulator.drainCompleted())
            try writeMixedChunk(
                immutableMixed,
                frameCount: readFrames,
                segment: &segment,
                outputFramesWritten: &outputFramesWritten,
                fileWriteCalls: &fileWriteCalls
            )
        }
    }

    private func writeMixedChunk(
        _ mixed: UnsafeBufferPointer<Float>,
        frameCount: Int,
        segment: inout SegmentPipeline,
        outputFramesWritten: inout UInt64,
        fileWriteCalls: inout UInt64
    ) throws {
        if let converter = segment.converter {
            try AudioConverterDriver.copyInterleavedSamples(
                mixed,
                frameCount: frameCount,
                channelCount: 2,
                into: segment.inputBuffer
            )
            try converter.convertLive(inputBuffer: segment.inputBuffer, outputBuffer: segment.outputBuffer) { convertedBuffer in
                try writeBuffer(
                    convertedBuffer,
                    segment: &segment,
                    outputFramesWritten: &outputFramesWritten,
                    fileWriteCalls: &fileWriteCalls
                )
            }
        } else {
            try AudioConverterDriver.copyInterleavedSamples(
                mixed,
                frameCount: frameCount,
                channelCount: 2,
                into: segment.outputBuffer
            )
            try writeBuffer(
                segment.outputBuffer,
                segment: &segment,
                outputFramesWritten: &outputFramesWritten,
                fileWriteCalls: &fileWriteCalls
            )
        }
    }

    private func writeBuffer(
        _ buffer: AVAudioPCMBuffer,
        segment: inout SegmentPipeline,
        outputFramesWritten: inout UInt64,
        fileWriteCalls: inout UInt64
    ) throws {
        try segment.sink.write(buffer)
        outputFramesWritten += UInt64(buffer.frameLength)
        segment.outputFramesWritten += UInt64(buffer.frameLength)
        fileWriteCalls += 1
        segment.fileWriteCalls += 1
        try segment.diskMonitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: segment.outputFramesWritten)
    }

    private func discardPausedFrames(
        upToWriteSequence boundary: Int,
        inputSamples: inout [Float],
        inputFramesRead: inout UInt64
    ) {
        while true {
            let read = inputSamples.withUnsafeMutableBufferPointer { destination in
                ring.read(into: destination, maxFrames: Self.chunkFrames, upToWriteSequence: boundary)
            }
            guard read > 0 else { return }
            inputFramesRead += UInt64(read)
        }
    }

    private func finishOutput(
        url: URL,
        bars: inout [AudioBar],
        barAccumulator: inout BarAccumulator,
        inputFramesRead: UInt64,
        outputFramesWritten: UInt64,
        fileWriteCalls: UInt64,
        microphonePeak: Float,
        systemPeak: Float
    ) -> FinishedRecordingOutput {
        bars.append(contentsOf: barAccumulator.finish())
        let dropped = ring.droppedFrames
        var warnings: [AudioCaptureWarning] = []
        if dropped > 0 {
            warnings.append(.framesDropped(dropped))
        }
        if !layout.systemChannels.isEmpty, systemPeak == 0 {
            warnings.append(.systemAudioWasSilent)
        }
        let stats = RecordingWriterStats(
            inputFramesRead: inputFramesRead,
            outputFramesWritten: outputFramesWritten,
            fileWriteCalls: fileWriteCalls,
            barsEmitted: UInt64(bars.count),
            ringDroppedFrames: dropped,
            ringOverflowCount: ring.overflowCount,
            microphonePeak: microphonePeak,
            systemPeak: systemPeak
        )
        return FinishedRecordingOutput(
            url: url,
            duration: stats.duration,
            sampleRate: RecordingFileSettings.outputSampleRate,
            channelCount: Int(RecordingFileSettings.outputChannelCount),
            bars: bars,
            stats: stats,
            warnings: warnings
        )
    }

    private enum WriterMode {
        case recording
        case pauseDraining(boundary: Int, command: PendingWriterCommand<RecordingSegmentOutput>)
        case paused
    }

    private enum WriterWork {
        case command(RecordingWriterCommand)
        case read(shouldStop: Bool, boundary: Int)
    }

    private func nextWriterWork() -> WriterWork {
        control.withLock { state in
            if let command = state.commandQueue.dequeue() {
                return .command(command)
            }
            return .read(shouldStop: state.shouldStop, boundary: ring.writeSequenceSnapshot)
        }
    }

    private struct SegmentPipeline {
        let url: URL
        let sink: any RecordingFileSink
        let converter: AudioConverterDriver?
        let inputBuffer: AVAudioPCMBuffer
        let outputBuffer: AVAudioPCMBuffer
        var diskMonitor: DiskSpaceMonitor
        var outputFramesWritten: UInt64 = 0
        var fileWriteCalls: UInt64 = 0
        var isClosed = false

        init(
            url: URL,
            sink: any RecordingFileSink,
            inputSampleRate: Double,
            mixedInputFormat: AVAudioFormat,
            outputFormat: AVAudioFormat,
            diskSpaceChecker: any DiskSpaceChecking,
            diskSpaceWatchdogIntervalFrames: UInt64,
            observer: ConverterStatusObserving?
        ) throws {
            self.url = url
            self.sink = sink
            self.converter = inputSampleRate == RecordingFileSettings.outputSampleRate
                ? nil
                : try AudioConverterDriver(
                    inputFormat: mixedInputFormat,
                    outputFormat: outputFormat,
                    observer: observer
                )
            self.inputBuffer = try AudioConverterDriver.makeBuffer(
                format: mixedInputFormat,
                frameCapacity: AVAudioFrameCount(RecordingWriter.chunkFrames)
            )
            self.outputBuffer = try AudioConverterDriver.makeBuffer(
                format: outputFormat,
                frameCapacity: AudioConverterDriver.outputCapacity(
                    inputFrames: RecordingWriter.chunkFrames,
                    inputSampleRate: inputSampleRate
                )
            )
            self.diskMonitor = DiskSpaceMonitor(
                checker: diskSpaceChecker,
                outputURL: url,
                watchdogIntervalFrames: diskSpaceWatchdogIntervalFrames
            )
        }

        mutating func close() throws -> RecordingSegmentOutput {
            guard !isClosed else {
                return RecordingSegmentOutput(
                    url: url,
                    duration: TimeInterval(Double(outputFramesWritten) / RecordingFileSettings.outputSampleRate),
                    outputFramesWritten: outputFramesWritten
                )
            }
            if let converter {
                try converter.drainFinal(outputBuffer: outputBuffer) { convertedBuffer in
                    try sink.write(convertedBuffer)
                    outputFramesWritten += UInt64(convertedBuffer.frameLength)
                    fileWriteCalls += 1
                    try diskMonitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: outputFramesWritten)
                }
            }
            sink.close()
            isClosed = true
            return RecordingSegmentOutput(
                url: url,
                duration: TimeInterval(Double(outputFramesWritten) / RecordingFileSettings.outputSampleRate),
                outputFramesWritten: outputFramesWritten
            )
        }

        mutating func closeAfterFailure() {
            guard !isClosed else { return }
            sink.close()
            isClosed = true
        }
    }
}
