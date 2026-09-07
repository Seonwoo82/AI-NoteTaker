@testable import AudioPipeline
import CoreAudio
import Foundation
import Testing

@Test("CaptureSession mic and system starts both sources through shared resources")
func captureSessionMicAndSystemStartsBothSourcesThroughSharedResources() async throws {
    let log = LifecycleLog()
    let aggregateProbe = FakeAggregateFactoryProbe()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        aggregateFactory: FakeAggregateFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan(),
            probe: aggregateProbe
        )
    ))

    let result = try await session.start(configuration: configuration(mode: .micAndSystem))

    #expect(result.aggregateSampleRate == 48_000)
    #expect(result.channelMap.microphoneChannels == [0])
    #expect(result.channelMap.systemChannels == [1, 2])
    #expect(log.events() == [
        .permission,
        .resolveMicrophone,
        .resolveOutput,
        .resolveProcessObject,
        .diskPreflight,
        .tapCreate,
        .tapFormatRead,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart
    ])
    #expect(aggregateProbe.mixedAggregateCalls() == [
        FakeAggregateFactoryProbe.MixedAggregateCall(
            microphoneUID: "mic-uid",
            microphoneStreams: [micStream],
            outputUID: "default-output",
            tapUID: fixedSystemTapUUID,
            tapChannelCount: 2,
            clockSource: .microphone
        )
    ])

    _ = try await session.stop()
    #expect(log.events().suffix(7) == [
        .listenerRemove,
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy,
        .tapDestroy
    ])
}

@Test("CaptureSession mic and system forwards explicit output clock source")
func captureSessionMicAndSystemForwardsExplicitOutputClockSource() async throws {
    let log = LifecycleLog()
    let aggregateProbe = FakeAggregateFactoryProbe()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        aggregateFactory: FakeAggregateFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan(),
            probe: aggregateProbe
        )
    ))
    let configuration = RecordingConfiguration(
        mode: .micAndSystem,
        microphoneUID: "mic-uid",
        outputURL: URL(fileURLWithPath: "/tmp/notetaker-test-output.m4a"),
        microphoneGain: 1,
        systemGain: 1,
        clockSource: .output
    )

    _ = try await session.start(configuration: configuration)

    #expect(aggregateProbe.mixedAggregateCalls().map(\.clockSource) == [.output])
    _ = try await session.stop()
}

@Test("CaptureSession mic and system denied microphone permission has no device or tap side effects")
func captureSessionMicAndSystemDeniedMicrophonePermissionHasNoDeviceOrTapSideEffects() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        permissionGranted: false
    ))

    do {
        _ = try await session.start(configuration: configuration(mode: .micAndSystem))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.microphonePermissionDenied {
        #expect(log.events() == [.permission])
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("CaptureSession mic and system unwinds each injected startup failure in reverse order")
func captureSessionMicAndSystemUnwindsEveryInjectedStartupFailure() async throws {
    let cases: [(StartFailurePoint, [LifecycleEvent], AudioCaptureError)] = [
        (
            .processLookup,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject],
            .deviceDisconnected
        ),
        (
            .tapCreate,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate],
            .tapCreationFailed(-50)
        ),
        (
            .tapFormatRead,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .tapDestroy],
            .unsupportedStreamFormat(nil)
        ),
        (
            .aggregateCreate,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .tapDestroy],
            .aggregateCreationFailed(-50)
        ),
        (
            .writerMake,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .writerMake, .aggregateDestroy, .tapDestroy],
            .fileWriteFailed("synthetic make failure")
        ),
        (
            .listenerRegister,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .writerMake, .listenerRegister,
             .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy],
            .deviceDisconnected
        ),
        (
            .writerStart,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .writerMake, .listenerRegister, .writerStart,
             .listenerRemove, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy],
            .fileWriteFailed("synthetic start failure")
        ),
        (
            .ioProcCreate,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .writerMake, .listenerRegister, .writerStart,
             .ioProcCreate, .listenerRemove, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy],
            .ioProcCreationFailed(-50)
        ),
        (
            .deviceStart,
            [.permission, .resolveMicrophone, .resolveOutput, .resolveProcessObject, .diskPreflight,
             .tapCreate, .tapFormatRead, .aggregateCreate, .writerMake, .listenerRegister, .writerStart,
             .ioProcCreate, .deviceStart, .listenerRemove, .ioProcDestroy, .writerRequestStop,
             .writerJoin, .aggregateDestroy, .tapDestroy],
            .startFailed(-50)
        )
    ]

    for (failurePoint, expectedEvents, expectedError) in cases {
        let log = LifecycleLog()
        let session = CaptureSession(dependencies: .fake(log: log, failurePoint: failurePoint))

        do {
            _ = try await session.start(configuration: configuration(mode: .micAndSystem))
            Issue.record("start unexpectedly succeeded for \(failurePoint)")
        } catch let error as AudioCaptureError {
            #expect(error == expectedError)
            #expect(log.events() == expectedEvents, "\(failurePoint) events: \(log.events())")
        } catch {
            Issue.record("unexpected error for \(failurePoint): \(error)")
        }
    }
}

