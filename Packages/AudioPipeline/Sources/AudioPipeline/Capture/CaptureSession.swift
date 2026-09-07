import CoreAudio
import Dispatch
import Foundation

public struct CaptureTerminalEvent: Equatable, Sendable {
    public let generation: UInt64
    public let error: AudioCaptureError

    public init(generation: UInt64, error: AudioCaptureError) {
        self.generation = generation
        self.error = error
    }
}

public actor CaptureSession {
    struct Dependencies: Sendable {
        let permissionRequester: any MicrophonePermissionRequesting
        let deviceResolver: any CaptureDeviceResolving
        let diskSpaceChecker: any DiskSpaceChecking
        let aggregateFactory: any CaptureAggregateDeviceMaking
        let monitorFactory: any CaptureDeviceMonitoring
        let writerFactory: any CaptureSessionRecordingWriterMaking
        let ioProcManager: any CaptureDeviceIOProcManaging
        let processObjects: any AudioProcessObjectResolving
        let systemTapFactory: any SystemAudioTapMaking
        let stabilizationWaiter: any CaptureStabilizationWaiting
        let attemptFileManager: any CaptureAttemptFileManaging
        let runtimeEventAcknowledgement: (@Sendable (CaptureDeviceEvent) -> Void)?

        init(
            permissionRequester: any MicrophonePermissionRequesting,
            deviceResolver: any CaptureDeviceResolving,
            diskSpaceChecker: any DiskSpaceChecking,
            aggregateFactory: any CaptureAggregateDeviceMaking,
            monitorFactory: any CaptureDeviceMonitoring,
            writerFactory: any CaptureSessionRecordingWriterMaking,
            ioProcManager: any CaptureDeviceIOProcManaging,
            processObjects: any AudioProcessObjectResolving,
            systemTapFactory: any SystemAudioTapMaking,
            stabilizationWaiter: any CaptureStabilizationWaiting,
            attemptFileManager: any CaptureAttemptFileManaging = FileManagerCaptureAttemptFileManager(),
            runtimeEventAcknowledgement: (@Sendable (CaptureDeviceEvent) -> Void)? = nil
        ) {
            self.permissionRequester = permissionRequester
            self.deviceResolver = deviceResolver
            self.diskSpaceChecker = diskSpaceChecker
            self.aggregateFactory = aggregateFactory
            self.monitorFactory = monitorFactory
            self.writerFactory = writerFactory
            self.ioProcManager = ioProcManager
            self.processObjects = processObjects
            self.systemTapFactory = systemTapFactory
            self.stabilizationWaiter = stabilizationWaiter
            self.attemptFileManager = attemptFileManager
            self.runtimeEventAcknowledgement = runtimeEventAcknowledgement
        }
    }

    struct ActiveResources: Sendable {
        let generation: UInt64
        let microphone: CaptureResolvedMicrophone?
        let aggregate: any CaptureAggregateDeviceManaging
        let tap: (any SystemAudioTapManaging)?
        let monitor: any CaptureDeviceMonitorRegistration
        let writer: any CaptureSessionRecordingWriter
        let context: CaptureContext
        let ioQueue: DispatchQueue
        let ioProcID: AudioDeviceIOProcID
        let warnings: [AudioCaptureWarning]
        let hasSystemAudio: Bool
        let usingDefaultMicrophone: Bool
        var deviceStarted: Bool
    }

    enum LifecycleState: Sendable {
        case idle
        case starting(generation: UInt64, PartialResources)
        case stabilizing(generation: UInt64, PartialResources)
        case active(ActiveResources)
        case paused(ActiveResources)
        case cleanupNeeded(PartialResources)
        case finished(Result<FinishedRecordingOutput, Error>)
    }

    let dependencies: Dependencies
    public nonisolated let terminalEventStream: AsyncStream<CaptureTerminalEvent>
    private let terminalEventsContinuation: AsyncStream<CaptureTerminalEvent>.Continuation
    var lifecycleState: LifecycleState = .idle
    private var nextGeneration: UInt64 = 0
    private var terminalEventGenerations: Set<UInt64> = []

    public init() {
        self.init(dependencies: Dependencies(
            permissionRequester: AVAudioApplicationMicrophonePermissionRequester(),
            deviceResolver: CoreAudioCaptureDeviceResolver(),
            diskSpaceChecker: VolumeDiskSpaceChecker(),
            aggregateFactory: CoreAudioCaptureAggregateDeviceFactory(),
            monitorFactory: CaptureDeviceMonitor(),
            writerFactory: DefaultCaptureSessionRecordingWriterFactory(),
            ioProcManager: CoreAudioDeviceIOProcManager(),
            processObjects: AudioProcessObjects(),
            systemTapFactory: SystemAudioTapFactory(),
            stabilizationWaiter: ContinuousClockCaptureStabilizationWaiter(),
            attemptFileManager: FileManagerCaptureAttemptFileManager()
        ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        var capturedContinuation: AsyncStream<CaptureTerminalEvent>.Continuation!
        terminalEventStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        terminalEventsContinuation = capturedContinuation
    }

    public func start(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        switch lifecycleState {
        case .idle, .finished:
            break
        case .starting, .stabilizing, .active, .paused, .cleanupNeeded:
            throw AudioCaptureError.fileWriteFailed("Capture session already started")
        }

        switch configuration.mode {
        case .micOnly:
            return try await startMicOnly(configuration: configuration)
        case .systemOnly:
            return try await startSystemOnlyWithStabilization(configuration: configuration)
        case .micAndSystem:
            return try await startMicAndSystemWithStabilization(configuration: configuration)
        }
    }

    private func startMicOnly(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        let generation = reserveGeneration()
        lifecycleState = .starting(
            generation: generation,
            PartialResources(generation: generation)
        )

        var partial = PartialResources(generation: generation)
        updateStartingResources(generation: generation) { $0 = partial }

        do {
            let permissionGranted = await dependencies.permissionRequester.requestRecordPermission()
            guard startupStateOwnsGeneration(generation) else {
                throw retainedStartupTerminalError(
                    for: generation,
                    fallback: AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
                )
            }
            guard permissionGranted else {
                lifecycleState = .idle
                throw AudioCaptureError.microphonePermissionDenied
            }

            let microphone = try dependencies.deviceResolver.resolveMicrophone(uid: configuration.microphoneUID)
            partial.microphone = microphone
            partial.usingDefaultMicrophone = configuration.microphoneUID == nil
            updateStartingResources(generation: generation) { $0 = partial }
            try preflightDiskSpace(for: configuration.outputURL)

            let createdAggregate = try dependencies.aggregateFactory.createMicOnlyAggregate(
                microphoneUID: microphone.uid,
                microphoneStreams: microphone.inputStreams
            )
            return try await startSharedResources(
                generation: generation,
                configuration: configuration,
                microphone: microphone,
                usingDefaultMicrophone: configuration.microphoneUID == nil,
                aggregate: createdAggregate,
                tap: nil,
                initialTapFormat: nil,
                partial: &partial
            )
        } catch {
            let surfacedError = adoptPendingAggregateOwner(from: error, partial: &partial)
            guard startupStateOwnsGeneration(generation) else {
                throw retainedStartupTerminalError(for: generation, fallback: surfacedError)
            }
            retainStartupCleanupFailure(originalError: surfacedError, partial: &partial)
            throw surfacedError
        }
    }

    private func startSystemOnlyWithStabilization(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        var attempt = 1
        var generation = reserveGeneration()

        while true {
            lifecycleState = .starting(
                generation: generation,
                PartialResources(generation: generation)
            )

            var partial = PartialResources(generation: generation)
            updateStartingResources(generation: generation) { $0 = partial }

            do {
                let output = try dependencies.deviceResolver.resolveDefaultOutput()
                let processObjectID = try dependencies.processObjects.currentProcessObjectID()
                try preflightDiskSpace(for: configuration.outputURL)

                let tap = try dependencies.systemTapFactory.create(excludingProcessID: processObjectID)
                partial.tap = tap
                partial.warnings = appendUnique(partial.warnings, tap.warnings)
                updateStartingResources(generation: generation) { $0 = partial }

                let tapFormat = try tap.currentFormat()
                let createdAggregate = try dependencies.aggregateFactory.createSystemOnlyAggregate(
                    outputUID: output.uid,
                    tapUID: tap.uid,
                    tapChannelCount: Int(tapFormat.channelCount)
                )
                return try await startSharedResources(
                    generation: generation,
                    configuration: configuration,
                    microphone: nil,
                    usingDefaultMicrophone: false,
                    aggregate: createdAggregate,
                    tap: tap,
                    initialTapFormat: tapFormat,
                    partial: &partial
                )
            } catch CaptureStartupStabilizationError.mismatch {
                let terminalError = AudioCaptureError.unsupportedStreamFormat(nil)
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: terminalError)
                }
                retainStartupCleanupFailure(
                    originalError: terminalError,
                    partial: &partial,
                    deleteAttemptOutput: true
                )
                guard !partial.hasPendingResources else {
                    throw terminalError
                }
                guard attempt < 2 else {
                    throw terminalError
                }
                attempt += 1
                generation = reserveGeneration()
            } catch is CancellationError {
                let terminalError = CancellationError()
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: terminalError)
                }
                retainStartupCleanupFailure(
                    originalError: terminalError,
                    partial: &partial,
                    deleteAttemptOutput: true
                )
                throw terminalError
            } catch {
                let surfacedError = adoptPendingAggregateOwner(from: error, partial: &partial)
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: surfacedError)
                }
                retainStartupCleanupFailure(originalError: surfacedError, partial: &partial)
                throw surfacedError
            }
        }
    }

    private func startMicAndSystemWithStabilization(configuration: RecordingConfiguration) async throws -> CaptureStartResult {
        var attempt = 1
        var generation = reserveGeneration()

        while true {
            lifecycleState = .starting(
                generation: generation,
                PartialResources(generation: generation)
            )

            var partial = PartialResources(generation: generation)
            updateStartingResources(generation: generation) { $0 = partial }

            do {
                let permissionGranted = await dependencies.permissionRequester.requestRecordPermission()
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(
                        for: generation,
                        fallback: AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
                    )
                }
                guard permissionGranted else {
                    lifecycleState = .idle
                    throw AudioCaptureError.microphonePermissionDenied
                }

                let microphone = try dependencies.deviceResolver.resolveMicrophone(uid: configuration.microphoneUID)
                partial.microphone = microphone
                partial.usingDefaultMicrophone = configuration.microphoneUID == nil
                updateStartingResources(generation: generation) { $0 = partial }

                let output = try dependencies.deviceResolver.resolveDefaultOutput()
                let processObjectID = try dependencies.processObjects.currentProcessObjectID()
                try preflightDiskSpace(for: configuration.outputURL)

                let tap = try dependencies.systemTapFactory.create(excludingProcessID: processObjectID)
                partial.tap = tap
                partial.warnings = appendUnique(partial.warnings, tap.warnings)
                updateStartingResources(generation: generation) { $0 = partial }

                let tapFormat = try tap.currentFormat()
                let createdAggregate = try dependencies.aggregateFactory.createMicAndSystemAggregate(
                    microphoneUID: microphone.uid,
                    microphoneStreams: microphone.inputStreams,
                    outputUID: output.uid,
                    tapUID: tap.uid,
                    tapChannelCount: Int(tapFormat.channelCount),
                    clockSource: configuration.clockSource
                )
                return try await startSharedResources(
                    generation: generation,
                    configuration: configuration,
                    microphone: microphone,
                    usingDefaultMicrophone: configuration.microphoneUID == nil,
                    aggregate: createdAggregate,
                    tap: tap,
                    initialTapFormat: tapFormat,
                    partial: &partial
                )
            } catch CaptureStartupStabilizationError.mismatch {
                let terminalError = AudioCaptureError.unsupportedStreamFormat(nil)
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: terminalError)
                }
                retainStartupCleanupFailure(
                    originalError: terminalError,
                    partial: &partial,
                    deleteAttemptOutput: true
                )
                guard !partial.hasPendingResources else {
                    throw terminalError
                }
                guard attempt < 2 else {
                    throw terminalError
                }
                attempt += 1
                generation = reserveGeneration()
            } catch is CancellationError {
                let terminalError = CancellationError()
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: terminalError)
                }
                retainStartupCleanupFailure(
                    originalError: terminalError,
                    partial: &partial,
                    deleteAttemptOutput: true
                )
                throw terminalError
            } catch {
                let surfacedError = adoptPendingAggregateOwner(from: error, partial: &partial)
                guard startupStateOwnsGeneration(generation) else {
                    throw retainedStartupTerminalError(for: generation, fallback: surfacedError)
                }
                retainStartupCleanupFailure(originalError: surfacedError, partial: &partial)
                throw surfacedError
            }
        }
    }

    public func stop() async throws -> FinishedRecordingOutput {
        switch lifecycleState {
        case .finished(.success(let output)):
            return output
        case .finished(.failure(let error)):
            throw error
        case .idle:
            throw AudioCaptureError.fileWriteFailed("Capture session not started")
        case .starting(_, let partial), .stabilizing(_, let partial):
            var cleanup = partial
            cleanup.errorContext = cleanup.errorContext ?? AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
            lifecycleState = .cleanupNeeded(cleanup)
            return try finishTeardown(&cleanup)
        case .active(let resources), .paused(let resources):
            var partial = PartialResources(resources)
            lifecycleState = .cleanupNeeded(partial)
            return try finishTeardown(&partial)
        case .cleanupNeeded(let partial):
            var retry = partial
            return try finishTeardown(&retry)
        }
    }

    public func hasPendingCleanup() -> Bool {
        switch lifecycleState {
        case .starting, .stabilizing, .active, .paused, .cleanupNeeded:
            return true
        case .idle, .finished:
            return false
        }
    }

    public func progress() -> CaptureProgress? {
        switch lifecycleState {
        case .active(let resources), .paused(let resources):
            return resources.writer.currentProgress
        default:
            return nil
        }
    }

    public func pause() async throws -> RecordingSegmentOutput {
        switch lifecycleState {
        case .active(let resources):
            let segment = try resources.writer.pause()
            lifecycleState = .paused(resources)
            return segment
        case .paused:
            throw AudioCaptureError.fileWriteFailed("Capture session already paused")
        case .idle, .starting, .stabilizing, .cleanupNeeded, .finished:
            throw AudioCaptureError.fileWriteFailed("Capture session is not actively recording")
        }
    }

    public func resume(outputURL: URL) async throws {
        switch lifecycleState {
        case .paused(let resources):
            try resources.writer.resume(outputURL: outputURL)
            lifecycleState = .active(resources)
        case .active:
            throw AudioCaptureError.fileWriteFailed("Capture session is already recording")
        case .idle, .starting, .stabilizing, .cleanupNeeded, .finished:
            throw AudioCaptureError.fileWriteFailed("Capture session is not paused")
        }
    }

    private func reserveGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    func updateStartingResources(
        generation: UInt64,
        _ update: (inout PartialResources) -> Void
    ) {
        switch lifecycleState {
        case .starting(let stateGeneration, var partial) where stateGeneration == generation:
            update(&partial)
            lifecycleState = .starting(generation: generation, partial)
        case .stabilizing(let stateGeneration, var partial) where stateGeneration == generation:
            update(&partial)
            lifecycleState = .stabilizing(generation: generation, partial)
        default:
            return
        }
    }

    private func retainStartupCleanupFailure(
        originalError: Error,
        partial: inout PartialResources,
        deleteAttemptOutput: Bool? = nil
    ) {
        partial.errorContext = originalError
        if let deleteAttemptOutput {
            partial.deleteAttemptOutputOnCleanup = deleteAttemptOutput && partial.attemptOwnedOutputURL != nil
        } else if let audioError = originalError as? AudioCaptureError,
                  !audioError.keepsPartialFile,
                  partial.attemptOwnedOutputURL != nil {
            partial.deleteAttemptOutputOnCleanup = true
        }
        do {
            _ = try teardownPartial(&partial)
        } catch {
        }

        if partial.hasPendingResources {
            lifecycleState = .cleanupNeeded(partial)
        } else {
            lifecycleState = .finished(.failure(originalError))
        }
    }

    private func adoptPendingAggregateOwner(
        from error: Error,
        partial: inout PartialResources
    ) -> Error {
        guard let cleanupError = error as? CaptureAggregateCreationCleanupError else {
            return error
        }
        partial.pendingAggregateOwner = cleanupError.pendingOwner
        let retainedPartial = partial
        updateStartingResources(generation: partial.generation) { $0 = retainedPartial }
        return cleanupError.originalError
    }

    private func startupStateOwnsGeneration(_ generation: UInt64) -> Bool {
        switch lifecycleState {
        case .starting(let stateGeneration, _), .stabilizing(let stateGeneration, _):
            return stateGeneration == generation
        default:
            return false
        }
    }

    private func retainedStartupTerminalError(for generation: UInt64, fallback: Error) -> Error {
        switch lifecycleState {
        case .cleanupNeeded(let partial) where partial.generation == generation:
            return terminalError(from: partial) ?? fallback
        case .finished(.failure(let error)):
            return error
        case .finished(.success):
            return AudioCaptureError.fileWriteFailed("Capture session stopped during startup")
        default:
            return fallback
        }
    }

    private nonisolated func terminalError(from partial: PartialResources) -> Error? {
        if let errorContext = partial.errorContext {
            return errorContext
        }
        if case .failure(let writerError) = partial.writerResult {
            return writerError
        }
        return nil
    }

    func monitorEventReceived(_ event: CaptureDeviceEvent, generation: UInt64) async {
        switch lifecycleState {
        case .active(let resources) where resources.generation == generation,
             .paused(let resources) where resources.generation == generation:
            dependencies.runtimeEventAcknowledgement?(event)
            guard let error = runtimeError(
                for: event,
                hasMicrophone: resources.microphone != nil,
                hasSystemAudio: resources.hasSystemAudio,
                usingDefaultMicrophone: resources.usingDefaultMicrophone
            ) else {
                return
            }
            yieldTerminalEvent(generation: generation, error: error)
            var partial = PartialResources(resources)
            partial.errorContext = error
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        case .starting(let stateGeneration, var partial) where stateGeneration == generation:
            dependencies.runtimeEventAcknowledgement?(event)
            guard let error = runtimeError(
                for: event,
                hasMicrophone: partial.microphone != nil,
                hasSystemAudio: partial.hasSystemAudio,
                usingDefaultMicrophone: partial.usingDefaultMicrophone
            ) else {
                return
            }
            yieldTerminalEvent(generation: generation, error: error)
            partial.errorContext = error
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        case .stabilizing(let stateGeneration, var partial) where stateGeneration == generation:
            dependencies.runtimeEventAcknowledgement?(event)
            if event == .streamConfigurationChanged || event == .nominalSampleRateChanged {
                partial.stabilizationInvalidated = true
                lifecycleState = .stabilizing(generation: generation, partial)
                return
            }
            guard let error = runtimeError(
                for: event,
                hasMicrophone: partial.microphone != nil,
                hasSystemAudio: partial.hasSystemAudio,
                usingDefaultMicrophone: partial.usingDefaultMicrophone
            ) else {
                return
            }
            yieldTerminalEvent(generation: generation, error: error)
            partial.errorContext = error
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        default:
            return
        }
    }

    func yieldTerminalEvent(generation: UInt64, error: AudioCaptureError) {
        guard !terminalEventGenerations.contains(generation) else { return }
        terminalEventGenerations.insert(generation)
        terminalEventsContinuation.yield(CaptureTerminalEvent(generation: generation, error: error))
    }

    private nonisolated func runtimeError(
        for event: CaptureDeviceEvent,
        hasMicrophone: Bool,
        hasSystemAudio: Bool,
        usingDefaultMicrophone: Bool
    ) -> AudioCaptureError? {
        switch event {
        case .ioStoppedAbnormally:
            return .ioStoppedAbnormally
        case .streamConfigurationChanged, .nominalSampleRateChanged:
            return .streamFormatChanged
        case .aggregateAliveChanged:
            return .deviceDisconnected
        case .deviceListChanged:
            return hasSystemAudio ? .deviceDisconnected : nil
        case .microphoneAliveChanged:
            return hasMicrophone ? .deviceDisconnected : nil
        case .defaultInputDeviceChanged:
            return usingDefaultMicrophone ? .deviceDisconnected : nil
        case .defaultOutputDeviceChanged:
            return hasSystemAudio ? .deviceDisconnected : nil
        }
    }

    static let minimumStartCapacityBytes: Int64 = 200 * 1_024 * 1_024
}
