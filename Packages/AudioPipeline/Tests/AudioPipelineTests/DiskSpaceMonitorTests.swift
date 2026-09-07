@testable import AudioPipeline
import Foundation
import Testing

@Test("Disk monitor ignores startup capacity and throws only after written frames drop below watchdog watermark")
func diskMonitorIgnoresStartupCapacityAndThrowsOnlyAfterWrittenFramesDropBelowWatchdogWatermark() throws {
    var monitor = DiskSpaceMonitor(
        checker: FixedDiskSpaceChecker(capacity: 10 * 1_024 * 1_024),
        outputURL: URL(fileURLWithPath: "/tmp/recording.m4a")
    )

    try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: 0)
    #expect(throws: AudioCaptureError.diskSpaceLow) {
        try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: 480_000)
    }
}

@Test("Disk monitor checks capacity only at successive ten second output frame thresholds")
func diskMonitorChecksCapacityOnlyAtSuccessiveTenSecondOutputFrameThresholds() throws {
    let checker = RecordingDiskSpaceChecker(capacity: 100 * 1_024 * 1_024)
    var monitor = DiskSpaceMonitor(
        checker: checker,
        outputURL: URL(fileURLWithPath: "/tmp/task-2-output/recording.m4a")
    )

    for frames in [0, 1, 1_024, 479_999] as [UInt64] {
        try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: frames)
    }
    #expect(checker.calls().isEmpty)

    try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: 480_000)
    #expect(checker.calls() == [URL(fileURLWithPath: "/tmp/task-2-output", isDirectory: true)])

    for frames in [480_001, 721_000, 959_999] as [UInt64] {
        try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: frames)
    }
    #expect(checker.calls().count == 1)

    try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: 960_000)
    try monitor.ensureEnoughSpaceAfterWritingStarted(outputFramesWritten: 1_440_000)
    #expect(checker.calls().count == 3)
}

private struct FixedDiskSpaceChecker: DiskSpaceChecking {
    let capacity: Int64
    func availableCapacity(at url: URL) throws -> Int64 { capacity }
}

private final class RecordingDiskSpaceChecker: DiskSpaceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int64
    private var urls: [URL] = []

    init(capacity: Int64) {
        self.capacity = capacity
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        lock.lock()
        urls.append(url)
        lock.unlock()
        return capacity
    }

    func calls() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
