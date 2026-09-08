@testable import AudioPipeline
import CoreAudio
import Darwin
import Dispatch
import Foundation

func fakeAudioDeviceIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    noErr
}

enum LifecycleEvent: Equatable, CustomStringConvertible, Sendable {
    case permission
    case resolveMicrophone
    case resolveOutput
    case resolveProcessObject
    case diskPreflight
    case tapCreate
    case tapFormatRead
    case aggregateCreate
    case aggregateDestroy
    case tapDestroy
    case listenerRegister
    case listenerRemove
    case writerMake
    case writerStart
    case writerPause
    case writerResume
    case writerRequestStop
    case writerJoin
    case ioProcCreate
    case ioProcDestroy
    case deviceStart
    case deviceStop
    case stabilizationWait

    var description: String {
        switch self {
        case .permission: "permission"
        case .resolveMicrophone: "resolveMicrophone"
        case .resolveOutput: "resolveOutput"
        case .resolveProcessObject: "resolveProcessObject"
        case .diskPreflight: "diskPreflight"
        case .tapCreate: "tapCreate"
        case .tapFormatRead: "tapFormatRead"
        case .aggregateCreate: "aggregateCreate"
        case .aggregateDestroy: "aggregateDestroy"
        case .tapDestroy: "tapDestroy"
        case .listenerRegister: "listenerRegister"
        case .listenerRemove: "listenerRemove"
        case .writerMake: "writerMake"
        case .writerStart: "writerStart"
        case .writerPause: "writerPause"
        case .writerResume: "writerResume"
        case .writerRequestStop: "writerRequestStop"
        case .writerJoin: "writerJoin"
        case .ioProcCreate: "ioProcCreate"
        case .ioProcDestroy: "ioProcDestroy"
        case .deviceStart: "deviceStart"
        case .deviceStop: "deviceStop"
        case .stabilizationWait: "stabilizationWait"
        }
    }
}

enum StartFailurePoint: Sendable {
    case processLookup
    case tapCreate
    case tapFormatRead
    case aggregateCreate
    case listenerRegister
    case writerMake
    case writerStart
    case ioProcCreate
    case deviceStart
}

