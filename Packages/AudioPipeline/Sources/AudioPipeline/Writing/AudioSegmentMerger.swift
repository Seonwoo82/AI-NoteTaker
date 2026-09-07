@preconcurrency import AVFoundation
import Foundation

public struct AudioSegmentMergeOutput: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
}

typealias AudioSegmentExport = @Sendable (_ asset: AVAsset, _ destination: URL, _ presetName: String) async throws -> Void

public struct AudioSegmentMerger: Sendable {
    private let export: AudioSegmentExport

    public init() {
        self.export = Self.exportWithAVFoundation
    }

    init(export: @escaping AudioSegmentExport) {
        self.export = export
    }

    public func merge(_ sources: [URL], to destination: URL) async throws -> AudioSegmentMergeOutput {
        guard !sources.isEmpty else {
            throw AudioCaptureError.fileWriteFailed("No recording segments to merge")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AudioCaptureError.outputAlreadyExists(destination.path)
        }

        let orderedSources = sources.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if orderedSources.count == 1 {
            return try await copySingleSegment(orderedSources[0], to: destination)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioCaptureError.fileWriteFailed("Could not create segment composition track")
        }
        var cursor = CMTime.zero
        for source in orderedSources {
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioCaptureError.fileWriteFailed("Recording segment has no audio track: \(source.path)")
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + duration
        }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString).merge.mp4")
        do {
            try await export(composition, temporaryURL, AVAssetExportPresetPassthrough)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return try readOutput(destination, duration: cursor.seconds)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if let audioError = error as? AudioCaptureError {
                throw audioError
            }
            throw AudioCaptureError.fileWriteFailed("Could not merge recording segments: \(Self.describe(error))")
        }
    }

    private static func exportWithAVFoundation(_ asset: AVAsset, _ url: URL, _ presetName: String) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw AudioCaptureError.fileWriteFailed("Could not create segment exporter")
        }
        try await exporter.export(to: url, as: .mp4)
    }

    private func copySingleSegment(_ source: URL, to destination: URL) async throws -> AudioSegmentMergeOutput {
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString).merge.m4a")
        do {
            try FileManager.default.copyItem(at: source, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return try readOutput(destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if let audioError = error as? AudioCaptureError {
                throw audioError
            }
            throw AudioCaptureError.fileWriteFailed("Could not publish recording segment: \(error.localizedDescription)")
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
    }

    private func readOutput(_ url: URL, duration: TimeInterval? = nil) throws -> AudioSegmentMergeOutput {
        let file = try AVAudioFile(forReading: url)
        return AudioSegmentMergeOutput(
            url: url,
            duration: duration ?? TimeInterval(Double(file.length) / file.fileFormat.sampleRate),
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount)
        )
    }
}
