import Foundation
import Observation

nonisolated enum LibraryStoreError: Error, Equatable, Sendable {
    case recordingNotFound(UUID)
}

@MainActor
@Observable
final class LibraryStore {
    private(set) var recordings: [Recording]
    let paths: LibraryPaths
    @ObservationIgnored var onRecordingUnavailable: ((UUID) -> Void)?

    private init(recordings: [Recording], paths: LibraryPaths) {
        self.recordings = recordings
        self.paths = paths
    }

    static func open(paths: LibraryPaths) async -> LibraryStore {
        let recordings = await Task.detached {
            Self.loadRecordings(paths: paths)
        }.value
        return LibraryStore(recordings: recordings, paths: paths)
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func add(_ recording: Recording) throws {
        try JSONFile.save(recording, to: paths.metadataURL(for: recording.id))
        recordings.append(recording)
        sortRecordings()
    }

    func update(_ recording: Recording) throws {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            throw LibraryStoreError.recordingNotFound(recording.id)
        }
        let previous = recordings[index]
        let stamped = recording.locallyStamped(after: previous)
        try JSONFile.save(stamped, to: paths.metadataURL(for: stamped.id))
        recordings[index] = stamped
        sortRecordings()
        if stamped.deletedAt != nil || stamped.audioVersion != previous.audioVersion {
            onRecordingUnavailable?(stamped.id)
        }
    }

    func applyRemote(_ recording: Recording) throws {
        let previous = self.recording(id: recording.id)
        try JSONFile.save(recording, to: paths.metadataURL(for: recording.id))
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.append(recording)
        }
        sortRecordings()
        if recording.deletedAt != nil || previous.map({ $0.audioVersion != recording.audioVersion }) == true {
            onRecordingUnavailable?(recording.id)
        }
    }

    func audioURL(for recording: Recording) -> URL {
        if recording.audioVersion <= 1 {
            return paths.audioURL(for: recording.id)
        }
        return paths.directory(for: recording.id)
            .appending(path: "audio-\(recording.audioVersion).m4a")
    }

    func nextTitle(base: String = String(localized: "New Recording")) -> String {
        let titles = Set(recordings.map(\.title))
        guard titles.contains(base) else { return base }

        let nextNumber = recordings
            .compactMap { recording -> Int? in
                guard recording.title.hasPrefix("\(base) ") else { return nil }
                let suffix = recording.title.dropFirst(base.count + 1)
                return Int(suffix)
            }
            .max()
            .map { $0 + 1 } ?? 2
        return "\(base) \(nextNumber)"
    }

    nonisolated private static func loadRecordings(paths: LibraryPaths) -> [Recording] {
        let fileManager = FileManager.default
        guard let recordingDirectories = try? fileManager.contentsOfDirectory(
            at: paths.recordingsRoot,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return recordingDirectories
            .compactMap { directory in
                try? JSONFile.load(Recording.self, from: directory.appending(path: "meta.json"))
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func sortRecordings() {
        recordings.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