final class LifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [LifecycleEvent] = []

    func append(_ event: LifecycleEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events() -> [LifecycleEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

extension CaptureSession.Dependencies {
    static func fake(
        log: LifecycleLog,
        permissionGranted: Bool = true,
        diskCapacity: Int64 = 1_000_000_000,
        failurePoint: StartFailurePoint? = nil,
        permissionRequester: (any MicrophonePermissionRequesting)? = nil,
        deviceResolver: (any CaptureDeviceResolving)? = nil,
        diskSpaceChecker: (any DiskSpaceChecking)? = nil,
        aggregateFactory: (any CaptureAggregateDeviceMaking)? = nil,
        teardownFailures: LifecycleFailurePlan = LifecycleFailurePlan(),
        writerProbe: FakeSessionWriterProbe? = nil,
        writerFactory: (any CaptureSessionRecordingWriterMaking)? = nil,
        ioProcManager: (any CaptureDeviceIOProcManaging)? = nil,
        processObjects: (any AudioProcessObjectResolving)? = nil,
        systemTapFactory: (any SystemAudioTapMaking)? = nil,
        stabilizationWaiter: (any CaptureStabilizationWaiting)? = nil,
        attemptFileManager: (any CaptureAttemptFileManaging)? = nil,
        runtimeEventAcknowledgement: (@Sendable (CaptureDeviceEvent) -> Void)? = nil
    ) -> CaptureSession.Dependencies {
        CaptureSession.Dependencies(
            permissionRequester: permissionRequester ?? FakeMicrophonePermissionRequester(
                log: log,
                granted: permissionGranted
            ),
            deviceResolver: deviceResolver ?? FakeCaptureDeviceResolver(log: log),
            diskSpaceChecker: diskSpaceChecker ?? FakePreflightDiskSpaceChecker(log: log, capacity: diskCapacity),
            aggregateFactory: aggregateFactory ?? FakeAggregateFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            monitorFactory: FakeMonitorFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            writerFactory: writerFactory ?? FakeSessionWriterFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures,
                probe: writerProbe
            ),
            ioProcManager: ioProcManager ?? FakeIOProcManager(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            processObjects: processObjects ?? FakeProcessObjectResolver(log: log, failurePoint: failurePoint),
            systemTapFactory: systemTapFactory ?? FakeSystemAudioTapFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            stabilizationWaiter: stabilizationWaiter ?? ZeroDelayCaptureStabilizationWaiter(),
            attemptFileManager: attemptFileManager ?? FileManagerCaptureAttemptFileManager(),
            runtimeEventAcknowledgement: runtimeEventAcknowledgement
        )
    }

    static func fakeWithWriterFactory(
        log: LifecycleLog,
        permissionGranted: Bool = true,
        diskCapacity: Int64 = 1_000_000_000,
        failurePoint: StartFailurePoint? = nil,
        teardownFailures: LifecycleFailurePlan = LifecycleFailurePlan(),
        writerFactory: any CaptureSessionRecordingWriterMaking,
        attemptFileManager: (any CaptureAttemptFileManaging)? = nil,
        runtimeEventAcknowledgement: (@Sendable (CaptureDeviceEvent) -> Void)? = nil
    ) -> CaptureSession.Dependencies {
        CaptureSession.Dependencies(
            permissionRequester: FakeMicrophonePermissionRequester(log: log, granted: permissionGranted),
            deviceResolver: FakeCaptureDeviceResolver(log: log),
            diskSpaceChecker: FakePreflightDiskSpaceChecker(log: log, capacity: diskCapacity),
            aggregateFactory: FakeAggregateFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            monitorFactory: FakeMonitorFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            writerFactory: writerFactory,
            ioProcManager: FakeIOProcManager(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            processObjects: FakeProcessObjectResolver(log: log, failurePoint: failurePoint),
            systemTapFactory: FakeSystemAudioTapFactory(
                log: log,
                failurePoint: failurePoint,
                teardownFailures: teardownFailures
            ),
            stabilizationWaiter: ZeroDelayCaptureStabilizationWaiter(),
            attemptFileManager: attemptFileManager ?? FileManagerCaptureAttemptFileManager(),
            runtimeEventAcknowledgement: runtimeEventAcknowledgement
        )
    }
}

func configuration(mode: CaptureMode = .micOnly) -> RecordingConfiguration {
    RecordingConfiguration(
        mode: mode,
        microphoneUID: "mic-uid",
        outputURL: URL(fileURLWithPath: "/tmp/notetaker-test-output.m4a"),
        microphoneGain: 1,
        systemGain: 0
    )
}

let micOnlyChannelMap = InputChannelMap(
    microphoneChannels: [0],
    systemChannels: [],
    bufferLayout: [InputBufferLayout(bufferIndex: 0, channelCount: 1)],
    confidence: .terminalType
)

let micStream = InputStreamDescriptor(
    bufferIndex: 0,
    startingChannelIndex: 0,
    channelCount: 1,
    terminalType: .microphone,
    name: "Built-in Microphone"
)

struct FakeMicrophonePermissionRequester: MicrophonePermissionRequesting {
    let log: LifecycleLog
    let granted: Bool

    func requestRecordPermission() async -> Bool {
        log.append(.permission)
        return granted
    }
}

struct FakeCaptureDeviceResolver: CaptureDeviceResolving {
    let log: LifecycleLog

    func resolveMicrophone(uid: String?) throws -> CaptureResolvedMicrophone {
        log.append(.resolveMicrophone)
        return CaptureResolvedMicrophone(
            id: 11,
            uid: uid ?? "default-mic",
            inputStreams: [micStream]
        )
    }

    func resolveDefaultOutput() throws -> CaptureResolvedOutput {
        log.append(.resolveOutput)
        return CaptureResolvedOutput(id: 12, uid: "default-output")
    }
}

struct FakeProcessObjectResolver: AudioProcessObjectResolving {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    var processObjectID: AudioObjectID? = 41

    func currentProcessObjectID() throws -> AudioObjectID? {
        log.append(.resolveProcessObject)
        if failurePoint == .processLookup {
            throw AudioCaptureError.deviceDisconnected
        }
        return processObjectID
    }
}

struct FakePreflightDiskSpaceChecker: DiskSpaceChecking {
    let log: LifecycleLog
    let capacity: Int64

    func availableCapacity(at url: URL) throws -> Int64 {
        log.append(.diskPreflight)
        return capacity
    }
}

struct ZeroDelayCaptureStabilizationWaiter: CaptureStabilizationWaiting {
    func wait() async throws {}
}

struct FakeAggregateFactory: CaptureAggregateDeviceMaking {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    let teardownFailures: LifecycleFailurePlan
    let probe: FakeAggregateFactoryProbe?

    init(
        log: LifecycleLog,
        failurePoint: StartFailurePoint?,
        teardownFailures: LifecycleFailurePlan,
        probe: FakeAggregateFactoryProbe? = nil
    ) {
        self.log = log
        self.failurePoint = failurePoint
        self.teardownFailures = teardownFailures
        self.probe = probe
    }

    func createMicOnlyAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor]
    ) throws -> any CaptureAggregateDeviceManaging {
        log.append(.aggregateCreate)
        if failurePoint == .aggregateCreate {
            throw AudioCaptureError.aggregateCreationFailed(-50)
        }
        return FakeAggregate(log: log, teardownFailures: teardownFailures)
    }

    func createSystemOnlyAggregate(
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int
    ) throws -> any CaptureAggregateDeviceManaging {
        log.append(.aggregateCreate)
        if failurePoint == .aggregateCreate {
            throw AudioCaptureError.aggregateCreationFailed(-50)
        }
        return FakeAggregate.systemOnly(log: log, teardownFailures: teardownFailures, tapChannelCount: tapChannelCount)
    }

    func createMicAndSystemAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) throws -> any CaptureAggregateDeviceManaging {
        log.append(.aggregateCreate)
        probe?.recordMixedAggregate(
            microphoneUID: microphoneUID,
            microphoneStreams: microphoneStreams,
            outputUID: outputUID,
            tapUID: tapUID,
            tapChannelCount: tapChannelCount,
            clockSource: clockSource
        )
        if failurePoint == .aggregateCreate {
            throw AudioCaptureError.aggregateCreationFailed(-50)
        }
        return FakeAggregate.micAndSystem(
            log: log,
            teardownFailures: teardownFailures,
            microphoneStreams: microphoneStreams,
            tapChannelCount: tapChannelCount
        )
    }
}

