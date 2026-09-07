import Foundation

public struct PlaybackTimeline: Equatable, Sendable {
    public static let skipInterval: TimeInterval = 15

    public let duration: TimeInterval

    public var endTime: TimeInterval { duration }

    public init(duration: TimeInterval) {
        self.duration = max(0, duration)
    }

    public func clampedSeekTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else {
            return time.sign == .minus ? 0 : duration
        }
        return min(max(0, time), duration)
    }

    public func skippingBackward(from time: TimeInterval) -> TimeInterval {
        clampedSeekTime(time - Self.skipInterval)
    }

    public func skippingForward(from time: TimeInterval) -> TimeInterval {
        clampedSeekTime(time + Self.skipInterval)
    }
}
