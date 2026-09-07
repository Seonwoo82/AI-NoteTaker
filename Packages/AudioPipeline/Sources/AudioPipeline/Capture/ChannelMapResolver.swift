public enum InputTerminalType: Equatable, Sendable {
    case microphone
    case headset
    case line
    case unknown
}

public struct InputStreamDescriptor: Equatable, Sendable {
    public let bufferIndex: Int
    public let startingChannelIndex: Int
    public let channelCount: Int
    public let terminalType: InputTerminalType
    public let name: String

    public init(
        bufferIndex: Int,
        startingChannelIndex: Int,
        channelCount: Int,
        terminalType: InputTerminalType,
        name: String
    ) {
        self.bufferIndex = bufferIndex
        self.startingChannelIndex = startingChannelIndex
        self.channelCount = channelCount
        self.terminalType = terminalType
        self.name = name
    }
}

public struct InputBufferLayout: Equatable, Sendable {
    public let bufferIndex: Int
    public let channelCount: Int

    public init(bufferIndex: Int, channelCount: Int) {
        self.bufferIndex = bufferIndex
        self.channelCount = channelCount
    }
}

public enum ChannelMapConfidence: Equatable, Sendable {
    case terminalType
    case streamName
    case assumedMicThenTap
}

public struct InputChannelMap: Equatable, Sendable {
    public let microphoneChannels: [Int]
    public let systemChannels: [Int]
    public let bufferLayout: [InputBufferLayout]
    public let confidence: ChannelMapConfidence

    public init(
        microphoneChannels: [Int],
        systemChannels: [Int],
        bufferLayout: [InputBufferLayout],
        confidence: ChannelMapConfidence
    ) {
        self.microphoneChannels = microphoneChannels
        self.systemChannels = systemChannels
        self.bufferLayout = bufferLayout
        self.confidence = confidence
    }
}

public enum ChannelMapError: Error, Equatable, Sendable {
    case emptyStreams
    case nonContiguousChannels
    case aggregateChannelCountMismatch(expected: Int, actual: Int)
    case unsupportedMicrophoneChannelCount(Int)
    case unsupportedTapChannelCount(Int)
}

public enum ChannelMapResolver {
    public static func resolve(
        aggregateStreams: [InputStreamDescriptor],
        inputBufferChannelCounts: [Int]? = nil,
        microphoneStreams: [InputStreamDescriptor],
        tapChannelCount: Int
    ) throws -> InputChannelMap {
        guard !aggregateStreams.isEmpty else {
            throw ChannelMapError.emptyStreams
        }

        let actualChannelCount = try contiguousChannelCount(for: aggregateStreams)
        let bufferLayout = makeBufferLayout(
            aggregateStreams: aggregateStreams,
            inputBufferChannelCounts: inputBufferChannelCounts
        )
        let bufferChannelCount = bufferLayout.reduce(0) { $0 + $1.channelCount }
        guard bufferChannelCount == actualChannelCount else {
            throw ChannelMapError.aggregateChannelCountMismatch(
                expected: actualChannelCount,
                actual: bufferChannelCount
            )
        }
        try validateMicrophoneStreams(microphoneStreams)
        let microphoneChannelCount = microphoneStreams.reduce(0) { $0 + $1.channelCount }
        let expectedChannelCount = microphoneChannelCount + tapChannelCount

        guard expectedChannelCount == actualChannelCount else {
            throw ChannelMapError.aggregateChannelCountMismatch(
                expected: expectedChannelCount,
                actual: actualChannelCount
            )
        }
        guard microphoneChannelCount <= 2 else {
            throw ChannelMapError.unsupportedMicrophoneChannelCount(microphoneChannelCount)
        }
        guard tapChannelCount == 0 || tapChannelCount == 2 else {
            throw ChannelMapError.unsupportedTapChannelCount(tapChannelCount)
        }

        if tapChannelCount == 0 {
            return InputChannelMap(
                microphoneChannels: Array(0..<microphoneChannelCount),
                systemChannels: [],
                bufferLayout: bufferLayout,
                confidence: confidence(forMicrophoneOnly: aggregateStreams)
            )
        }

        if microphoneStreams.isEmpty {
            return InputChannelMap(
                microphoneChannels: [],
                systemChannels: Array(0..<tapChannelCount),
                bufferLayout: bufferLayout,
                confidence: confidence(forSystemOnly: aggregateStreams)
            )
        }

        if let terminalMap = mapFromTerminalTypes(
            aggregateStreams: aggregateStreams,
            microphoneChannelCount: microphoneChannelCount,
            tapChannelCount: tapChannelCount
        ) {
            return InputChannelMap(
                microphoneChannels: terminalMap.microphone,
                systemChannels: terminalMap.system,
                bufferLayout: bufferLayout,
                confidence: .terminalType
            )
        }

        if let nameMap = mapFromTapNames(
            aggregateStreams: aggregateStreams,
            microphoneChannelCount: microphoneChannelCount,
            tapChannelCount: tapChannelCount
        ) {
            return InputChannelMap(
                microphoneChannels: nameMap.microphone,
                systemChannels: nameMap.system,
                bufferLayout: bufferLayout,
                confidence: .streamName
            )
        }

        return InputChannelMap(
            microphoneChannels: Array(0..<microphoneChannelCount),
            systemChannels: Array(microphoneChannelCount..<expectedChannelCount),
            bufferLayout: bufferLayout,
            confidence: .assumedMicThenTap
        )
    }

