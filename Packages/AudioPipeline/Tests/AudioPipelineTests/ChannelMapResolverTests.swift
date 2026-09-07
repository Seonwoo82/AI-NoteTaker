import AudioPipeline
import Testing

@Test("Channel map resolver maps mono microphone before stereo tap in H1 order")
func channelMapResolverMapsMonoMicrophoneBeforeStereoTapInH1Order() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone, name: "Built-in Microphone"),
            descriptor(bufferIndex: 1, startingChannelIndex: 1, channelCount: 2, name: "System Tap")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone, name: "Built-in Microphone")],
        tapChannelCount: 2
    )

    #expect(map == InputChannelMap(
        microphoneChannels: [0],
        systemChannels: [1, 2],
        bufferLayout: [
            InputBufferLayout(bufferIndex: 0, channelCount: 1),
            InputBufferLayout(bufferIndex: 1, channelCount: 2)
        ],
        confidence: .terminalType
    ))
}

@Test("Channel map resolver maps stereo microphone before stereo tap in H1 order")
func channelMapResolverMapsStereoMicrophoneBeforeStereoTapInH1Order() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .headset, name: "USB Headset"),
            descriptor(bufferIndex: 1, startingChannelIndex: 2, channelCount: 2, name: "Process Tap")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .headset, name: "USB Headset")],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [0, 1])
    #expect(map.systemChannels == [2, 3])
    #expect(map.confidence == .terminalType)
}

@Test("Channel map resolver maps explicit H2 order with stereo tap before microphone")
func channelMapResolverMapsExplicitH2OrderWithStereoTapBeforeMicrophone() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 2, name: "Output Tap"),
            descriptor(bufferIndex: 1, startingChannelIndex: 2, channelCount: 1, terminalType: .microphone, name: "Studio Mic")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone, name: "Studio Mic")],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [2])
    #expect(map.systemChannels == [0, 1])
    #expect(map.confidence == .terminalType)
}

@Test("Channel map resolver uses terminal type to disambiguate line input microphone")
func channelMapResolverUsesTerminalTypeToDisambiguateLineInputMicrophone() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .line, name: "Line Input"),
            descriptor(bufferIndex: 1, startingChannelIndex: 2, channelCount: 2, name: "System Audio")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .line, name: "Line Input")],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [0, 1])
    #expect(map.systemChannels == [2, 3])
    #expect(map.confidence == .terminalType)
}

@Test("Channel map resolver uses case insensitive tap stream name to disambiguate")
func channelMapResolverUsesCaseInsensitiveTapStreamNameToDisambiguate() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 2, name: "PROCESS TaP"),
            descriptor(bufferIndex: 1, startingChannelIndex: 2, channelCount: 1, terminalType: .unknown, name: "Input Stream")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .unknown, name: "Input Stream")],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [2])
    #expect(map.systemChannels == [0, 1])
    #expect(map.confidence == .streamName)
}

@Test("Channel map resolver assumes H1 order when mixed streams are ambiguous")
func channelMapResolverAssumesH1OrderWhenMixedStreamsAreAmbiguous() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [
            descriptor(startingChannelIndex: 0, channelCount: 1, name: "Input"),
            descriptor(bufferIndex: 1, startingChannelIndex: 1, channelCount: 2, name: "Output")
        ],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .unknown, name: "Input")],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [0])
    #expect(map.systemChannels == [1, 2])
    #expect(map.confidence == .assumedMicThenTap)
}

@Test("Channel map resolver rejects empty aggregate streams")
func channelMapResolverRejectsEmptyAggregateStreams() {
    #expect(throws: ChannelMapError.emptyStreams) {
        try ChannelMapResolver.resolve(aggregateStreams: [], microphoneStreams: [], tapChannelCount: 0)
    }
}

@Test("Channel map resolver rejects gaps between aggregate streams")
func channelMapResolverRejectsGapsBetweenAggregateStreams() {
    #expect(throws: ChannelMapError.nonContiguousChannels) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [
                descriptor(startingChannelIndex: 0, channelCount: 1),
                descriptor(bufferIndex: 1, startingChannelIndex: 2, channelCount: 2)
            ],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1)],
            tapChannelCount: 2
        )
    }
}