final class FakeAggregateFactoryProbe: @unchecked Sendable {
    struct MixedAggregateCall: Equatable, Sendable {
        let microphoneUID: String
        let microphoneStreams: [InputStreamDescriptor]
        let outputUID: String
        let tapUID: UUID
        let tapChannelCount: Int
        let clockSource: AggregateClockSource
    }

    private let lock = NSLock()
    private var mixedCalls: [MixedAggregateCall] = []

    func recordMixedAggregate(
        microphoneUID: String,
        microphoneStreams: [InputStreamDescriptor],
        outputUID: String,
        tapUID: UUID,
        tapChannelCount: Int,
        clockSource: AggregateClockSource
    ) {
        lock.lock()
        mixedCalls.append(MixedAggregateCall(
            microphoneUID: microphoneUID,
            microphoneStreams: microphoneStreams,
            outputUID: outputUID,
            tapUID: tapUID,
            tapChannelCount: tapChannelCount,
            clockSource: clockSource
        ))
        lock.unlock()
    }

    func mixedAggregateCalls() -> [MixedAggregateCall] {
        lock.lock()
        defer { lock.unlock() }
        return mixedCalls
    }
}

final class FakeAggregate: CaptureAggregateDeviceManaging, @unchecked Sendable {
    let id = AudioObjectID(99)
    let uid = "com.seonwoo.notetaker.tests.aggregate"
    let sampleRate = 48_000.0
    let inputStreams: [InputStreamDescriptor]
    let channelMap: InputChannelMap
    let inputChannelCount: Int
    let inputBufferChannelCounts: [Int]
    let bufferFrameSize = 512
    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private let lock = NSLock()
    private var destroyed = false
    private var currentInputStreamReads = 0
    private var currentInputStreamSequence: [[InputStreamDescriptor]]
    private var currentInputBufferReads = 0
    private var currentInputBufferSequence: [[Int]]
    private let onCurrentInputStreams: (@Sendable () -> Void)?

