import CoreAudio
import Foundation

protocol CaptureAttemptFileManaging: Sendable {
    func fileExists(at url: URL) -> Bool
    func removeItem(at url: URL) throws
}

struct FileManagerCaptureAttemptFileManager: CaptureAttemptFileManaging {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

extension CaptureSession {
    struct PartialResources: Sendable {
        let generation: UInt64
        var microphone: CaptureResolvedMicrophone?
        var aggregate: (any CaptureAggregateDeviceManaging)?
        var pendingAggregateOwner: (any CaptureAggregateDeviceDestroying)?
        var tap: (any SystemAudioTapManaging)?
        var monitor: (any CaptureDeviceMonitorRegistration)?
        var writer: (any CaptureSessionRecordingWriter)?
        var deviceID: AudioObjectID?
        var stopIOProcID: AudioDeviceIOProcID?
        var destroyIOProcID: AudioDeviceIOProcID?
        var deviceStarted: Bool
        var writerResult: Result<FinishedRecordingOutput, Error>?
        var warnings: [AudioCaptureWarning]
        var errorContext: Error?
        var hasSystemAudio: Bool
        var usingDefaultMicrophone: Bool
        var attemptOwnedOutputURL: URL?
        var deleteAttemptOutputOnCleanup: Bool
        var stabilizationInvalidated: Bool

        init(generation: UInt64) {
            self.generation = generation
            self.microphone = nil
            self.aggregate = nil
            self.pendingAggregateOwner = nil
            self.tap = nil
            self.monitor = nil
            self.writer = nil
            self.deviceID = nil
            self.stopIOProcID = nil
            self.destroyIOProcID = nil
            self.deviceStarted = false
            self.writerResult = nil
            self.warnings = []
            self.errorContext = nil
            self.hasSystemAudio = false
            self.usingDefaultMicrophone = false
            self.attemptOwnedOutputURL = nil
            self.deleteAttemptOutputOnCleanup = false
            self.stabilizationInvalidated = false
        }

        init(
            generation: UInt64 = 0,
            microphone: CaptureResolvedMicrophone? = nil,
            aggregate: (any CaptureAggregateDeviceManaging)?,
            pendingAggregateOwner: (any CaptureAggregateDeviceDestroying)? = nil,
            tap: (any SystemAudioTapManaging)? = nil,
            monitor: (any CaptureDeviceMonitorRegistration)?,
            writer: (any CaptureSessionRecordingWriter)?,
            deviceID: AudioObjectID?,
            stopIOProcID: AudioDeviceIOProcID?,
            destroyIOProcID: AudioDeviceIOProcID?,
            deviceStarted: Bool,
            writerResult: Result<FinishedRecordingOutput, Error>? = nil,
            warnings: [AudioCaptureWarning] = [],
            errorContext: Error? = nil,
            hasSystemAudio: Bool = false,
            usingDefaultMicrophone: Bool = false,
            attemptOwnedOutputURL: URL? = nil,
            deleteAttemptOutputOnCleanup: Bool = false,
            stabilizationInvalidated: Bool = false
        ) {
            self.generation = generation
            self.microphone = microphone
            self.aggregate = aggregate
            self.pendingAggregateOwner = pendingAggregateOwner
            self.tap = tap
            self.monitor = monitor
            self.writer = writer
            self.deviceID = deviceID
            self.stopIOProcID = stopIOProcID
            self.destroyIOProcID = destroyIOProcID
            self.deviceStarted = deviceStarted
            self.writerResult = writerResult
            self.warnings = warnings
            self.errorContext = errorContext
            self.hasSystemAudio = hasSystemAudio
            self.usingDefaultMicrophone = usingDefaultMicrophone
            self.attemptOwnedOutputURL = attemptOwnedOutputURL
            self.deleteAttemptOutputOnCleanup = deleteAttemptOutputOnCleanup
            self.stabilizationInvalidated = stabilizationInvalidated
        }

        init(_ resources: ActiveResources) {
            self.init(
                generation: resources.generation,
                microphone: resources.microphone,
                aggregate: resources.aggregate,
                tap: resources.tap,
                monitor: resources.monitor,
                writer: resources.writer,
                deviceID: resources.aggregate.id,
                stopIOProcID: resources.ioProcID,
                destroyIOProcID: resources.ioProcID,
                deviceStarted: resources.deviceStarted,
                warnings: resources.warnings,
                hasSystemAudio: resources.hasSystemAudio,
                usingDefaultMicrophone: resources.usingDefaultMicrophone
            )
        }

        var hasPendingResources: Bool {
            aggregate != nil
                || pendingAggregateOwner != nil
                || tap != nil
                || monitor != nil
                || writer != nil
                || deviceStarted
                || stopIOProcID != nil
                || destroyIOProcID != nil
                || (deleteAttemptOutputOnCleanup && attemptOwnedOutputURL != nil)
        }
    }

    func writerCompleted(_ result: Result<FinishedRecordingOutput, Error>, generation: UInt64) async {
        switch lifecycleState {
        case .active(let resources) where resources.generation == generation,
             .paused(let resources) where resources.generation == generation:
            yieldWriterTerminalEvent(result, generation: generation)
            var partial = PartialResources(resources)
            partial.writerResult = result
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        case .starting(let stateGeneration, var partial) where stateGeneration == generation:
            yieldWriterTerminalEvent(result, generation: generation)
            partial.writerResult = result
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        case .stabilizing(let stateGeneration, var partial) where stateGeneration == generation:
            yieldWriterTerminalEvent(result, generation: generation)
            partial.writerResult = result
            lifecycleState = .cleanupNeeded(partial)
            do {
                _ = try finishTeardown(&partial)
            } catch {
            }
        default:
            return
        }
    }