@Test("Channel map resolver rejects overlapping aggregate streams")
func channelMapResolverRejectsOverlappingAggregateStreams() {
    #expect(throws: ChannelMapError.nonContiguousChannels) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [
                descriptor(startingChannelIndex: 0, channelCount: 2),
                descriptor(bufferIndex: 1, startingChannelIndex: 1, channelCount: 2)
            ],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 2)],
            tapChannelCount: 2
        )
    }
}

@Test("Channel map resolver rejects total channel count mismatch")
func channelMapResolverRejectsTotalChannelCountMismatch() {
    #expect(throws: ChannelMapError.aggregateChannelCountMismatch(expected: 4, actual: 3)) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [
                descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone),
                descriptor(bufferIndex: 1, startingChannelIndex: 1, channelCount: 2, name: "Tap")
            ],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 2)],
            tapChannelCount: 2
        )
    }
}

@Test("Channel map resolver rejects three channel microphones")
func channelMapResolverRejectsThreeChannelMicrophones() {
    #expect(throws: ChannelMapError.unsupportedMicrophoneChannelCount(3)) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [descriptor(startingChannelIndex: 0, channelCount: 3, terminalType: .microphone)],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 3, terminalType: .microphone)],
            tapChannelCount: 0
        )
    }
}

@Test("Channel map resolver rejects non-empty zero channel microphone descriptors")
func channelMapResolverRejectsNonEmptyZeroChannelMicrophoneDescriptors() {
    #expect(throws: ChannelMapError.unsupportedMicrophoneChannelCount(0)) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, name: "Tap")],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 0, terminalType: .microphone)],
            tapChannelCount: 2
        )
    }
}

@Test("Channel map resolver rejects non stereo taps")
func channelMapResolverRejectsNonStereoTaps() {
    #expect(throws: ChannelMapError.unsupportedTapChannelCount(1)) {
        try ChannelMapResolver.resolve(
            aggregateStreams: [
                descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone),
                descriptor(bufferIndex: 1, startingChannelIndex: 1, channelCount: 1, name: "Tap")
            ],
            microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone)],
            tapChannelCount: 1
        )
    }
}

@Test("Channel map resolver maps mic only mono without system channels")
func channelMapResolverMapsMicOnlyMonoWithoutSystemChannels() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone)],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 1, terminalType: .microphone)],
        tapChannelCount: 0
    )

    #expect(map.microphoneChannels == [0])
    #expect(map.systemChannels == [])
    #expect(map.confidence == .terminalType)
}

@Test("Channel map resolver maps mic only stereo without system channels")
func channelMapResolverMapsMicOnlyStereoWithoutSystemChannels() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .headset)],
        microphoneStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, terminalType: .headset)],
        tapChannelCount: 0
    )

    #expect(map.microphoneChannels == [0, 1])
    #expect(map.systemChannels == [])
    #expect(map.confidence == .terminalType)
}

@Test("Channel map resolver maps system only stereo tap without microphone channels")
func channelMapResolverMapsSystemOnlyStereoTapWithoutMicrophoneChannels() throws {
    let map = try ChannelMapResolver.resolve(
        aggregateStreams: [descriptor(startingChannelIndex: 0, channelCount: 2, name: "Tap")],
        microphoneStreams: [],
        tapChannelCount: 2
    )

    #expect(map.microphoneChannels == [])
    #expect(map.systemChannels == [0, 1])
    #expect(map.bufferLayout == [InputBufferLayout(bufferIndex: 0, channelCount: 2)])
    #expect(map.confidence == .streamName)
}

private func descriptor(
    bufferIndex: Int = 0,
    startingChannelIndex: Int,
    channelCount: Int,
    terminalType: InputTerminalType = .unknown,
    name: String = "Stream"
) -> InputStreamDescriptor {
    InputStreamDescriptor(
        bufferIndex: bufferIndex,
        startingChannelIndex: startingChannelIndex,
        channelCount: channelCount,
        terminalType: terminalType,
        name: name
    )
}
