import Foundation
import Observation

nonisolated enum LibraryStoreError: Error, Equatable, Sendable {
    case recordingNotFound(UUID)
    case duplicateRecording(UUID)
    case emptyTitle
    case recordingDeleted(UUID)
    case recordingNotDeleted(UUID)
    case metadataWriteFailed(UUID, String)
    case deletionFailed(UUID, String)
}

@MainActor
@Observable
final class LibraryStore {
    private(set) var recordings: [Recording]
    private(set) var maintenanceError: String?
    let paths: LibraryPaths
    @ObservationIgnored var onRecordingUnavailable: ((UUID) -> Void)?

    private init(recordings: [Recording], paths: LibraryPaths, maintenanceError: String? = nil) {
        self.recordings = recordings
        self.paths = paths
        self.maintenanceError = maintenanceError
    }

    static func open(paths: LibraryPaths, now: Date = .now) async -> LibraryStore {
        let loadResult = await Task.detached { () -> LoadResult in
            await RecordingRecovery.recoverRecordings(in: paths)
            return Self.loadRecordings(paths: paths, now: now)
        }.value
        return LibraryStore(
            recordings: loadResult.recordings,
            paths: paths,
            maintenanceError: loadResult.maintenanceError
        )
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func add(_ recording: Recording) throws {
        guard !recordings.contains(where: { $0.id == recording.id }) else {
            throw LibraryStoreError.duplicateRecording(recording.id)
        }
        try saveMetadata(recording)
        recordings.append(recording)
        sortRecordings()
    }

    func update(_ recording: Recording) throws {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            throw LibraryStoreError.recordingNotFound(recording.id)
        }
        guard recordings[index].deletedAt == nil else {
            throw LibraryStoreError.recordingDeleted(recording.id)
        }
        try saveMetadata(recording)
        recordings[index] = recording
        sortRecordings()
    }

    func filteredRecordings(in folder: RecordingFolder, matching query: String = "") -> [Recording] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return recordings.filter { recording in
            guard Self.includes(recording, in: folder) else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return recording.title.localizedStandardContains(trimmedQuery)
        }
    }

    func rename(id: UUID, to title: String) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw LibraryStoreError.emptyTitle
        }
        try mutateActiveRecording(id: id) { recording in
            recording.title = trimmedTitle
        }
    }

    func setFavorite(id: UUID, isFavorite: Bool) throws {
        try mutateActiveRecording(id: id) { recording in
            recording.isFavorite = isFavorite
        }
    }

    func moveToRecentlyDeleted(id: UUID, now: Date = .now) throws {
        try mutateActiveRecording(id: id) { recording in
            recording.deletedAt = now
        }
        onRecordingUnavailable?(id)
    }

    func restore(id: UUID) throws {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.recordingNotFound(id)
        }
        var restored = recordings[index]
        restored.deletedAt = nil
        try saveMetadata(restored)
        recordings[index] = restored
        sortRecordings()
    }

    func deletePermanently(id: UUID) throws {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.recordingNotFound(id)
        }
        guard recordings[index].deletedAt != nil else {
            throw LibraryStoreError.recordingNotDeleted(id)
        }
        do {
            try FileManager.default.removeItem(at: paths.directory(for: id))
        } catch {
            throw LibraryStoreError.deletionFailed(id, String(describing: error))
        }
        recordings.remove(at: index)
        onRecordingUnavailable?(id)
    }

    @discardableResult
    func purgeExpired(now: Date = .now) throws -> [UUID] {
        let expiredIDs = recordings
            .filter { recording in
                guard let deletedAt = recording.deletedAt else { return false }
                return now.timeIntervalSince(deletedAt) >= Self.recentlyDeletedRetention
            }
            .map(\.id)

        var purgedIDs: [UUID] = []
        for id in expiredIDs {
            try deletePermanently(id: id)
            purgedIDs.append(id)
        }
        return purgedIDs
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

    private func mutateActiveRecording(id: UUID, update: (inout Recording) -> Void) throws {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.recordingNotFound(id)
        }
        guard recordings[index].deletedAt == nil else {
            throw LibraryStoreError.recordingDeleted(id)
        }
        var updated = recordings[index]
        update(&updated)
        try saveMetadata(updated)
        recordings[index] = updated
        sortRecordings()
    }

    private func saveMetadata(_ recording: Recording) throws {
        do {
            try JSONFile.save(recording, to: paths.metadataURL(for: recording.id))
        } catch {
            throw LibraryStoreError.metadataWriteFailed(recording.id, String(describing: error))
        }
    }

    nonisolated private static func loadRecordings(paths: LibraryPaths, now: Date) -> LoadResult {
        let fileManager = FileManager.default
        guard let recordingDirectories = try? fileManager.contentsOfDirectory(
            at: paths.recordingsRoot,
            includingPropertiesForKeys: nil
        ) else { return LoadResult(recordings: [], maintenanceError: nil) }

        var maintenanceErrors: [String] = []
        var recordings = recordingDirectories.compactMap { directory -> Recording? in
            guard let directoryID = UUID(uuidString: directory.lastPathComponent) else {
                return nil
            }
            guard let recording = try? JSONFile.load(Recording.self, from: directory.appending(path: "meta.json")) else {
                return nil
            }
            guard recording.id == directoryID else {
                return nil
            }
            return recording
        }

        let expiredRecordings = recordings.filter { recording in
            guard let deletedAt = recording.deletedAt else { return false }
            return now.timeIntervalSince(deletedAt) >= recentlyDeletedRetention
        }

        for recording in expiredRecordings {
            do {
                try fileManager.removeItem(at: paths.directory(for: recording.id))
                recordings.removeAll { $0.id == recording.id }
            } catch {
                maintenanceErrors.append("Failed to purge \(recording.id.uuidString): \(error)")
            }
        }

        return LoadResult(
            recordings: sorted(recordings),
            maintenanceError: maintenanceErrors.isEmpty ? nil : maintenanceErrors.joined(separator: "\n")
        )
    }

    private func sortRecordings() {
        recordings = Self.sorted(recordings)
    }

    nonisolated private static func includes(_ recording: Recording, in folder: RecordingFolder) -> Bool {
        switch folder {
        case .all:
            recording.deletedAt == nil
        case .favorites:
            recording.isFavorite && recording.deletedAt == nil
        case .recentlyDeleted:
            recording.deletedAt != nil
        }
    }

    nonisolated private static func sorted(_ recordings: [Recording]) -> [Recording] {
        recordings.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    nonisolated private static let recentlyDeletedRetention: TimeInterval = 30 * 24 * 60 * 60

    nonisolated private struct LoadResult: Sendable {
        let recordings: [Recording]
        let maintenanceError: String?
    }
}
