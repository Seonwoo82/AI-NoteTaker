@preconcurrency import AVFAudio
import AudioPipeline
import Foundation

nonisolated enum RecordingRecovery {
    private struct ReadableRun {
        let url: URL
        let duration: TimeInterval
        let createdAt: Date
    }

    private struct ReadableAudio {
        let duration: TimeInterval
        let createdAt: Date
    }

    static func recoverRecordings(in paths: LibraryPaths) async {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: paths.recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for directory in directories {
            await recoverDirectory(directory, paths: paths, fileManager: fileManager)
        }
    }

    private static func recoverDirectory(
        _ directory: URL,
        paths: LibraryPaths,
        fileManager: FileManager
    ) async {
        guard let id = UUID(uuidString: directory.lastPathComponent),
              directoryIsDirectory(directory),
              !fileManager.fileExists(atPath: paths.metadataURL(for: id).path)
        else { return }

        let audioURL = paths.audioURL(for: id)
        let segmentsDirectory = paths.segmentsDirectory(for: id)
        let finalAudio = readableAudio(at: audioURL)
        let orderedRunURLs = orderedRuns(in: segmentsDirectory, fileManager: fileManager)
        let readableRuns = orderedRunURLs.flatMap { readablePrefix(from: $0) }
        let hasUnverifiedSegments = fileManager.fileExists(atPath: segmentsDirectory.path)
            && (orderedRunURLs == nil || readableRuns == nil)

        if let readableRuns, !readableRuns.isEmpty {
            let runsDuration = readableRuns.reduce(0) { $0 + $1.duration }
            if let finalAudio {
                if runsDuration > finalAudio.duration {
                    await publishMergedRuns(
                        readableRuns,
                        id: id,
                        audioURL: audioURL,
                        paths: paths,
                        segmentsDirectory: segmentsDirectory,
                        fileManager: fileManager
                    )
                    return
                }
            } else {
                await publishMergedRuns(
                    readableRuns,
                    id: id,
                    audioURL: audioURL,
                    paths: paths,
                    segmentsDirectory: segmentsDirectory,
                    fileManager: fileManager
                )
                return
            }
        }

        if let finalAudio {
            try? publishRecoveredRecording(
                id: id,
                duration: finalAudio.duration,
                createdAt: finalAudio.createdAt,
                paths: paths,
                segmentsDirectory: segmentsDirectory,
                fileManager: fileManager,
                cleanupSegments: !hasUnverifiedSegments
            )
            return
        }
    }

    private static func publishMergedRuns(
        _ readableRuns: [ReadableRun],
        id: UUID,
        audioURL: URL,
        paths: LibraryPaths,
        segmentsDirectory: URL,
        fileManager: FileManager
    ) async {
        let hasExistingFinalAudio = fileManager.fileExists(atPath: audioURL.path)
        let existingFinalBackupURL = backupExistingFinalAudioIfNeeded(audioURL, fileManager: fileManager)
        guard !hasExistingFinalAudio || existingFinalBackupURL != nil else { return }
        do {
            let merged = try await AudioSegmentMerger().merge(readableRuns.map(\.url), to: audioURL)
            try publishRecoveredRecording(
                id: id,
                duration: merged.duration,
                createdAt: recoveredCreationDate(from: readableRuns),
                paths: paths,
                segmentsDirectory: segmentsDirectory,
                fileManager: fileManager,
                cleanupSegments: true
            )
            if let existingFinalBackupURL {
                try? fileManager.removeItem(at: existingFinalBackupURL)
            }
        } catch {
            try? fileManager.removeItem(at: audioURL)
            if let existingFinalBackupURL {
                try? fileManager.moveItem(at: existingFinalBackupURL, to: audioURL)
            }
        }
    }

    private static func publishRecoveredRecording(
        id: UUID,
        duration: TimeInterval,
        createdAt: Date,
        paths: LibraryPaths,
        segmentsDirectory: URL,
        fileManager: FileManager,
        cleanupSegments: Bool
    ) throws {
        let recording = Recording(
            id: id,
            title: String(localized: "Recovered Recording"),
            createdAt: createdAt,
            duration: duration,
            mode: .micAndSystem
        )
        try JSONFile.save(recording, to: paths.metadataURL(for: id))
        if cleanupSegments,
           fileManager.fileExists(atPath: paths.audioURL(for: id).path),
           fileManager.fileExists(atPath: paths.metadataURL(for: id).path) {
            try? fileManager.removeItem(at: segmentsDirectory)
        }
    }

    private static func readableAudio(at url: URL) -> ReadableAudio? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let duration = TimeInterval(file.length) / sampleRate
        let createdAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return ReadableAudio(duration: duration, createdAt: createdAt)
    }

    private static func backupExistingFinalAudioIfNeeded(
        _ audioURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard fileManager.fileExists(atPath: audioURL.path) else { return nil }
        let backupURL = audioURL.deletingLastPathComponent()
            .appending(path: ".audio.recovery.\(UUID().uuidString).m4a")
        do {
            try fileManager.moveItem(at: audioURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private static func orderedRuns(
        in segmentsDirectory: URL,
        fileManager: FileManager
    ) -> [URL]? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: segmentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let runs = contents.compactMap { url -> (Int, URL)? in
            guard url.pathExtension == "m4a",
                  url.lastPathComponent != "preview.m4a",
                  url.deletingPathExtension().lastPathComponent.count == 3,
                  let index = Int(url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (index, url)
        }
        .sorted { lhs, rhs in lhs.0 < rhs.0 }

        guard !runs.isEmpty else { return nil }
        for (expected, run) in runs.enumerated() where run.0 != expected {
            return nil
        }
        return runs.map(\.1)
    }

    private static func readablePrefix(from runs: [URL]) -> [ReadableRun]? {
        var readable: [ReadableRun] = []
        for (index, run) in runs.enumerated() {
            guard let audio = readableAudio(at: run) else {
                guard index == runs.index(before: runs.endIndex) else {
                    return nil
                }
                break
            }
            readable.append(ReadableRun(url: run, duration: audio.duration, createdAt: audio.createdAt))
        }
        return readable
    }

    private static func recoveredCreationDate(from runs: [ReadableRun]) -> Date {
        runs.map(\.createdAt).max() ?? Date()
    }

    private static func directoryIsDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
