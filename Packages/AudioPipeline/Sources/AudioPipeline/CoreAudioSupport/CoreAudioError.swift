import CoreAudio

public enum CoreAudioOperation: String, Equatable, Sendable {
    case getDataSize
    case getData
    case addListener
    case removeListener
    case createAggregate
    case destroyAggregate
    case destroyTap
    case createIOProc
    case destroyIOProc
    case startDevice
    case stopDevice
}

public struct CoreAudioError: Error, Equatable, Sendable {
    public let status: OSStatus
    public let operation: CoreAudioOperation
    public let objectID: AudioObjectID
    public let selector: AudioObjectPropertySelector?

    public init(
        status: OSStatus,
        operation: CoreAudioOperation,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector?
    ) {
        self.status = status
        self.operation = operation
        self.objectID = objectID
        self.selector = selector
    }
}
