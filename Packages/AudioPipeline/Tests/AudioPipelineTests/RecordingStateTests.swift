import Foundation
import Testing
import AudioPipeline

@Test("recording state follows the legal start pause resume finish flow")
func recordingStateFollowsLegalFlow() throws {
    let identity = RecordingIdentity(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        startedAt: Date(timeIntervalSince1970: 4)
    )

    let recording = try RecordingState.idle.applying(.start(identity))
    #expect(recording == .recording(identity))

    let paused = try recording.applying(.pause)
    #expect(paused == .paused(identity))

    let resumed = try paused.applying(.resume)
    #expect(resumed == .recording(identity))

    let finishing = try resumed.applying(.finish)
    #expect(finishing == .finishing(identity))

    let finished = try finishing.applying(.finished)
    #expect(finished == .idle)
}

@Test("recording state preserves identity through pause resume and finish")
func recordingStatePreservesIdentity() throws {
    let identity = RecordingIdentity(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111114")!,
        startedAt: Date(timeIntervalSince1970: 44)
    )

    let paused = try RecordingState.idle
        .applying(.start(identity))
        .applying(.pause)
    let resumed = try paused.applying(.resume)
    let finishing = try resumed.applying(.finish)

    #expect(paused == .paused(identity))
    #expect(resumed == .recording(identity))
    #expect(finishing == .finishing(identity))
}

@Test("active recording states may fail and failed state resets to idle")
func activeRecordingStatesMayFailAndReset() throws {
    let identity = RecordingIdentity(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222224")!,
        startedAt: Date(timeIntervalSince1970: 444)
    )

    let recordingFailed = try RecordingState.idle
        .applying(.start(identity))
        .applying(.fail("microphone denied"))
    #expect(recordingFailed == .failed("microphone denied"))
    #expect(try recordingFailed.applying(.reset) == .idle)

    let pausedFailed = try RecordingState.idle
        .applying(.start(identity))
        .applying(.pause)
        .applying(.fail("device disconnected"))
    #expect(pausedFailed == .failed("device disconnected"))

    let finishingFailed = try RecordingState.idle
        .applying(.start(identity))
        .applying(.finish)
        .applying(.fail("write failed"))
    #expect(finishingFailed == .failed("write failed"))
}

@Test("invalid recording transitions throw the exact state and event")
func invalidRecordingTransitionsThrowExactError() throws {
    let identity = RecordingIdentity(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333334")!,
        startedAt: Date(timeIntervalSince1970: 4_444)
    )

    try expectInvalidTransition(from: .idle, event: .finish)
    try expectInvalidTransition(from: .recording(identity), event: .start(identity))
    try expectInvalidTransition(from: .finishing(identity), event: .pause)
    try expectInvalidTransition(from: .failed("boom"), event: .resume)
}

@Test("every non-legal recording state and event pair throws the exact invalid transition")
func everyNonLegalRecordingStateEventPairThrowsExactInvalidTransition() throws {
    let identity = RecordingIdentity(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        startedAt: Date(timeIntervalSince1970: 44_444)
    )
    let otherIdentity = RecordingIdentity(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        startedAt: Date(timeIntervalSince1970: 55_555)
    )

    let states: [(label: String, value: RecordingState)] = [
        ("idle", .idle),
        ("recording", .recording(identity)),
        ("paused", .paused(identity)),
        ("finishing", .finishing(identity)),
        ("failed", .failed("boom"))
    ]
    let events: [(label: String, value: RecordingEvent)] = [
        ("start", .start(otherIdentity)),
        ("pause", .pause),
        ("resume", .resume),
        ("finish", .finish),
        ("finished", .finished),
        ("fail", .fail("network lost")),
        ("reset", .reset)
    ]

    let legalPairs = Set([
        "idle|start",
        "recording|pause",
        "recording|finish",
        "recording|fail",
        "paused|resume",
        "paused|finish",
        "paused|fail",
        "finishing|finished",
        "finishing|fail",
        "failed|reset"
    ])

    for state in states {
        for event in events {
            let pair = "\(state.label)|\(event.label)"
            guard !legalPairs.contains(pair) else { continue }

            try expectInvalidTransition(
                from: state.value,
                event: event.value,
                label: pair
            )
        }
    }
}

private func expectInvalidTransition(
    from state: RecordingState,
    event: RecordingEvent,
    label: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    do {
        _ = try state.applying(event)
        Issue.record(
            "Expected invalid transition error\(label.map { " for \($0)" } ?? "")",
            sourceLocation: sourceLocation
        )
    } catch let error as RecordingStateError {
        #expect(
            error == .invalidTransition(from: state, event: event),
            "\(label ?? "transition") should throw exact invalid transition",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}
