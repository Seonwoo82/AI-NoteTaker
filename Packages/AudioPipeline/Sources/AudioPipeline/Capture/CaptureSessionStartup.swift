import CoreAudio
import Dispatch
import Foundation

protocol CaptureStabilizationWaiting: Sendable {
    func wait() async throws
}

struct ContinuousClockCaptureStabilizationWaiter: CaptureStabilizationWaiting {
    func wait() async throws {
        try await ContinuousClock().sleep(for: .milliseconds(250))
    }
}

extension CaptureSession {
    enum CaptureStartupStabilizationError: Error {
        case mismatch
    }

    func startSharedResources(
        generation: UInt64,
        configuration: RecordingConfiguration,
        microphone: CaptureResolvedMicrophone?,
        usingDefaultMicrophone: Bool,
        aggregate createdAggregate: any CaptureAggregateDeviceManaging,
        tap: (any SystemAudioTapManaging)?,
        initialTapFormat: SystemAudioTapFormat?,
        partial: inout PartialResources
    ) async throws -> CaptureStartResult {
        partial.aggregate = createdAggregate
        partial.deviceID = createdAggregate.id
        partial.hasSystemAudio = !createdAggregate.channelMap.systemChannels.isEmpty
        partial.usingDefaultMicrophone = usingDefaultMicrophone
        updateStartingResources(generation: generation) { $0 = partial }

        let ring = try makeRing(
            sampleRate: createdAggregate.sampleRate,
            channelCount: createdAggregate.inputChannelCount
        )
        let wake = DispatchSemaphore(value: 0)
        let createdContext = try CaptureContext(
            ring: ring,
            wake: wake,
            expectedLayout: createdAggregate.channelMap.bufferLayout,
            inputChannelCount: createdAggregate.inputChannelCount,
            maxFramesPerCycle: maxFramesPerCycle(bufferFrameSize: createdAggregate.bufferFrameSize)
        )

        let writerLayout = MixChannelLayout(
            microphoneChannels: createdAggregate.channelMap.microphoneChannels,
            systemChannels: createdAggregate.channelMap.systemChannels
        )
        let createdWriter = try dependencies.writerFactory.makeWriter(
            inputSampleRate: createdAggregate.sampleRate,
            inputChannelCount: createdAggregate.inputChannelCount,
            layout: writerLayout,
            ring: ring,
            wake: wake,
            outputURL: configuration.outputURL,
            microphoneGain: configuration.microphoneGain,
            systemGain: configuration.systemGain,
            diskSpaceChecker: dependencies.diskSpaceChecker
        )
        partial.writer = createdWriter
        updateStartingResources(generation: generation) { $0 = partial }
        createdWriter.setCompletionHandler { [weak self, generation] result in
            Task {
                await self?.writerCompleted(result, generation: generation)
            }
        }

        let registeredMonitor = try dependencies.monitorFactory.register(
            aggregateID: createdAggregate.id,
            microphoneID: microphone?.id,
            eventHandler: { [weak self, generation] event in
                Task { [weak self] in
                    await self?.monitorEventReceived(event, generation: generation)
                }
            }
        )
        partial.monitor = registeredMonitor
        updateStartingResources(generation: generation) { $0 = partial }

        if !FileManager.default.fileExists(atPath: configuration.outputURL.path) {
            partial.attemptOwnedOutputURL = configuration.outputURL
            updateStartingResources(generation: generation) { $0 = partial }
        }

        try createdWriter.start()

        let createdIOQueue = DispatchQueue(
            label: "NoteTaker.CaptureSession.IOProc.\(UUID().uuidString)",
            qos: .userInteractive
        )
        let block = CaptureIOProc.makeBlock(context: createdContext)
        let createdIOProcID = try dependencies.ioProcManager.createIOProc(
            deviceID: createdAggregate.id,
            queue: createdIOQueue,
            block: block
        )
        partial.destroyIOProcID = createdIOProcID
        updateStartingResources(generation: generation) { $0 = partial }

        do {
            try dependencies.ioProcManager.startDevice(
                deviceID: createdAggregate.id,
                ioProcID: createdIOProcID
            )
        } catch AudioCaptureError.startFailed(let status)
            where partial.hasSystemAudio && status == kAudioDevicePermissionsError {
            throw AudioCaptureError.systemAudioPermissionDenied
        }
        partial.deviceStarted = true
        partial.stopIOProcID = createdIOProcID
        lifecycleState = .stabilizing(generation: generation, partial)

        if let tap, let initialTapFormat {
            try await dependencies.stabilizationWaiter.wait()
            partial = try currentStabilizingResources(generation: generation)
            guard !partial.stabilizationInvalidated else {
                throw CaptureStartupStabilizationError.mismatch
            }
            let stabilizedTapFormat = try tap.currentFormat()
            let stabilizedStreams = try createdAggregate.currentInputStreams()
            let stabilizedInputBufferChannelCounts = try createdAggregate.currentInputBufferChannelCounts()
            guard stabilizedTapFormat == initialTapFormat,
                  stabilizedStreams == createdAggregate.inputStreams,
                  stabilizedInputBufferChannelCounts == createdAggregate.inputBufferChannelCounts else {
                throw CaptureStartupStabilizationError.mismatch
            }
            partial = try currentStabilizingResources(generation: generation)
            guard !partial.stabilizationInvalidated else {
                throw CaptureStartupStabilizationError.mismatch
            }
        }

        partial.attemptOwnedOutputURL = nil
        partial.deleteAttemptOutputOnCleanup = false

        lifecycleState = .active(ActiveResources(
            generation: generation,
            microphone: microphone,
            aggregate: createdAggregate,
            tap: tap,
            monitor: registeredMonitor,
            writer: createdWriter,
            context: createdContext,
            ioQueue: createdIOQueue,
            ioProcID: createdIOProcID,
            warnings: partial.warnings,
            hasSystemAudio: partial.hasSystemAudio,
            usingDefaultMicrophone: partial.usingDefaultMicrophone,
            deviceStarted: partial.deviceStarted
        ))
        return CaptureStartResult(
            aggregateSampleRate: createdAggregate.sampleRate,
            channelMap: createdAggregate.channelMap,
            warnings: partial.warnings
        )
    }

