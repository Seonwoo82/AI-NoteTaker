import CryptoKit
import Foundation

@MainActor
final class MeetingDataSynchronizer {
    private let profile: MeetingProfileStore?
    private let store: MeetingIntelligenceStore?
    private let edits: MeetingEditLog?
    private var profileSync: Task<Void, Error>?
    private var artifactSync: Task<Void, Error>?

    init(
        profile: MeetingProfileStore? = nil,
        store: MeetingIntelligenceStore? = nil,
        edits: MeetingEditLog? = nil
    ) {
        self.profile = profile
        self.store = store
        self.edits = edits
    }

    func cancel() {
        profileSync?.cancel()
        artifactSync?.cancel()
    }

    func synchronizeProfile(transport: any MeetingDataSyncTransport, workspace: String) async throws {
        guard let profile else { return }
        if let profileSync {
            try await profileSync.value
            return
        }
        try Task.checkCancellation()
        let task = Task { @MainActor in
            defer { profileSync = nil }
            guard profile.setSyncWorkspace(workspace) else {
                throw SyncError.transferFailed(profile.lastError ?? "Meeting profile sync state could not be saved.")
            }
            let remote = try await transport.getMeetingProfile()
            try Task.checkCancellation()
            if let remoteProfile = remote.profile {
                try profile.applyRemoteProfile(remoteProfile)
            }
            guard let pending = profile.pendingProfileUpload else { return }
            try pending.validate()
            let response = try await transport.putMeetingProfile(MeetingProfileUpload(profile: pending))
            try Task.checkCancellation()
            if response.profile == pending {
                guard profile.markProfileUploadFinished(pending) else {
                    throw SyncError.transferFailed(profile.lastError ?? "Meeting profile sync acknowledgement could not be saved.")
                }
            } else if let winner = response.profile {
                try profile.applyRemoteProfile(winner)
            }
        }
        profileSync = task
        try await awaitOwnedTask(task)
    }

    func synchronizeArtifacts(
        transport: any MeetingDataSyncTransport,
        workspace: String,
        library: LibraryStore
    ) async throws {
        guard store != nil || edits != nil else { return }
        if let artifactSync {
            try await artifactSync.value
            return
        }
        try Task.checkCancellation()
        let task = Task { @MainActor in
            defer { artifactSync = nil }
            var firstRecoverableError: Error?
            do {
                try await synchronizeEdits(transport: transport, workspace: workspace, library: library)
            } catch let error as CancellationError {
                throw error
            } catch {
                firstRecoverableError = error
            }
            do {
                try await synchronizeIntelligence(transport: transport, library: library)
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil { firstRecoverableError = error }
            }
            if let firstRecoverableError {
                throw firstRecoverableError
            }
        }
        artifactSync = task
        try await awaitOwnedTask(task)
    }