@Test("CaptureSession maps denied microphone permission before device mutation")
func captureSessionMapsDeniedMicrophonePermissionBeforeDeviceMutation() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        permissionGranted: false
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.microphonePermissionDenied {
        #expect(log.events() == [.permission])
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("CaptureSession rejects less than 200 MB before aggregate and writer creation")
func captureSessionRejectsLowPreflightCapacityBeforeHALMutation() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        diskCapacity: (200 * 1_024 * 1_024) - 1
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(log.events() == [.permission, .resolveMicrophone, .diskPreflight])
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}


@Test("CaptureSession retries successfully after microphone resolution failure resets startup state")
func captureSessionRetriesAfterMicrophoneResolutionFailure() async throws {
    let log = LifecycleLog()
    let resolver = FailsOnceCaptureDeviceResolver(log: log)
    let session = CaptureSession(dependencies: .fake(
        log: log,
        deviceResolver: resolver
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("first start unexpectedly succeeded")
    } catch AudioCaptureError.deviceDisconnected {
        #expect(log.events() == [.permission, .resolveMicrophone])
    } catch {
        Issue.record("unexpected first-start error: \(error)")
    }

    let result = try await session.start(configuration: configuration())

    #expect(result.aggregateSampleRate == 48_000)
    #expect(result.channelMap == micOnlyChannelMap)
    #expect(log.events() == [
        .permission,
        .resolveMicrophone,
        .permission,
        .resolveMicrophone,
        .diskPreflight,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart
    ])
}

@Test("CaptureSession retries successfully after low disk preflight resets startup state")
func captureSessionRetriesAfterLowDiskPreflightFailure() async throws {
    let log = LifecycleLog()
    let diskSpace = MutableFakePreflightDiskSpaceChecker(
        log: log,
        capacity: (200 * 1_024 * 1_024) - 1
    )
    let session = CaptureSession(dependencies: .fake(
        log: log,
        diskSpaceChecker: diskSpace
    ))

    do {
        _ = try await session.start(configuration: configuration())
        Issue.record("first start unexpectedly succeeded")
    } catch AudioCaptureError.diskSpaceLow {
        #expect(log.events() == [.permission, .resolveMicrophone, .diskPreflight])
    } catch {
        Issue.record("unexpected first-start error: \(error)")
    }

    diskSpace.setCapacity(200 * 1_024 * 1_024)
    let result = try await session.start(configuration: configuration())

    #expect(result.aggregateSampleRate == 48_000)
    #expect(result.channelMap == micOnlyChannelMap)
    #expect(log.events() == [
        .permission,
        .resolveMicrophone,
        .diskPreflight,
        .permission,
        .resolveMicrophone,
        .diskPreflight,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart
    ])
}