    private func currentStabilizingResources(generation: UInt64) throws -> PartialResources {
        switch lifecycleState {
        case .stabilizing(let stateGeneration, let partial) where stateGeneration == generation:
            return partial
        case .cleanupNeeded(var partial) where partial.generation == generation:
            _ = try finishTeardown(&partial)
            throw AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
        case .finished(.failure(let error)):
            throw error
        case .finished(.success):
            throw AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
        default:
            throw AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
        }
    }

    func preflightDiskSpace(for outputURL: URL) throws {
        let parent = outputURL.deletingLastPathComponent()
        let capacity = try dependencies.diskSpaceChecker.availableCapacity(at: parent)
        guard capacity >= Self.minimumStartCapacityBytes else {
            throw AudioCaptureError.diskSpaceLow
        }
    }

    nonisolated func maxFramesPerCycle(bufferFrameSize: Int) -> Int {
        let safeBufferSize = max(1, bufferFrameSize)
        let (value, overflow) = safeBufferSize.multipliedReportingOverflow(by: 4)
        return overflow ? safeBufferSize : max(safeBufferSize, value)
    }

    nonisolated func makeRing(sampleRate: Double, channelCount: Int) throws -> SPSCRingBuffer {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioCaptureError.unsupportedStreamFormat(nil)
        }
        let seconds = 4.0
        let frameCapacity = max(1, Int((sampleRate * seconds).rounded(.up)))
        return try SPSCRingBuffer(capacityFrames: frameCapacity, channelCount: channelCount)
    }
}