    private nonisolated func awaitOwnedTask(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func synchronizeEdits(
        transport: any MeetingDataSyncTransport,
        workspace: String,
        library: LibraryStore
    ) async throws {
        guard let edits else { return }
        var firstRecoverableError: Error?
        var pageCount = 0
        while true {
            try Task.checkCancellation()
            pageCount += 1
            guard pageCount <= 1_000 else { throw SyncError.invalidResponse }
            let page = try await transport.listMeetingEdits(after: edits.cursor(workspace: workspace))
            try Task.checkCancellation()
            try edits.ingest(page: page, workspace: workspace)
            guard page.nextCursor != nil else { break }
        }

        for edit in edits.pending(workspace: workspace) {
            try Task.checkCancellation()
            guard shouldUpload(edit, library: library) else { continue }
            do {
                let entry = try await transport.uploadMeetingEdit(edit)
                try Task.checkCancellation()
                try edits.acknowledge(entry: entry, workspace: workspace)
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil { firstRecoverableError = error }
            }
        }
        if let firstRecoverableError {
            throw firstRecoverableError
        }
    }

    private func synchronizeIntelligence(
        transport: any MeetingDataSyncTransport,
        library: LibraryStore
    ) async throws {
        guard let store else { return }
        let remoteByKey = try await fetchRemoteIntelligence(transport: transport)
        let recordings = Dictionary(uniqueKeysWithValues: library.recordings.map { ($0.id, $0) })
        var remoteDocuments: [MeetingIntelligenceKey: MeetingIntelligenceDocument] = [:]
        var firstRecoverableError: Error?

        for descriptor in remoteByKey.values.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let recording = recordings[descriptor.recordingID],
                  recording.deletedAt == nil,
                  recording.audioVersion == descriptor.audioVersion,
                  !isLocallyPurged(recording.id, library: library)
            else { continue }
            do {
                let localSnapshot = try store.localDescriptor(for: recording)
                if localSnapshot == descriptor {
                    continue
                }
                let temp = library.paths.directory(for: descriptor.recordingID)
                    .appending(path: ".\(descriptor.recordingID.uuidString)-\(descriptor.audioVersion)-intelligence.download")
                try? FileManager.default.removeItem(at: temp)
                do {
                    try await transport.downloadMeetingIntelligence(descriptor, to: temp)
                    let data = try store.readDownloadedData(from: temp)
                    try? FileManager.default.removeItem(at: temp)
                    let remote = try store.validateDownloadedDescriptor(descriptor, data: data, recording: recording)
                    remoteDocuments[descriptor.key] = remote
                    if let current = try store.localDocumentWithData(for: recording),
                       current.descriptor != localSnapshot,
                       current.document.wins(over: remote) {
                        continue
                    }
                    _ = try await store.publishRemote(remote, data: data, descriptor: descriptor)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    throw error
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil { firstRecoverableError = error }
            }
        }

        for recording in recordings.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            guard recording.deletedAt == nil, !isLocallyPurged(recording.id, library: library) else { continue }
            do {
                guard let local = try store.localDocumentWithData(for: recording) else { continue }
                let document = local.document
                let key = MeetingIntelligenceKey(recordingID: document.recordingID, audioVersion: document.audioVersion)
                let currentSnapshot = try store.localDocumentWithData(for: recording) ?? local
                let current = currentSnapshot.document
                let data = currentSnapshot.data
                let localDescriptor = currentSnapshot.descriptor
                if let remoteDescriptor = remoteByKey[key], remoteDescriptor == localDescriptor {
                    continue
                }
                if let remoteDocument = remoteDocuments[key], !current.wins(over: remoteDocument) {
                    continue
                }
                try current.validate(duration: recording.duration)
                let winner = try await transport.uploadMeetingIntelligence(current, data: data)
                try Task.checkCancellation()
                if let latest = try store.localDocumentWithData(for: recording),
                   latest.descriptor != localDescriptor,
                   latest.document.wins(over: current) {
                    _ = try await transport.uploadMeetingIntelligence(latest.document, data: latest.data)
                    continue
                }
                if winner != localDescriptor {
                    let temp = library.paths.directory(for: winner.recordingID)
                        .appending(path: ".\(winner.recordingID.uuidString)-\(winner.audioVersion)-intelligence-winner.download")
                    try? FileManager.default.removeItem(at: temp)
                    do {
                        try await transport.downloadMeetingIntelligence(winner, to: temp)
                        let winnerData = try store.readDownloadedData(from: temp)
                        try? FileManager.default.removeItem(at: temp)
                        let winnerDocument = try store.validateDownloadedDescriptor(winner, data: winnerData, recording: recording)
                        _ = try await store.publishRemote(winnerDocument, data: winnerData, descriptor: winner)
                    } catch {
                        try? FileManager.default.removeItem(at: temp)
                        throw error
                    }
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil { firstRecoverableError = error }
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }
    }

    private func fetchRemoteIntelligence(
        transport: any MeetingDataSyncTransport
    ) async throws -> [MeetingIntelligenceKey: MeetingNotesDescriptor] {
        var cursor: String?
        var previousCursor: String?
        var seenCursors = Set<String>()
        var descriptors: [MeetingIntelligenceKey: MeetingNotesDescriptor] = [:]
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            pageCount += 1
            guard pageCount <= 1_000 else { throw SyncError.invalidResponse }
            let page = try await transport.listMeetingIntelligence(cursor: cursor)
            for descriptor in page.intelligence {
                let key = descriptor.key
                guard descriptors[key] == nil else { throw SyncError.invalidResponse }
                descriptors[key] = descriptor
            }
            guard let nextCursor = page.nextCursor else {
                cursor = nil
                continue
            }
            guard !nextCursor.isEmpty,
                  previousCursor.map({ nextCursor > $0 }) ?? true,
                  seenCursors.insert(nextCursor).inserted,
                  !page.intelligence.isEmpty
            else {
                throw SyncError.invalidResponse
            }
            previousCursor = nextCursor
            cursor = nextCursor
        } while cursor != nil
        return descriptors
    }

    private func isLocallyPurged(_ recordingID: UUID, library: LibraryStore) -> Bool {
        FileManager.default.fileExists(atPath: library.paths.directory(for: recordingID).appending(path: ".purged").path)
    }

    private func shouldUpload(_ edit: MeetingEdit, library: LibraryStore) -> Bool {
        guard let recording = library.recording(id: edit.recordingID),
              recording.deletedAt == nil,
              recording.audioVersion == edit.audioVersion,
              !isLocallyPurged(edit.recordingID, library: library)
        else { return false }
        return true
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct MeetingIntelligenceKey: Hashable, Comparable {
    let recordingID: UUID
    let audioVersion: Int

    static func < (lhs: MeetingIntelligenceKey, rhs: MeetingIntelligenceKey) -> Bool {
        if lhs.recordingID.uuidString == rhs.recordingID.uuidString {
            return lhs.audioVersion < rhs.audioVersion
        }
        return lhs.recordingID.uuidString < rhs.recordingID.uuidString
    }
}

private extension MeetingNotesDescriptor {
    var key: MeetingIntelligenceKey {
        MeetingIntelligenceKey(recordingID: recordingID, audioVersion: audioVersion)
    }
}