    init(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan,
        inputStreams: [InputStreamDescriptor] = [micStream],
        channelMap: InputChannelMap = micOnlyChannelMap,
        inputChannelCount: Int = 1,
        inputBufferChannelCounts: [Int]? = nil,
        currentInputStreamSequence: [[InputStreamDescriptor]]? = nil,
        currentInputBufferSequence: [[Int]]? = nil,
        onCurrentInputStreams: (@Sendable () -> Void)? = nil
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.inputStreams = inputStreams
        self.channelMap = channelMap
        self.inputChannelCount = inputChannelCount
        self.inputBufferChannelCounts = inputBufferChannelCounts ?? channelMap.bufferLayout.map(\.channelCount)
        self.currentInputStreamSequence = currentInputStreamSequence ?? [inputStreams]
        self.currentInputBufferSequence = currentInputBufferSequence
            ?? [inputBufferChannelCounts ?? channelMap.bufferLayout.map(\.channelCount)]
        self.onCurrentInputStreams = onCurrentInputStreams
    }

    static func systemOnly(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan,
        tapChannelCount: Int
    ) -> FakeAggregate {
        let streams = [InputStreamDescriptor(
            bufferIndex: 0,
            startingChannelIndex: 0,
            channelCount: tapChannelCount,
            terminalType: .unknown,
            name: "Tap"
        )]
        return FakeAggregate(
            log: log,
            teardownFailures: teardownFailures,
            inputStreams: streams,
            channelMap: InputChannelMap(
                microphoneChannels: [],
                systemChannels: Array(0..<tapChannelCount),
                bufferLayout: [InputBufferLayout(bufferIndex: 0, channelCount: tapChannelCount)],
                confidence: .terminalType
            ),
            inputChannelCount: tapChannelCount
        )
    }

    static func micAndSystem(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan,
        microphoneStreams: [InputStreamDescriptor],
        tapChannelCount: Int
    ) -> FakeAggregate {
        let streams = microphoneStreams + [InputStreamDescriptor(
            bufferIndex: microphoneStreams.count,
            startingChannelIndex: microphoneStreams.reduce(0) { $0 + $1.channelCount },
            channelCount: tapChannelCount,
            terminalType: .unknown,
            name: "Tap"
        )]
        let microphoneChannelCount = microphoneStreams.reduce(0) { $0 + $1.channelCount }
        let totalChannelCount = microphoneChannelCount + tapChannelCount
        return FakeAggregate(
            log: log,
            teardownFailures: teardownFailures,
            inputStreams: streams,
            channelMap: InputChannelMap(
                microphoneChannels: Array(0..<microphoneChannelCount),
                systemChannels: Array(microphoneChannelCount..<totalChannelCount),
                bufferLayout: streams.map {
                    InputBufferLayout(bufferIndex: $0.bufferIndex, channelCount: $0.channelCount)
                },
                confidence: .assumedMicThenTap
            ),
            inputChannelCount: totalChannelCount
        )
    }

    func currentInputStreams() throws -> [InputStreamDescriptor] {
        onCurrentInputStreams?()
        lock.lock()
        let index = min(currentInputStreamReads, currentInputStreamSequence.count - 1)
        currentInputStreamReads += 1
        let streams = currentInputStreamSequence[index]
        lock.unlock()
        return streams
    }

    func currentInputBufferChannelCounts() throws -> [Int] {
        lock.lock()
        let index = min(currentInputBufferReads, currentInputBufferSequence.count - 1)
        currentInputBufferReads += 1
        let counts = currentInputBufferSequence[index]
        lock.unlock()
        return counts
    }

    func destroy() throws {
        lock.lock()
        let shouldDestroy = !destroyed
        lock.unlock()
        if shouldDestroy {
            log.append(.aggregateDestroy)
            if let error = teardownFailures.consumeFailure(at: .aggregateDestroy) {
                throw error
            }
            lock.lock()
            destroyed = true
            lock.unlock()
        }
    }
}