@Test("CaptureSession start failure unwinds acquired resources exactly once in reverse order")
func captureSessionStartFailureUnwindsAcquiredResourcesInReverseOrder() async throws {
    let cases: [(StartFailurePoint, [LifecycleEvent], AudioCaptureError)] = [
        (
            .aggregateCreate,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate],
            .aggregateCreationFailed(-50)
        ),
        (
            .listenerRegister,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate, .writerMake,
             .listenerRegister, .writerRequestStop, .writerJoin, .aggregateDestroy],
            .deviceDisconnected
        ),
        (
            .writerMake,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate, .writerMake,
             .aggregateDestroy],
            .fileWriteFailed("synthetic make failure")
        ),
        (
            .writerStart,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate, .writerMake,
             .listenerRegister, .writerStart, .listenerRemove, .writerRequestStop, .writerJoin,
             .aggregateDestroy],
            .fileWriteFailed("synthetic start failure")
        ),
        (
            .ioProcCreate,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate, .writerMake,
             .listenerRegister, .writerStart, .ioProcCreate, .listenerRemove, .writerRequestStop,
             .writerJoin, .aggregateDestroy],
            .ioProcCreationFailed(-50)
        ),
        (
            .deviceStart,
            [.permission, .resolveMicrophone, .diskPreflight, .aggregateCreate, .writerMake,
             .listenerRegister, .writerStart, .ioProcCreate, .deviceStart, .listenerRemove,
             .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy],
            .startFailed(-50)
        )
    ]

    for (failurePoint, expectedEvents, expectedError) in cases {
        let log = LifecycleLog()
        let session = CaptureSession(dependencies: .fake(
            log: log,
            failurePoint: failurePoint
        ))

        do {
            _ = try await session.start(configuration: configuration())
            Issue.record("start unexpectedly succeeded for \(failurePoint)")
        } catch let error as AudioCaptureError {
            #expect(error == expectedError)
            #expect(log.events() == expectedEvents, "\(failurePoint) events: \(log.events())")
        } catch {
            Issue.record("unexpected error for \(failurePoint): \(error)")
        }
    }
}

@Test("CaptureSession successful start and repeat stop keep reverse teardown idempotent")
func captureSessionSuccessfulStartAndRepeatStopAreIdempotent() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(log: log))

    let result = try await session.start(configuration: configuration())

    #expect(result.aggregateSampleRate == 48_000)
    #expect(result.channelMap == micOnlyChannelMap)
    #expect(log.events() == [
        .permission,
        .resolveMicrophone,
        .diskPreflight,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart
    ])

    let first = try await session.stop()
    let second = try await session.stop()

    #expect(first.url == second.url)
    #expect(first.duration == second.duration)
    #expect(first.sampleRate == second.sampleRate)
    #expect(first.channelCount == second.channelCount)
    #expect(log.events() == [
        .permission,
        .resolveMicrophone,
        .diskPreflight,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart,
        .listenerRemove,
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy
    ])
}

@Test("CaptureSession start stop start stop removes both listener registrations")
func captureSessionRestartRemovesBothListenerRegistrations() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(log: log))

    _ = try await session.start(configuration: configuration())
    _ = try await session.stop()
    _ = try await session.start(configuration: configuration())
    _ = try await session.stop()

    #expect(log.events().filter { $0 == .listenerRegister }.count == 2)
    #expect(log.events().filter { $0 == .listenerRemove }.count == 2)
    #expect(log.events().suffix(7) == [
        .writerStart,
        .ioProcCreate,
        .deviceStart,
        .listenerRemove,
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy
    ].suffix(7))
}

