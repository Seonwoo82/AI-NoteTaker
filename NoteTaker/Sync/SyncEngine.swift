import Foundation
import CryptoKit

@MainActor
final class SyncEngine {
    private let transport: SyncTransport
    private let onNotesChanged: ((UUID) -> Void)?
    private var currentSync: Task<Void, Error>?
    private var needsResync = false

    init(transport: SyncTransport, onNotesChanged: ((UUID) -> Void)? = nil) {
        self.transport = transport
        self.onNotesChanged = onNotesChanged
    }

    func cancel() {
        currentSync?.cancel()
    }

    func sync(library: LibraryStore) async throws {
        if let currentSync {
            needsResync = true
            try await currentSync.value
            return
        }

        let task = Task { @MainActor in
            defer { currentSync = nil }
            repeat {
                needsResync = false
                try await performSync(library: library)
            } while needsResync
        }
        currentSync = task
        try await task.value
    }

    private func performSync(library: LibraryStore) async throws {
        let remoteByID = try await fetchRemoteIndex()
        let localSnapshot = library.recordings
        let localByID = Dictionary(uniqueKeysWithValues: localSnapshot.map { ($0.id, $0) })
        let ids = Set(remoteByID.keys).union(localByID.keys)
        var firstRecoverableError: Error?

        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let local = localByID[id]
            let remote = remoteByID[id]

            do {
                if let local, let remote, local == remote {
                    if local.deletedAt == nil, needsAudioDownload(for: remote, current: local, library: library) {
                        try await adopt(remote, localSnapshot: local, library: library)
                    }
                    continue
                }

                if let local, local.wins(over: remote) {
                    try await publish(local, remote: remote, library: library)
                    continue
                }

                if let remote {
                    try await adopt(remote, localSnapshot: local, library: library)
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil {
                    firstRecoverableError = error
                }
            }
        }

        if let notesTransport = transport as? MeetingNotesSyncTransport {
            do {
                try await syncMeetingNotes(transport: notesTransport, library: library)
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil {
                    firstRecoverableError = error
                }
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }
    }

    private func fetchRemoteIndex() async throws -> [UUID: Recording] {
        var cursor: String?
        var previousCursors = Set<String>()
        var recordings: [UUID: Recording] = [:]
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            pageCount += 1
            guard pageCount <= 1_000 else {
                throw SyncError.invalidResponse
            }
            let page = try await transport.listRecordings(cursor: cursor)
            for recording in page.recordings {
                guard recordings[recording.id] == nil else {
                    throw SyncError.invalidResponse
                }
                recordings[recording.id] = recording
            }

            guard let nextCursor = page.nextCursor else {
                cursor = nil
                continue
            }
            guard !nextCursor.isEmpty, previousCursors.insert(nextCursor).inserted else {
                throw SyncError.invalidResponse
            }
            guard !page.recordings.isEmpty else {
                throw SyncError.invalidResponse
            }
            cursor = nextCursor
        } while cursor != nil
        return recordings
    }

    private func publish(_ local: Recording, remote: Recording?, library: LibraryStore) async throws {
        try Task.checkCancellation()
        if local.deletedAt == nil, remote?.audioVersion != local.audioVersion {
            let audioURL = library.audioURL(for: local)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw SyncError.missingAudio(local.id)
            }
            try Task.checkCancellation()
            try await transport.uploadAudio(for: local, from: audioURL)
        }

