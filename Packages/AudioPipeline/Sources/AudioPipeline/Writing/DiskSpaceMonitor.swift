import Foundation

public protocol DiskSpaceChecking: Sendable {
    func availableCapacity(at url: URL) throws -> Int64
}

public struct VolumeDiskSpaceChecker: DiskSpaceChecking, Sendable {
    public init() {}

    public func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        throw AudioCaptureError.fileWriteFailed("Volume capacity unavailable")
    }
}

internal struct DiskSpaceMonitor: Sendable {
    internal static let lowWatermarkBytes: Int64 = 30 * 1_024 * 1_024
    internal static let defaultWatchdogIntervalFrames: UInt64 = 480_000

    private let checker: any DiskSpaceChecking
    private let volumeURL: URL
    private let watchdogIntervalFrames: UInt64
    private var nextFrameThreshold: UInt64

    internal init(
        checker: any DiskSpaceChecking,
        outputURL: URL,
        watchdogIntervalFrames: UInt64 = Self.defaultWatchdogIntervalFrames
    ) {
        self.checker = checker
        self.volumeURL = Self.volumeURL(for: outputURL)
        self.watchdogIntervalFrames = max(1, watchdogIntervalFrames)
        self.nextFrameThreshold = self.watchdogIntervalFrames
    }

    internal mutating func ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: UInt64) throws {
        guard outputFramesWritten >= nextFrameThreshold else { return }
        let capacity = try checker.availableCapacity(at: volumeURL)
        if capacity < Self.lowWatermarkBytes {
            throw AudioCaptureError.diskSpaceLow
        }
        let completedIntervals = outputFramesWritten / watchdogIntervalFrames
        nextFrameThreshold = (completedIntervals + 1) * watchdogIntervalFrames
    }

    private static func volumeURL(for outputURL: URL) -> URL {
        let parent = outputURL.deletingLastPathComponent()
        guard !parent.path.isEmpty else {
            return outputURL
        }
        return parent
    }
}