@Test("CaptureSession system-only starts without microphone permission or microphone resolution")
func captureSessionSystemOnlyUsesOutputTapAggregateAndSharedStartup() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(log: log))

    let result = try await session.start(configuration: configuration(mode: .systemOnly))

    #expect(result.aggregateSampleRate == 48_000)
    #expect(result.channelMap.microphoneChannels == [])
    #expect(result.channelMap.systemChannels == [0, 1])
    #expect(result.warnings.isEmpty)
    #expect(log.events() == [
        .resolveOutput,
        .resolveProcessObject,
        .diskPreflight,
        .tapCreate,
        .tapFormatRead,
        .aggregateCreate,
        .writerMake,
        .listenerRegister,
        .writerStart,
        .ioProcCreate,
        .deviceStart
    ])

    _ = try await session.stop()
    #expect(log.events().suffix(7) == [
        .listenerRemove,
        .deviceStop,
        .ioProcDestroy,
        .writerRequestStop,
        .writerJoin,
        .aggregateDestroy,
        .tapDestroy
    ])
}


@Test("CaptureSession system-only continues when self process object is unavailable")
func captureSessionSystemOnlyContinuesWhenSelfProcessIsUnavailable() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        processObjects: FakeProcessObjectResolver(log: log, failurePoint: nil, processObjectID: nil)
    ))

    let start = try await session.start(configuration: configuration(mode: .systemOnly))
    #expect(start.warnings == [AudioCaptureWarning.selfExclusionUnavailable])

    let output = try await session.stop()
    #expect(output.warnings == [AudioCaptureWarning.selfExclusionUnavailable, .systemAudioWasSilent])
}

@Test("CaptureSession system-only unwinds each injected startup failure in acquisition order")
func captureSessionSystemOnlyUnwindsEveryInjectedStartupFailure() async throws {
    let cases: [(StartFailurePoint, [LifecycleEvent], AudioCaptureError)] = [
        (.processLookup, [.resolveOutput, .resolveProcessObject], .deviceDisconnected),
        (.tapCreate, [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate], .tapCreationFailed(-50)),
        (
            .tapFormatRead,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .tapDestroy],
            .unsupportedStreamFormat(nil)
        ),
        (
            .aggregateCreate,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .aggregateCreate, .tapDestroy],
            .aggregateCreationFailed(-50)
        ),
        (
            .listenerRegister,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .aggregateCreate,
             .writerMake, .listenerRegister, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy],
            .deviceDisconnected
        ),
        (
            .writerStart,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .aggregateCreate,
             .writerMake, .listenerRegister, .writerStart, .listenerRemove, .writerRequestStop, .writerJoin,
             .aggregateDestroy, .tapDestroy],
            .fileWriteFailed("synthetic start failure")
        ),
        (
            .ioProcCreate,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .aggregateCreate,
             .writerMake, .listenerRegister, .writerStart, .ioProcCreate, .listenerRemove, .writerRequestStop,
             .writerJoin, .aggregateDestroy, .tapDestroy],
            .ioProcCreationFailed(-50)
        ),
        (
            .deviceStart,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .aggregateCreate,
             .writerMake, .listenerRegister, .writerStart, .ioProcCreate, .deviceStart, .listenerRemove,
             .ioProcDestroy, .writerRequestStop, .writerJoin, .aggregateDestroy, .tapDestroy],
            .startFailed(-50)
        )
    ]

    for (failurePoint, expectedEvents, expectedError) in cases {
        let log = LifecycleLog()
        let session = CaptureSession(dependencies: .fake(log: log, failurePoint: failurePoint))

        do {
            _ = try await session.start(configuration: configuration(mode: .systemOnly))
            Issue.record("start unexpectedly succeeded for \(failurePoint)")
        } catch let error as AudioCaptureError {
            #expect(error == expectedError)
            #expect(log.events() == expectedEvents, "\(failurePoint) events: \(log.events())")
        } catch {
            Issue.record("unexpected error for \(failurePoint): \(error)")
        }
    }
}