        try Task.checkCancellation()
        let winner = try await transport.putRecording(local)
        let current = library.recording(id: local.id)
        if winner.wins(over: current), winner != current {
            try await adopt(winner, localSnapshot: current, library: library)
        }
    }

    private func adopt(_ remote: Recording, localSnapshot: Recording?, library: LibraryStore) async throws {
        try Task.checkCancellation()
        if let current = library.recording(id: remote.id),
           current != localSnapshot,
           current.wins(over: remote) {
            try await publish(current, remote: remote, library: library)
            return
        }

        let currentBeforeTransfer = library.recording(id: remote.id)
        if remote.deletedAt == nil, needsAudioDownload(for: remote, current: currentBeforeTransfer, library: library) {
            let destination = library.audioURL(for: remote)
            let temp = destination.deletingLastPathComponent()
                .appending(path: ".\(remote.id.uuidString)-\(remote.audioVersion).download")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: temp)
            do {
                try await transport.downloadAudio(for: remote, to: temp)
                try Task.checkCancellation()
                if let current = library.recording(id: remote.id),
                   current != localSnapshot,
                   current.wins(over: remote) {
                    try? FileManager.default.removeItem(at: temp)
                    try await publish(current, remote: remote, library: library)
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        }

        try Task.checkCancellation()
        if let current = library.recording(id: remote.id),
           current != localSnapshot,
           current.wins(over: remote) {
            try await publish(current, remote: remote, library: library)
            return
        }
        try Task.checkCancellation()
        try library.applyRemote(remote)
    }

    private func needsAudioDownload(for remote: Recording, current: Recording?, library: LibraryStore) -> Bool {
        current?.audioVersion != remote.audioVersion ||
            !FileManager.default.fileExists(atPath: library.audioURL(for: remote).path)
    }

    private func syncMeetingNotes(transport: MeetingNotesSyncTransport, library: LibraryStore) async throws {
        let remoteByKey = try await fetchRemoteNotes(transport: transport)
        let localRecordings = Dictionary(uniqueKeysWithValues: library.recordings.map { ($0.id, $0) })
        var localNotes: [MeetingNotesKey: LocalMeetingNotes] = [:]
        var blockedKeys = Set<MeetingNotesKey>()
        var firstRecoverableError: Error?

        for recording in localRecordings.values where !isLocallyPurged(recording.id, library: library) {
            do {
                if let note = try localMeetingNotes(for: recording, library: library) {
                    localNotes[note.descriptor.key] = note
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                blockedKeys.insert(MeetingNotesKey(recordingID: recording.id, audioVersion: recording.audioVersion))
                if firstRecoverableError == nil {
                    firstRecoverableError = error
                }
            }
        }
        let keys = Set(remoteByKey.keys).union(localNotes.keys)

        for key in keys.sorted() {
            try Task.checkCancellation()
            guard let recording = localRecordings[key.recordingID] else { continue }
            if isLocallyPurged(recording.id, library: library) { continue }
            if key.audioVersion != recording.audioVersion { continue }
            if blockedKeys.contains(key) { continue }
            let local = localNotes[key]
            let remote = remoteByKey[key]

            do {
                if let local, let remote, local.descriptor == remote {
                    continue
                }
                if let local, local.descriptor.wins(over: remote) {
                    try await publishMeetingNotes(local, remote: remote, transport: transport, library: library)
                    continue
                }
                if let remote {
                    try await adoptMeetingNotes(remote, localSnapshot: local?.descriptor, recording: recording, transport: transport, library: library)
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if firstRecoverableError == nil {
                    firstRecoverableError = error
                }
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }
    }

    private func fetchRemoteNotes(transport: MeetingNotesSyncTransport) async throws -> [MeetingNotesKey: MeetingNotesDescriptor] {
        var cursor: String?
        var previousCursor: String?
        var seenCursors = Set<String>()
        var notes: [MeetingNotesKey: MeetingNotesDescriptor] = [:]
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            pageCount += 1
            guard pageCount <= 1_000 else {
                throw SyncError.invalidResponse
            }
            let page = try await transport.listMeetingNotes(cursor: cursor)
            for descriptor in page.notes {
                let key = descriptor.key
                guard notes[key] == nil else {
                    throw SyncError.invalidResponse
                }
                notes[key] = descriptor
            }

            guard let nextCursor = page.nextCursor else {
                cursor = nil
                continue
            }
            guard !nextCursor.isEmpty,
                  previousCursor.map({ nextCursor > $0 }) ?? true,
                  seenCursors.insert(nextCursor).inserted,
                  !page.notes.isEmpty
            else {
                throw SyncError.invalidResponse
            }
            previousCursor = nextCursor
            cursor = nextCursor
        } while cursor != nil
        return notes
    }

    private func publishMeetingNotes(
        _ local: LocalMeetingNotes,
        remote: MeetingNotesDescriptor?,
        transport: MeetingNotesSyncTransport,
        library: LibraryStore
    ) async throws {
        try Task.checkCancellation()
        let winner = try await transport.uploadMeetingNotes(local.document, data: local.data)
        try Task.checkCancellation()
        do {
            if let current = try localMeetingNotes(for: local.document.recordingID, audioVersion: local.document.audioVersion, library: library),
               current.descriptor != local.descriptor,
               current.descriptor.wins(over: winner) {
                try await publishMeetingNotes(current, remote: winner, transport: transport, library: library)
                return
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw error
        }
        if winner.wins(over: local.descriptor), winner != local.descriptor {
            guard let recording = library.recording(id: winner.recordingID) else { return }
            try await adoptMeetingNotes(winner, localSnapshot: local.descriptor, recording: recording, transport: transport, library: library)
        } else if let remote, remote.wins(over: local.descriptor) {
            guard let recording = library.recording(id: remote.recordingID) else { return }
            try await adoptMeetingNotes(remote, localSnapshot: local.descriptor, recording: recording, transport: transport, library: library)
        }
    }

    private func adoptMeetingNotes(
        _ remote: MeetingNotesDescriptor,
        localSnapshot: MeetingNotesDescriptor?,
        recording: Recording,
        transport: MeetingNotesSyncTransport,
        library: LibraryStore
    ) async throws {
        try Task.checkCancellation()
        guard recording.audioVersion == remote.audioVersion else {
            throw SyncError.invalidResponse
        }
        let destination = meetingNotesURL(for: remote.recordingID, library: library)
        let temp = destination.deletingLastPathComponent()
            .appending(path: ".\(remote.recordingID.uuidString)-\(remote.audioVersion)-notes.download")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: temp)
        do {
            try await transport.downloadMeetingNotes(remote, to: temp)
            try Task.checkCancellation()
            let data = try readMeetingNotesData(from: temp)
            try validateDownloadedMeetingNotes(data, descriptor: remote, recording: recording)
            do {
                if let current = try localMeetingNotes(for: remote.recordingID, audioVersion: remote.audioVersion, library: library),
                   current.descriptor != localSnapshot,
                   current.descriptor.wins(over: remote) {
                    try? FileManager.default.removeItem(at: temp)
                    try await publishMeetingNotes(current, remote: remote, transport: transport, library: library)
                    return
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                throw error
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            onNotesChanged?(remote.recordingID)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private func localMeetingNotes(for recording: Recording, library: LibraryStore) throws -> LocalMeetingNotes? {
        try localMeetingNotes(for: recording.id, audioVersion: recording.audioVersion, library: library)
    }

    private func localMeetingNotes(for recordingID: UUID, audioVersion: Int, library: LibraryStore) throws -> LocalMeetingNotes? {
        if isLocallyPurged(recordingID, library: library) {
            return nil
        }
        let url = meetingNotesURL(for: recordingID, library: library)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readMeetingNotesData(from: url)
        let document = try meetingNotesDecoder.decode(MeetingNotesDocument.self, from: data)
        guard document.schemaVersion == 1, document.recordingID == recordingID else {
            throw SyncError.invalidResponse
        }
        guard document.audioVersion == audioVersion else { return nil }
        return LocalMeetingNotes(
            document: document,
            data: data,
            descriptor: MeetingNotesDescriptor(
                recordingID: document.recordingID,
                audioVersion: document.audioVersion,
                generatedAtMillis: Self.milliseconds(since1970: document.generatedAt),
                revision: Self.sha256Hex(data),
                byteCount: data.count
            )
        )
    }

    private func readMeetingNotesData(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else {
            throw SyncError.invalidResponse
        }
        guard size <= URLSessionSyncTransport.maxMeetingNotesByteCount else {
            throw SyncError.transferFailed("Meeting notes are larger than the 2 MiB sync limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: URLSessionSyncTransport.maxMeetingNotesByteCount + 1) ?? Data()
        guard data.count > 0 else {
            throw SyncError.invalidResponse
        }
        guard data.count <= URLSessionSyncTransport.maxMeetingNotesByteCount else {
            throw SyncError.transferFailed("Meeting notes are larger than the 2 MiB sync limit.")
        }
        return data
    }

    private func validateDownloadedMeetingNotes(_ data: Data, descriptor: MeetingNotesDescriptor, recording: Recording) throws {
        guard data.count == descriptor.byteCount,
              data.count > 0,
              data.count <= URLSessionSyncTransport.maxMeetingNotesByteCount,
              Self.sha256Hex(data) == descriptor.revision
        else {
            throw SyncError.invalidResponse
        }
        let document = try meetingNotesDecoder.decode(MeetingNotesDocument.self, from: data)
        guard document.schemaVersion == 1,
              document.recordingID == descriptor.recordingID,
              document.audioVersion == descriptor.audioVersion,
              document.audioVersion == recording.audioVersion,
              Self.milliseconds(since1970: document.generatedAt) == descriptor.generatedAtMillis
        else {
            throw SyncError.invalidResponse
        }
    }

    private func meetingNotesURL(for recordingID: UUID, library: LibraryStore) -> URL {
        library.paths.directory(for: recordingID).appending(path: "meeting-notes.json")
    }

    private func isLocallyPurged(_ recordingID: UUID, library: LibraryStore) -> Bool {
        FileManager.default.fileExists(atPath: library.paths.directory(for: recordingID).appending(path: ".purged").path)
    }

    private var meetingNotesDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct MeetingNotesKey: Hashable, Comparable {
    let recordingID: UUID
    let audioVersion: Int

    static func < (lhs: MeetingNotesKey, rhs: MeetingNotesKey) -> Bool {
        if lhs.recordingID.uuidString == rhs.recordingID.uuidString {
            return lhs.audioVersion < rhs.audioVersion
        }
        return lhs.recordingID.uuidString < rhs.recordingID.uuidString
    }
}

private struct LocalMeetingNotes {
    let document: MeetingNotesDocument
    let data: Data
    let descriptor: MeetingNotesDescriptor
}

private extension MeetingNotesDescriptor {
    var key: MeetingNotesKey {
        MeetingNotesKey(recordingID: recordingID, audioVersion: audioVersion)
    }

    func wins(over other: MeetingNotesDescriptor?) -> Bool {
        guard let other else { return true }
        if generatedAtMillis != other.generatedAtMillis {
            return generatedAtMillis > other.generatedAtMillis
        }
        return revision > other.revision
    }
}