struct FakeMonitorFactory: CaptureDeviceMonitoring {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    let teardownFailures: LifecycleFailurePlan

    func register(
        aggregateID: AudioObjectID,
        microphoneID: AudioObjectID?,
        eventHandler: @escaping @Sendable (CaptureDeviceEvent) -> Void
    ) throws -> any CaptureDeviceMonitorRegistration {
        log.append(.listenerRegister)
        if failurePoint == .listenerRegister {
            throw AudioCaptureError.deviceDisconnected
        }
        return FakeMonitorRegistration(log: log, teardownFailures: teardownFailures)
    }
}

struct FakeSystemAudioTapFactory: SystemAudioTapMaking {
    let log: LifecycleLog
    let failurePoint: StartFailurePoint?
    let teardownFailures: LifecycleFailurePlan
    var warnings: [AudioCaptureWarning] = []
    var format: SystemAudioTapFormat = validSystemTapFormat

    func create(excludingProcessID: AudioObjectID?) throws -> any SystemAudioTapManaging {
        log.append(.tapCreate)
        if failurePoint == .tapCreate {
            throw AudioCaptureError.tapCreationFailed(-50)
        }
        return FakeSystemAudioTap(
            log: log,
            teardownFailures: teardownFailures,
            uid: fixedSystemTapUUID,
            warnings: excludingProcessID == nil ? appendWarning(warnings, .selfExclusionUnavailable) : warnings,
            formatError: failurePoint == .tapFormatRead ? AudioCaptureError.unsupportedStreamFormat(nil) : nil,
            format: format
        )
    }
}


private func appendWarning(_ warnings: [AudioCaptureWarning], _ warning: AudioCaptureWarning) -> [AudioCaptureWarning] {
    warnings.contains(warning) ? warnings : warnings + [warning]
}

let fixedSystemTapUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 153))

let validSystemTapFormat = SystemAudioTapFormat(
    sampleRate: 48_000,
    formatID: kAudioFormatLinearPCM,
    formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
    bytesPerPacket: 8,
    framesPerPacket: 1,
    bytesPerFrame: 8,
    channelCount: 2,
    bitsPerChannel: 32
)


struct PermissionDeniedTapFactory: SystemAudioTapMaking {
    let log: LifecycleLog

    func create(excludingProcessID: AudioObjectID?) throws -> any SystemAudioTapManaging {
        log.append(.tapCreate)
        throw AudioCaptureError.systemAudioPermissionDenied
    }
}

final class FakeSystemAudioTap: SystemAudioTapManaging, @unchecked Sendable {
    let id = AudioObjectID(199)
    let uid: UUID
    let warnings: [AudioCaptureWarning]

    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private let lock = NSLock()
    private var destroyed = false
    private let formatError: AudioCaptureError?
    private let logEveryFormatRead: Bool
    private var formats: [SystemAudioTapFormat]
    private var formatReads = 0

    init(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan,
        uid: UUID,
        warnings: [AudioCaptureWarning] = [],
        formatError: AudioCaptureError? = nil,
        format: SystemAudioTapFormat = validSystemTapFormat,
        formats: [SystemAudioTapFormat]? = nil,
        logEveryFormatRead: Bool = false
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.uid = uid
        self.warnings = warnings
        self.formatError = formatError
        self.formats = formats ?? [format]
        self.logEveryFormatRead = logEveryFormatRead
    }

    func currentFormat() throws -> SystemAudioTapFormat {
        lock.lock()
        let readIndex = min(formatReads, formats.count - 1)
        formatReads += 1
        let shouldLog = logEveryFormatRead || formatReads == 1
        let format = formats[readIndex]
        lock.unlock()
        if shouldLog {
            log.append(.tapFormatRead)
        }
        if let formatError { throw formatError }
        return format
    }

