@preconcurrency import AVFAudio
import Darwin
import Foundation

public struct CaptureProgress: Equatable, Sendable {
    public let duration: TimeInterval
    public let microphonePeak: Float
    public let systemPeak: Float

    public init(duration: TimeInterval, microphonePeak: Float, systemPeak: Float) {
        self.duration = duration
        self.microphonePeak = microphonePeak
        self.systemPeak = systemPeak
    }
}

public struct RecordingWriterStats: Equatable, Sendable {
    public let inputFramesRead: UInt64
    public let outputFramesWritten: UInt64
    public let fileWriteCalls: UInt64
    public let barsEmitted: UInt64
    public let ringDroppedFrames: UInt64
    public let ringOverflowCount: UInt64
    public let microphonePeak: Float
    public let systemPeak: Float

    public init(
        inputFramesRead: UInt64,
        outputFramesWritten: UInt64,
        fileWriteCalls: UInt64,
        barsEmitted: UInt64,
        ringDroppedFrames: UInt64,
        ringOverflowCount: UInt64,
        microphonePeak: Float,
        systemPeak: Float
    ) {
        self.inputFramesRead = inputFramesRead
        self.outputFramesWritten = outputFramesWritten
        self.fileWriteCalls = fileWriteCalls
        self.barsEmitted = barsEmitted
        self.ringDroppedFrames = ringDroppedFrames
        self.ringOverflowCount = ringOverflowCount
        self.microphonePeak = microphonePeak
        self.systemPeak = systemPeak
    }

    public var duration: TimeInterval {
        TimeInterval(Double(outputFramesWritten) / RecordingFileSettings.outputSampleRate)
    }
}

public struct FinishedRecordingOutput: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
    public let bars: [AudioBar]
    public let stats: RecordingWriterStats
    public let warnings: [AudioCaptureWarning]

    public init(
        url: URL,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        bars: [AudioBar],
        stats: RecordingWriterStats,
        warnings: [AudioCaptureWarning]
    ) {
        self.url = url
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bars = bars
        self.stats = stats
        self.warnings = warnings
    }
}

public struct RecordingSegmentOutput: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let outputFramesWritten: UInt64

    public init(url: URL, duration: TimeInterval, outputFramesWritten: UInt64) {
        self.url = url
        self.duration = duration
        self.outputFramesWritten = outputFramesWritten
    }
}

internal protocol RecordingFileSink: AnyObject, Sendable {
    var processingFormat: AVAudioFormat { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    func close()
}

internal protocol RecordingFileSinkFactory: Sendable {
    func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink
}

internal struct AVAudioRecordingFileSinkFactory: RecordingFileSinkFactory {
    internal typealias FileOpener = @Sendable (
        _ url: URL,
        _ settings: [String: Any],
        _ commonFormat: AVAudioCommonFormat,
        _ interleaved: Bool
    ) throws -> AVAudioFile

    private let fileOpener: FileOpener

    internal init() {
        self.fileOpener = { url, settings, commonFormat, interleaved in
            try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: commonFormat,
                interleaved: interleaved
            )
        }
    }

    internal init(fileOpener: @escaping FileOpener) {
        self.fileOpener = fileOpener
    }

    internal func open(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws -> any RecordingFileSink {
        guard !Self.pathEntryExists(at: url) else {
            throw AudioCaptureError.outputAlreadyExists(url.path)
        }

        let stagedOutput = try StagedOutputDirectory(finalURL: url)
        do {
            let file = try fileOpener(stagedOutput.fileURL, settings, commonFormat, interleaved)
            do {
                try stagedOutput.publish(to: url)
            } catch {
                file.close()
                stagedOutput.removeIfOwned()
                throw error
            }
            return AVAudioRecordingFileSink(file: file)
        } catch {
            stagedOutput.removeIfOwned()
            throw error
        }
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return true }
            return Darwin.lstat(path, &metadata) == 0
        }
    }
}

private final class StagedOutputDirectory {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ metadata: stat) {
            self.device = metadata.st_dev
            self.inode = metadata.st_ino
        }
    }

    let fileURL: URL

    private let directoryURL: URL
    private let identity: Identity

    init(finalURL: URL) throws {
        let directoryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).\(UUID().uuidString).writing",
            isDirectory: true
        )
        let status = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        guard status == 0 else {
            let errorCode = errno
            throw AudioCaptureError.fileWriteFailed(
                "Could not create staging directory for \(finalURL.path): \(Self.errorDescription(errorCode))"
            )
        }

        var metadata = stat()
        let statStatus = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard statStatus == 0 else {
            let errorCode = errno
            _ = directoryURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.rmdir(path)
            }
            throw AudioCaptureError.fileWriteFailed(
                "Could not inspect staging directory for \(finalURL.path): \(Self.errorDescription(errorCode))"
            )
        }

        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("recording.m4a")
        self.identity = Identity(metadata)
    }

    deinit {
        removeIfOwned()
    }

    func publish(to finalURL: URL) throws {
        guard directoryIsOwned(), stagedFileIsRegular() else {
            throw AudioCaptureError.fileWriteFailed(
                "Staged output ownership changed before publishing \(finalURL.path)"
            )
        }

        let status = fileURL.withUnsafeFileSystemRepresentation { stagedPath in
            finalURL.withUnsafeFileSystemRepresentation { finalPath in
                guard let stagedPath, let finalPath else { return Int32(-1) }
                return Darwin.renamex_np(stagedPath, finalPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let errorCode = errno
            if Self.pathEntryExists(at: finalURL) {
                throw AudioCaptureError.outputAlreadyExists(finalURL.path)
            }
            throw AudioCaptureError.fileWriteFailed(
                "Could not publish output at \(finalURL.path): \(Self.errorDescription(errorCode))"
            )
        }

        removeDirectoryIfOwnedAndEmpty()
    }

    func removeIfOwned() {
        guard directoryIsOwned() else { return }

        if stagedFileIsRegular() {
            _ = fileURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.unlink(path)
            }
        }
        removeDirectoryIfOwnedAndEmpty()
    }

    private func directoryIsOwned() -> Bool {
        var metadata = stat()
        let status = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        return status == 0
            && Identity(metadata) == identity
            && metadata.st_mode & S_IFMT == S_IFDIR
    }

    private func stagedFileIsRegular() -> Bool {
        var metadata = stat()
        let status = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        return status == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }

    private func removeDirectoryIfOwnedAndEmpty() {
        guard directoryIsOwned() else { return }
        _ = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.rmdir(path)
        }
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return true }
            return Darwin.lstat(path, &metadata) == 0
        }
    }

    private static func errorDescription(_ errorCode: Int32) -> String {
        String(cString: strerror(errorCode)) + " (errno \(errorCode))"
    }
}

private final class AVAudioRecordingFileSink: RecordingFileSink, @unchecked Sendable {
    private let file: AVAudioFile

    var processingFormat: AVAudioFormat { file.processingFormat }

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }

    func close() {
        file.close()
    }
}


internal final class LockedResultBox<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Success, Error>?

    internal func set(_ result: Result<Success, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    internal func require() throws -> Result<Success, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw AudioCaptureError.fileWriteFailed("Recording writer result unavailable")
        }
        return result
    }
}