@Test("CaptureSession keeps failed system-only resources until retained cleanup succeeds")
func captureSessionSystemOnlyRetainsCleanupAfterUnwindFailureAndRejectsRestart() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        failurePoint: .tapFormatRead,
        teardownFailures: LifecycleFailurePlan([.tapDestroy])
    ))

    do {
        _ = try await session.start(configuration: configuration(mode: .systemOnly))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(log.events() == [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .tapDestroy])
    } catch {
        Issue.record("unexpected start error: \(error)")
    }

    do {
        _ = try await session.start(configuration: configuration(mode: .systemOnly))
        Issue.record("restart unexpectedly succeeded while cleanup was retained")
    } catch AudioCaptureError.fileWriteFailed("Capture session already started") {
    } catch {
        Issue.record("unexpected restart error: \(error)")
    }

    do {
        _ = try await session.stop()
        Issue.record("cleanup stop unexpectedly returned output")
    } catch AudioCaptureError.unsupportedStreamFormat(nil) {
        #expect(log.events().suffix(2) == [.tapDestroy, .tapDestroy])
    } catch {
        Issue.record("unexpected cleanup error: \(error)")
    }
}

@Test("CaptureSession maps system-only permission status only in system start paths")
func captureSessionMapsPermissionStatusByModeAndOperation() async throws {
    let tapLog = LifecycleLog()
    let tapSession = CaptureSession(dependencies: .fake(
        log: tapLog,
        systemTapFactory: PermissionDeniedTapFactory(log: tapLog)
    ))
    do {
        _ = try await tapSession.start(configuration: configuration(mode: .systemOnly))
        Issue.record("system-only tap creation unexpectedly succeeded")
    } catch AudioCaptureError.systemAudioPermissionDenied {
        #expect(tapLog.events() == [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate])
    } catch {
        Issue.record("unexpected system-only tap error: \(error)")
    }

    let systemLog = LifecycleLog()
    let systemSession = CaptureSession(dependencies: .fake(
        log: systemLog,
        ioProcManager: PermissionDeniedIOProcManager(log: systemLog)
    ))
    do {
        _ = try await systemSession.start(configuration: configuration(mode: .systemOnly))
        Issue.record("system-only start unexpectedly succeeded")
    } catch AudioCaptureError.systemAudioPermissionDenied {
        #expect(systemLog.events().contains(.deviceStart))
    } catch {
        Issue.record("unexpected system-only error: \(error)")
    }

    let micLog = LifecycleLog()
    let micSession = CaptureSession(dependencies: .fake(
        log: micLog,
        ioProcManager: PermissionDeniedIOProcManager(log: micLog)
    ))
    do {
        _ = try await micSession.start(configuration: configuration())
        Issue.record("mic-only start unexpectedly succeeded")
    } catch AudioCaptureError.startFailed(kAudioDevicePermissionsError) {
        #expect(micLog.events().contains(.deviceStart))
    } catch {
        Issue.record("unexpected mic-only error: \(error)")
    }
}

@Test("CaptureSession propagates system start warnings to final output without duplicating writer warnings")
func captureSessionSystemOnlyMergesStartWriterAndSilentWarnings() async throws {
    let log = LifecycleLog()
    let session = CaptureSession(dependencies: .fake(
        log: log,
        writerFactory: CapturingSessionWriterFactory(
            log: log,
            warnings: [.framesDropped(4)],
            systemPeak: 0
        ),
        systemTapFactory: FakeSystemAudioTapFactory(
            log: log,
            failurePoint: nil,
            teardownFailures: LifecycleFailurePlan(),
            warnings: [.selfExclusionUnavailable]
        )
    ))

    let start = try await session.start(configuration: configuration(mode: .systemOnly))
    #expect(start.warnings == [AudioCaptureWarning.selfExclusionUnavailable])

    let output = try await session.stop()
    #expect(output.warnings == [AudioCaptureWarning.selfExclusionUnavailable, .framesDropped(4), .systemAudioWasSilent])
}

