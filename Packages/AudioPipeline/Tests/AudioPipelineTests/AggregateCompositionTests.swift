import AudioPipeline
import CoreAudio
import Foundation
import Testing

@Test("Aggregate composition models mic only with private unstacked microphone subdevice")
func aggregateCompositionModelsMicOnlyWithPrivateUnstackedMicrophoneSubdevice() throws {
    let composition = try AggregateComposition(
        mode: .micOnly,
        microphoneUID: "mic-uid",
        outputUID: nil,
        tapUID: nil
    )

    #expect(composition.mode == .micOnly)
    #expect(composition.clockSource == .microphone)
    #expect(composition.mainSubDeviceUID == "mic-uid")
    #expect(composition.subDevices == [AggregateSubDevice(uid: "mic-uid", driftCompensation: true)])
    #expect(composition.tapUID == nil)
    #expect(composition.tapAutoStart == false)

    let hal = composition.makeHALProperties(name: "NoteTaker Aggregate", uid: "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceNameKey] as? String == "NoteTaker Aggregate")
    #expect(hal[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceMainSubDeviceKey] as? String == "mic-uid")
    #expect(hal[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
    #expect(hal[kAudioAggregateDeviceIsStackedKey] as? Bool == false)
    #expect(hal[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
    #expect(hal[kAudioAggregateDeviceTapListKey] == nil)
    expectSubDevices(hal, equal: [["uid": "mic-uid", "drift": true]])
}

@Test("Aggregate composition models mic and system with microphone clock")
func aggregateCompositionModelsMicAndSystemWithMicrophoneClock() throws {
    let tapID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let composition = try AggregateComposition(
        mode: .micAndSystem,
        microphoneUID: "mic-uid",
        outputUID: "output-uid",
        tapUID: tapID
    )

    #expect(composition.mode == .micAndSystem)
    #expect(composition.clockSource == .microphone)
    #expect(composition.mainSubDeviceUID == "mic-uid")
    #expect(composition.subDevices == [AggregateSubDevice(uid: "mic-uid", driftCompensation: true)])
    #expect(composition.tapUID == tapID)
    #expect(composition.tapAutoStart == false)

    let hal = composition.makeHALProperties(name: "Aggregate", uid: "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceMainSubDeviceKey] as? String == "mic-uid")
    #expect(hal[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
    expectSubDevices(hal, equal: [["uid": "mic-uid", "drift": true]])
    expectTaps(hal, equal: [["uid": tapID.uuidString, "drift": true]])
}

@Test("Aggregate composition models mic and system with output clock")
func aggregateCompositionModelsMicAndSystemWithOutputClock() throws {
    let tapID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let composition = try AggregateComposition(
        mode: .micAndSystem,
        microphoneUID: "mic-uid",
        outputUID: "output-uid",
        tapUID: tapID,
        clockSource: .output
    )

    #expect(composition.clockSource == .output)
    #expect(composition.mainSubDeviceUID == "output-uid")
    #expect(composition.subDevices == [
        AggregateSubDevice(uid: "output-uid", driftCompensation: false),
        AggregateSubDevice(uid: "mic-uid", driftCompensation: true)
    ])
    #expect(composition.tapUID == tapID)
    #expect(composition.tapAutoStart == false)

    let hal = composition.makeHALProperties(name: "Aggregate", uid: "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceMainSubDeviceKey] as? String == "output-uid")
    #expect(hal[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
    expectSubDevices(hal, equal: [
        ["uid": "output-uid", "drift": false],
        ["uid": "mic-uid", "drift": true]
    ])
    expectTaps(hal, equal: [["uid": tapID.uuidString, "drift": true]])
}

@Test("Aggregate composition models system only with output clock and autostarting tap")
func aggregateCompositionModelsSystemOnlyWithOutputClockAndAutostartingTap() throws {
    let tapID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let composition = try AggregateComposition(
        mode: .systemOnly,
        microphoneUID: nil,
        outputUID: "output-uid",
        tapUID: tapID
    )

    #expect(composition.mode == .systemOnly)
    #expect(composition.clockSource == .output)
    #expect(composition.mainSubDeviceUID == "output-uid")
    #expect(composition.subDevices == [AggregateSubDevice(uid: "output-uid", driftCompensation: false)])
    #expect(composition.tapUID == tapID)
    #expect(composition.tapAutoStart == true)

    let hal = composition.makeHALProperties(name: "Aggregate", uid: "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceNameKey] as? String == "Aggregate")
    #expect(hal[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
    #expect(hal[kAudioAggregateDeviceMainSubDeviceKey] as? String == "output-uid")
    #expect(hal[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
    #expect(hal[kAudioAggregateDeviceIsStackedKey] as? Bool == false)
    #expect(hal[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
    expectSubDevices(hal, equal: [["uid": "output-uid", "drift": false]])
    expectTaps(hal, equal: [["uid": tapID.uuidString, "drift": true]])
}

@Test("Aggregate composition throws exact errors for missing required identifiers")
func aggregateCompositionThrowsExactErrorsForMissingRequiredIdentifiers() {
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micOnly, microphoneUID: nil, outputUID: nil, tapUID: nil)
    }
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micOnly, microphoneUID: "", outputUID: nil, tapUID: nil)
    }
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micOnly, microphoneUID: " \t\n", outputUID: nil, tapUID: nil)
    }
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: nil, outputUID: "output", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: "", outputUID: "output", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingMicrophoneUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: " \t\n", outputUID: "output", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: "mic", outputUID: nil, tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: "mic", outputUID: "", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: "mic", outputUID: " \t\n", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingTapUID) {
        try AggregateComposition(mode: .micAndSystem, microphoneUID: "mic", outputUID: "output", tapUID: nil)
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .systemOnly, microphoneUID: nil, outputUID: nil, tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .systemOnly, microphoneUID: nil, outputUID: "", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingOutputUID) {
        try AggregateComposition(mode: .systemOnly, microphoneUID: nil, outputUID: " \t\n", tapUID: UUID())
    }
    #expect(throws: AggregateCompositionError.missingTapUID) {
        try AggregateComposition(mode: .systemOnly, microphoneUID: nil, outputUID: "output", tapUID: nil)
    }
}

private func expectSubDevices(
    _ hal: [String: Any],
    equal expected: [[String: AnyHashable]],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let subDevices = hal[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
    #expect(subDevices?.count == expected.count, sourceLocation: sourceLocation)
    for index in 0..<expected.count {
        #expect(subDevices?[index][kAudioSubDeviceUIDKey] as? String == expected[index]["uid"] as? String, sourceLocation: sourceLocation)
        #expect(subDevices?[index][kAudioSubDeviceDriftCompensationKey] as? Bool == expected[index]["drift"] as? Bool, sourceLocation: sourceLocation)
    }
}

private func expectTaps(
    _ hal: [String: Any],
    equal expected: [[String: AnyHashable]],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let taps = hal[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
    #expect(taps?.count == expected.count, sourceLocation: sourceLocation)
    for index in 0..<expected.count {
        #expect(taps?[index][kAudioSubTapUIDKey] as? String == expected[index]["uid"] as? String, sourceLocation: sourceLocation)
        #expect(taps?[index][kAudioSubTapDriftCompensationKey] as? Bool == expected[index]["drift"] as? Bool, sourceLocation: sourceLocation)
    }
}