    private static func makeBufferLayout(
        aggregateStreams: [InputStreamDescriptor],
        inputBufferChannelCounts: [Int]?
    ) -> [InputBufferLayout] {
        guard let inputBufferChannelCounts else {
            return aggregateStreams.map {
                InputBufferLayout(bufferIndex: $0.bufferIndex, channelCount: $0.channelCount)
            }
        }
        return inputBufferChannelCounts.enumerated().map { bufferIndex, channelCount in
            InputBufferLayout(bufferIndex: bufferIndex, channelCount: channelCount)
        }
    }

    private static func validateMicrophoneStreams(_ streams: [InputStreamDescriptor]) throws {
        if let invalidStream = streams.first(where: { $0.channelCount <= 0 }) {
            throw ChannelMapError.unsupportedMicrophoneChannelCount(invalidStream.channelCount)
        }
    }

    private static func contiguousChannelCount(for streams: [InputStreamDescriptor]) throws -> Int {
        var cursor = 0
        for stream in streams.sorted(by: { $0.startingChannelIndex < $1.startingChannelIndex }) {
            guard stream.channelCount > 0, stream.startingChannelIndex == cursor else {
                throw ChannelMapError.nonContiguousChannels
            }
            cursor += stream.channelCount
        }
        return cursor
    }

    private static func confidence(forMicrophoneOnly streams: [InputStreamDescriptor]) -> ChannelMapConfidence {
        streams.contains(where: \.isMicrophoneTerminal) ? .terminalType : .assumedMicThenTap
    }

    private static func confidence(forSystemOnly streams: [InputStreamDescriptor]) -> ChannelMapConfidence {
        streams.contains(where: \.hasTapName) ? .streamName : .assumedMicThenTap
    }

    private static func mapFromTerminalTypes(
        aggregateStreams: [InputStreamDescriptor],
        microphoneChannelCount: Int,
        tapChannelCount: Int
    ) -> (microphone: [Int], system: [Int])? {
        let microphoneChannels = aggregateStreams
            .filter(\.isMicrophoneTerminal)
            .flatMap(\.channelIndexes)
        guard microphoneChannels.count == microphoneChannelCount else {
            return nil
        }

        let systemChannels = Array(Set(0..<(microphoneChannelCount + tapChannelCount)).subtracting(microphoneChannels)).sorted()
        guard systemChannels.count == tapChannelCount else {
            return nil
        }
        return (microphoneChannels, systemChannels)
    }

    private static func mapFromTapNames(
        aggregateStreams: [InputStreamDescriptor],
        microphoneChannelCount: Int,
        tapChannelCount: Int
    ) -> (microphone: [Int], system: [Int])? {
        let systemChannels = aggregateStreams
            .filter(\.hasTapName)
            .flatMap(\.channelIndexes)
        guard systemChannels.count == tapChannelCount else {
            return nil
        }

        let microphoneChannels = Array(Set(0..<(microphoneChannelCount + tapChannelCount)).subtracting(systemChannels)).sorted()
        guard microphoneChannels.count == microphoneChannelCount else {
            return nil
        }
        return (microphoneChannels, systemChannels)
    }
}

private extension InputStreamDescriptor {
    var isMicrophoneTerminal: Bool {
        switch terminalType {
        case .microphone, .headset, .line:
            true
        case .unknown:
            false
        }
    }

    var hasTapName: Bool {
        name.lowercased().contains("tap")
    }

    var channelIndexes: [Int] {
        Array(startingChannelIndex..<(startingChannelIndex + channelCount))
    }
}