    func destroy() throws {
        lock.lock()
        let shouldDestroy = !destroyed
        lock.unlock()
        if shouldDestroy {
            log.append(.tapDestroy)
            if let error = teardownFailures.consumeFailure(at: .tapDestroy) {
                throw error
            }
            lock.lock()
            destroyed = true
            lock.unlock()
        }
    }
}

final class CapturingSessionWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: CapturingSessionWriter?

    func publish(_ writer: CapturingSessionWriter) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    func requireWriter() throws -> CapturingSessionWriter {
        lock.lock()
        defer { lock.unlock() }
        guard let writer else {
            throw AudioCaptureError.fileWriteFailed("writer unavailable")
        }
        return writer
    }
}

struct CapturingSessionWriterFactory: CaptureSessionRecordingWriterMaking {
    let log: LifecycleLog
    let teardownFailures: LifecycleFailurePlan
    let probe: CapturingSessionWriterProbe?
    private let startFailureGate: StartFailureGate
    private let warnings: [AudioCaptureWarning]
    private let systemPeak: Float
    private let createsOutputOnStart: Bool
    private let onStart: (@Sendable (_ startCount: Int, _ outputURL: URL) -> Void)?
    private let startCounter: StartCounter

    init(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan = LifecycleFailurePlan(),
        probe: CapturingSessionWriterProbe? = nil,
        failFirstStart: Bool = false,
        warnings: [AudioCaptureWarning] = [],
        systemPeak: Float = 0,
        createsOutputOnStart: Bool = false,
        onStart: (@Sendable (_ startCount: Int, _ outputURL: URL) -> Void)? = nil
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.probe = probe
        self.startFailureGate = StartFailureGate(remainingFailures: failFirstStart ? 1 : 0)
        self.warnings = warnings
        self.systemPeak = systemPeak
        self.createsOutputOnStart = createsOutputOnStart
        self.onStart = onStart
        self.startCounter = StartCounter()
    }

    func makeWriter(
        inputSampleRate: Double,
        inputChannelCount: Int,
        layout: MixChannelLayout,
        ring: SPSCRingBuffer,
        wake: DispatchSemaphore,
        outputURL: URL,
        microphoneGain: Float,
        systemGain: Float,
        liveAudioHandler: LiveAudioSampleHandler?,
        diskSpaceChecker: any DiskSpaceChecking
    ) throws -> any CaptureSessionRecordingWriter {
        log.append(.writerMake)
        let writer = CapturingSessionWriter(
            log: log,
            teardownFailures: teardownFailures,
            outputURL: outputURL,
            shouldFailStart: startFailureGate.consume(),
            warnings: warnings,
            systemPeak: systemPeak,
            createsOutputOnStart: createsOutputOnStart,
            onStart: { [startCounter, onStart] outputURL in
                onStart?(startCounter.increment(), outputURL)
            }
        )
        probe?.publish(writer)
        return writer
    }
}

private final class StartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        return starts
    }
}

private final class StartFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int

    init(remainingFailures: Int) {
        self.remainingFailures = remainingFailures
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}

final class CapturingSessionWriter: CaptureSessionRecordingWriter, @unchecked Sendable {
    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private let outputURL: URL
    private let shouldFailStart: Bool
    private let warnings: [AudioCaptureWarning]
    private let systemPeak: Float
    private let createsOutputOnStart: Bool
    private let lock = NSLock()
    private var terminalResult: Result<FinishedRecordingOutput, Error>?
    private var joined = false
    private var completionHandler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?
    private let onStart: (@Sendable (_ outputURL: URL) -> Void)?

    init(
        log: LifecycleLog,
        teardownFailures: LifecycleFailurePlan,
        outputURL: URL,
        shouldFailStart: Bool,
        warnings: [AudioCaptureWarning] = [],
        systemPeak: Float = 0,
        createsOutputOnStart: Bool = false,
        onStart: (@Sendable (_ outputURL: URL) -> Void)? = nil
    ) {
        self.log = log
        self.teardownFailures = teardownFailures
        self.outputURL = outputURL
        self.shouldFailStart = shouldFailStart
        self.warnings = warnings
        self.systemPeak = systemPeak
        self.createsOutputOnStart = createsOutputOnStart
        self.onStart = onStart
    }