@Test("CaptureSession never deletes preexisting configured output before writer start")
func captureSessionNeverDeletesPreexistingOutputBeforeWriterStart() async throws {
    let cases: [(String, CaptureMode, Bool, StartFailurePoint?, [LifecycleEvent])] = [
        ("mic and system process lookup failure", .micAndSystem, true, .processLookup, [
            .permission,
            .resolveMicrophone,
            .resolveOutput,
            .resolveProcessObject
        ]),
        ("mic permission denial", .micOnly, false, nil, [.permission]),
        ("process lookup failure", .systemOnly, true, .processLookup, [.resolveOutput, .resolveProcessObject]),
        ("tap create failure", .systemOnly, true, .tapCreate, [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate]),
        (
            "tap format failure",
            .systemOnly,
            true,
            .tapFormatRead,
            [.resolveOutput, .resolveProcessObject, .diskPreflight, .tapCreate, .tapFormatRead, .tapDestroy]
        )
    ]

    for (name, mode, permissionGranted, failurePoint, expectedEvents) in cases {
        let output = try temporaryCleanupOutput()
        let preexistingBytes = Data([0x00, 0x7f, 0x80, 0xff])
        let priorBytes = Data([0xde, 0xad, 0xbe, 0xef])
        try preexistingBytes.write(to: output.attemptURL)
        try priorBytes.write(to: output.priorURL)
        defer { try? FileManager.default.removeItem(at: output.directory) }
        let session = CaptureSession(dependencies: .fake(
            log: output.log,
            permissionGranted: permissionGranted,
            failurePoint: failurePoint
        ))

        do {
            _ = try await session.start(configuration: cleanupConfiguration(mode: mode, outputURL: output.attemptURL))
            Issue.record("start unexpectedly succeeded for \(name)")
        } catch {
            #expect(FileManager.default.fileExists(atPath: output.attemptURL.path), "preexisting output deleted for \(name)")
            #expect(FileManager.default.fileExists(atPath: output.priorURL.path), "prior file deleted for \(name)")
            #expect(try Data(contentsOf: output.attemptURL) == preexistingBytes, "preexisting bytes changed for \(name)")
            #expect(try Data(contentsOf: output.priorURL) == priorBytes, "prior bytes changed for \(name)")
            #expect(output.log.events() == expectedEvents, "events for \(name): \(output.log.events())")
        }
    }
}