    private func yieldWriterTerminalEvent(_ result: Result<FinishedRecordingOutput, Error>, generation: UInt64) {
        guard case .failure(let error) = result,
              let audioError = error as? AudioCaptureError
        else { return }
        yieldTerminalEvent(generation: generation, error: audioError)
    }

    func finishTeardown(_ partial: inout PartialResources) throws -> FinishedRecordingOutput {
        do {
            let output = try teardownPartial(&partial)
            lifecycleState = .finished(.success(output))
            return output
        } catch {
            if partial.hasPendingResources {
                lifecycleState = .cleanupNeeded(partial)
            } else {
                lifecycleState = .finished(.failure(error))
            }
            throw error
        }
    }

    func teardownPartial(_ partial: inout PartialResources) throws -> FinishedRecordingOutput {
        var firstError: Error?

        if let monitor = partial.monitor {
            do {
                try monitor.remove()
                partial.monitor = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if partial.deviceStarted, let deviceID = partial.deviceID, let ioProcID = partial.stopIOProcID {
            do {
                try dependencies.ioProcManager.stopDevice(deviceID: deviceID, ioProcID: ioProcID)
                partial.deviceStarted = false
                partial.stopIOProcID = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if !partial.deviceStarted,
           let deviceID = partial.deviceID,
           let ioProcID = partial.destroyIOProcID {
            do {
                try dependencies.ioProcManager.destroyIOProc(deviceID: deviceID, ioProcID: ioProcID)
                partial.destroyIOProcID = nil
                partial.stopIOProcID = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if let writer = partial.writer {
            writer.setCompletionHandler(nil)
            writer.requestStop()
            do {
                partial.writerResult = .success(try writer.join())
                partial.writer = nil
            } catch {
                if isKnownWriterCompletion(error, matching: partial.writerResult)
                    || isOriginalStartupError(error, matching: partial.errorContext) {
                    partial.writer = nil
                } else {
                    firstError = firstError ?? error
                }
            }
        }

        let aggregateDependenciesCleared = partial.monitor == nil
            && !partial.deviceStarted
            && partial.stopIOProcID == nil
            && partial.destroyIOProcID == nil
        if aggregateDependenciesCleared, let aggregate = partial.aggregate {
            do {
                try aggregate.destroy()
                partial.aggregate = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if aggregateDependenciesCleared,
           partial.aggregate == nil,
           let pendingAggregateOwner = partial.pendingAggregateOwner {
            do {
                try pendingAggregateOwner.destroy()
                partial.pendingAggregateOwner = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if partial.aggregate == nil,
           partial.pendingAggregateOwner == nil,
           partial.monitor == nil,
           let tap = partial.tap {
            do {
                try tap.destroy()
                partial.tap = nil
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
        if let errorContext = partial.errorContext {
            try deleteDisposableAttemptOutputIfNeeded(&partial)
            throw errorContext
        }
        guard let writerResult = partial.writerResult else {
            throw AudioCaptureError.fileWriteFailed("Recording writer result unavailable")
        }
        var output = try writerResult.get()
        output = decorateOutput(output, partial: partial)
        try deleteDisposableAttemptOutputIfNeeded(&partial)
        return output
    }

    nonisolated func decorateOutput(
        _ output: FinishedRecordingOutput,
        partial: PartialResources
    ) -> FinishedRecordingOutput {
        var warnings = appendUnique(partial.warnings, output.warnings)
        if partial.hasSystemAudio, output.stats.systemPeak == 0 {
            warnings = appendUnique(warnings, [.systemAudioWasSilent])
        }
        return FinishedRecordingOutput(
            url: output.url,
            duration: output.duration,
            sampleRate: output.sampleRate,
            channelCount: output.channelCount,
            bars: output.bars,
            stats: output.stats,
            warnings: warnings
        )
    }

    func deleteDisposableAttemptOutputIfNeeded(_ partial: inout PartialResources) throws {
        guard partial.deleteAttemptOutputOnCleanup else {
            return
        }
        guard let url = partial.attemptOwnedOutputURL else {
            partial.deleteAttemptOutputOnCleanup = false
            return
        }
        guard dependencies.attemptFileManager.fileExists(at: url) else {
            partial.deleteAttemptOutputOnCleanup = false
            partial.attemptOwnedOutputURL = nil
            return
        }
        try dependencies.attemptFileManager.removeItem(at: url)
        partial.deleteAttemptOutputOnCleanup = false
        partial.attemptOwnedOutputURL = nil
    }

    nonisolated func appendUnique(
        _ existing: [AudioCaptureWarning],
        _ additions: [AudioCaptureWarning]
    ) -> [AudioCaptureWarning] {
        var merged = existing
        for warning in additions where !merged.contains(warning) {
            merged.append(warning)
        }
        return merged
    }

    private nonisolated func isOriginalStartupError(
        _ error: Error,
        matching originalError: Error?
    ) -> Bool {
        guard let originalError else { return false }
        if let lhs = error as? AudioCaptureError, let rhs = originalError as? AudioCaptureError {
            return lhs == rhs
        }
        return false
    }

    private nonisolated func isKnownWriterCompletion(
        _ error: Error,
        matching result: Result<FinishedRecordingOutput, Error>?
    ) -> Bool {
        guard case .failure(let knownError) = result else {
            return false
        }
        if let lhs = error as? AudioCaptureError, let rhs = knownError as? AudioCaptureError {
            return lhs == rhs
        }
        return false
    }
}