    func start() throws {
        log.append(.writerStart)
        onStart?(outputURL)
        if createsOutputOnStart {
            try createFakeOutputExclusively(at: outputURL)
        }
        if shouldFailStart {
            let error = AudioCaptureError.fileWriteFailed("synthetic start failure")
            lock.lock()
            terminalResult = .failure(error)
            lock.unlock()
            throw error
        }
    }

    func setCompletionHandler(_ handler: (@Sendable (Result<FinishedRecordingOutput, Error>) -> Void)?) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
    }

    func requireCompletionHandler() throws -> @Sendable (Result<FinishedRecordingOutput, Error>) -> Void {
        lock.lock()
        defer { lock.unlock() }
        guard let completionHandler else {
            throw AudioCaptureError.fileWriteFailed("completion handler unavailable")
        }
        return completionHandler
    }

    func requestStop() {
        lock.lock()
        let shouldStop = !joined
        lock.unlock()
        if shouldStop {
            log.append(.writerRequestStop)
        }
    }

    func pause() throws -> RecordingSegmentOutput {
        log.append(.writerPause)
        return RecordingSegmentOutput(
            url: outputURL,
            duration: 0.25,
            outputFramesWritten: 12_000
        )
    }

    func resume(outputURL: URL) throws {
        log.append(.writerResume)
    }

    func join() throws -> FinishedRecordingOutput {
        lock.lock()
        let shouldJoin = !joined
        let terminalResult = terminalResult
        if terminalResult != nil {
            joined = true
        }
        lock.unlock()
        if shouldJoin {
            log.append(.writerJoin)
        }
        if let terminalResult {
            return try terminalResult.get()
        }
        if let error = teardownFailures.consumeFailure(at: .writerJoin) {
            throw error
        }
        lock.lock()
        joined = true
        lock.unlock()
        return FinishedRecordingOutput(
            url: outputURL,
            duration: 1,
            sampleRate: 48_000,
            channelCount: 2,
            bars: [],
            stats: RecordingWriterStats(
                inputFramesRead: 48_000,
                outputFramesWritten: 48_000,
                fileWriteCalls: 1,
                barsEmitted: 0,
                ringDroppedFrames: 0,
                ringOverflowCount: 0,
                microphonePeak: 0,
                systemPeak: systemPeak
            ),
            warnings: warnings
        )
    }
}

private func createFakeOutputExclusively(at url: URL) throws {
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, flags, mode_t(0o666))
    }
    guard descriptor >= 0 else {
        let errorCode = errno
        if errorCode == EEXIST {
            throw AudioCaptureError.outputAlreadyExists(url.path)
        }
        throw AudioCaptureError.fileWriteFailed(
            "Could not create fake output at \(url.path): \(String(cString: strerror(errorCode))) (errno \(errorCode))"
        )
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: Data("attempt".utf8))
    try handle.close()
}

final class FakeMonitorRegistration: CaptureDeviceMonitorRegistration, @unchecked Sendable {
    private let log: LifecycleLog
    private let teardownFailures: LifecycleFailurePlan
    private let lock = NSLock()
    private var removed = false

    init(log: LifecycleLog, teardownFailures: LifecycleFailurePlan) {
        self.log = log
        self.teardownFailures = teardownFailures
    }

    func remove() throws {
        lock.lock()
        let shouldRemove = !removed
        lock.unlock()
        if shouldRemove {
            log.append(.listenerRemove)
            if let error = teardownFailures.consumeFailure(at: .listenerRemove) {
                throw error
            }
            lock.lock()
            removed = true
            lock.unlock()
        }
    }
}

struct PermissionDeniedIOProcManager: CaptureDeviceIOProcManaging {
    let log: LifecycleLog

    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue,
        block: @escaping AudioDeviceIOBlock
    ) throws -> AudioDeviceIOProcID {
        log.append(.ioProcCreate)
        return fakeAudioDeviceIOProc
    }

    func startDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.deviceStart)
        throw AudioCaptureError.startFailed(kAudioDevicePermissionsError)
    }

    func stopDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.deviceStop)
    }

    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        log.append(.ioProcDestroy)
    }
}