@Test("CaptureSession deletes only attempt-owned output created by writer start after successful cleanup")
func captureSessionDeletesOnlyAttemptOwnedOutputAfterSuccessfulCleanup() async throws {
    let output = try temporaryCleanupOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let priorBytes = Data([0xca, 0xfe, 0xba, 0xbe])
    try priorBytes.write(to: output.priorURL)
    #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))

    let session = CaptureSession(dependencies: .fake(
        log: output.log,
        failurePoint: .ioProcCreate,
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true)
    ))

    do {
        _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.ioProcCreationFailed(-50) {
        #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))
        #expect(FileManager.default.fileExists(atPath: output.priorURL.path))
        #expect(try Data(contentsOf: output.priorURL) == priorBytes)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("CaptureSession writer collision preserves exact preexisting output bytes")
func captureSessionWriterCollisionPreservesExactPreexistingOutputBytes() async throws {
    let output = try temporaryCleanupOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let preexistingBytes = Data([0x00, 0x11, 0x80, 0xfe, 0xff])
    let priorBytes = Data([0xca, 0xfe, 0xba, 0xbe])
    try preexistingBytes.write(to: output.attemptURL)
    try priorBytes.write(to: output.priorURL)

    let session = CaptureSession(dependencies: .fake(
        log: output.log,
        failurePoint: .ioProcCreate,
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true)
    ))

    do {
        _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.outputAlreadyExists(let path) {
        #expect(path == output.attemptURL.path)
        #expect(FileManager.default.fileExists(atPath: output.attemptURL.path))
        #expect(FileManager.default.fileExists(atPath: output.priorURL.path))
        #expect(try Data(contentsOf: output.attemptURL) == preexistingBytes)
        #expect(try Data(contentsOf: output.priorURL) == priorBytes)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("CaptureSession output collision never deletes a foreign entry created after its ownership probe")
func captureSessionOutputCollisionNeverDeletesForeignEntryCreatedAfterOwnershipProbe() async throws {
    let output = try temporaryCleanupOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let foreignBytes = Data([0xf0, 0x0d, 0xba, 0xbe])
    #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))

    let session = CaptureSession(dependencies: .fake(
        log: output.log,
        writerFactory: CapturingSessionWriterFactory(
            log: output.log,
            createsOutputOnStart: true,
            onStart: { _, outputURL in
                try? foreignBytes.write(to: outputURL, options: .withoutOverwriting)
            }
        )
    ))

    do {
        _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.outputAlreadyExists(let path) {
        #expect(path == output.attemptURL.path)
        #expect(try Data(contentsOf: output.attemptURL) == foreignBytes)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("CaptureSession defers deleting attempt-owned output until retained cleanup succeeds")
func captureSessionDefersAttemptOutputDeletionUntilRetainedCleanupSucceeds() async throws {
    let output = try temporaryCleanupOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let priorBytes = Data([0x10, 0x32, 0x54, 0x76, 0x98])
    try priorBytes.write(to: output.priorURL)

    let session = CaptureSession(dependencies: .fake(
        log: output.log,
        failurePoint: .ioProcCreate,
        teardownFailures: LifecycleFailurePlan([.tapDestroy]),
        writerFactory: CapturingSessionWriterFactory(log: output.log, createsOutputOnStart: true)
    ))

    do {
        _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("start unexpectedly succeeded")
    } catch AudioCaptureError.ioProcCreationFailed(-50) {
        #expect(FileManager.default.fileExists(atPath: output.attemptURL.path))
        #expect(FileManager.default.fileExists(atPath: output.priorURL.path))
        #expect(try Data(contentsOf: output.priorURL) == priorBytes)
    } catch {
        Issue.record("unexpected start error: \(error)")
    }

    do {
        _ = try await session.stop()
        Issue.record("cleanup stop unexpectedly returned output")
    } catch AudioCaptureError.ioProcCreationFailed(-50) {
        #expect(!FileManager.default.fileExists(atPath: output.attemptURL.path))
        #expect(FileManager.default.fileExists(atPath: output.priorURL.path))
        #expect(try Data(contentsOf: output.priorURL) == priorBytes)
    } catch {
        Issue.record("unexpected cleanup error: \(error)")
    }
}

@Test("CaptureSession clears writer whose startup failure is also its terminal join error")
func captureSessionClearsWriterAfterMatchingStartupAndJoinFailure() async throws {
    let output = try temporaryCleanupOutput()
    defer { try? FileManager.default.removeItem(at: output.directory) }
    let session = CaptureSession(dependencies: .fake(
        log: output.log,
        writerFactory: CapturingSessionWriterFactory(log: output.log, failFirstStart: true, createsOutputOnStart: true)
    ))

    do {
        _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
        Issue.record("first start unexpectedly succeeded")
    } catch AudioCaptureError.fileWriteFailed("synthetic start failure") {
        #expect(FileManager.default.fileExists(atPath: output.attemptURL.path))
    } catch {
        Issue.record("unexpected first start error: \(error)")
    }

    try FileManager.default.removeItem(at: output.attemptURL)

    _ = try await session.start(configuration: cleanupConfiguration(mode: .systemOnly, outputURL: output.attemptURL))
    _ = try await session.stop()
}

private struct CleanupOutput {
    let directory: URL
    let attemptURL: URL
    let priorURL: URL
    let log: LifecycleLog
}

private func temporaryCleanupOutput() throws -> CleanupOutput {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return CleanupOutput(
        directory: directory,
        attemptURL: directory.appendingPathComponent("attempt.m4a"),
        priorURL: directory.appendingPathComponent("prior-success.m4a"),
        log: LifecycleLog()
    )
}

private func cleanupConfiguration(mode: CaptureMode, outputURL: URL) -> RecordingConfiguration {
    RecordingConfiguration(
        mode: mode,
        microphoneUID: mode == .micOnly ? "mic-uid" : nil,
        outputURL: outputURL,
        microphoneGain: 1,
        systemGain: 1
    )
}
