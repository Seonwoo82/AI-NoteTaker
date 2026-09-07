import Foundation

public struct RecordingIdentity: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle
    case recording(RecordingIdentity)
    case paused(RecordingIdentity)
    case finishing(RecordingIdentity)
    case failed(String)

    public func applying(_ event: RecordingEvent) throws -> RecordingState {
        switch (self, event) {
        case (.idle, .start(let identity)):
            return .recording(identity)
        case (.recording(let identity), .pause):
            return .paused(identity)
        case (.paused(let identity), .resume):
            return .recording(identity)
        case (.recording(let identity), .finish),
             (.paused(let identity), .finish):
            return .finishing(identity)
        case (.finishing, .finished):
            return .idle
        case (.recording, .fail(let reason)),
             (.paused, .fail(let reason)),
             (.finishing, .fail(let reason)):
            return .failed(reason)
        case (.failed, .reset):
            return .idle
        default:
            throw RecordingStateError.invalidTransition(from: self, event: event)
        }
    }
}

public enum RecordingEvent: Equatable, Sendable {
    case start(RecordingIdentity)
    case pause
    case resume
    case finish
    case finished
    case fail(String)
    case reset
}

public enum RecordingStateError: Error, Equatable, Sendable {
    case invalidTransition(from: RecordingState, event: RecordingEvent)
}
