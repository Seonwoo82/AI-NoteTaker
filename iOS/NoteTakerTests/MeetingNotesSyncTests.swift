import Foundation
import CryptoKit
import Testing

#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Test("meeting notes sync uploads, downloads, and skips unchanged revisions")
func meetingNotesSyncUploadsDownloadsAndSkipsUnchangedRevisions() async throws {
    let server = InMemoryMeetingNotesTransport()
    let first = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    let second = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "81111111-2222-3333-8444-555555555555")),
        audioVersion: 1
    )
    let document = meetingNotesDocument(for: recording, markdown: "# Local", transcript: "Full transcript")
    try first.add(recording)
    try second.applyRemote(recording)
    try writeAudio(in: first, recording: recording)
    try writeMeetingNotes(document, in: first)

    try await SyncEngine(transport: server).sync(library: first)
    var changedIDs: [UUID] = []
    try await SyncEngine(transport: server) { changedIDs.append($0) }.sync(library: second)

    #expect(try readMeetingNotes(in: second, id: recording.id) == document)
    #expect(changedIDs == [recording.id])
    #expect(server.noteUploadCount(for: recording.id, audioVersion: 1) == 1)
    #expect(server.noteDownloadCount(for: recording.id, audioVersion: 1) == 1)

    try await SyncEngine(transport: server).sync(library: second)
    #expect(server.noteUploadCount(for: recording.id, audioVersion: 1) == 1)
    #expect(server.noteDownloadCount(for: recording.id, audioVersion: 1) == 1)
}

@MainActor
@Test("meeting notes corrupt download keeps existing local document")
func meetingNotesCorruptDownloadKeepsExistingLocalDocument() async throws {
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "82222222-3333-4444-8555-666666666666")),
        audioVersion: 1
    )
    let oldDocument = meetingNotesDocument(
        for: recording,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        markdown: "# Old",
        transcript: "Old transcript"
    )
    let remoteDocument = meetingNotesDocument(
        for: recording,
        generatedAt: Date(timeIntervalSince1970: 2_000),
        markdown: "# Remote",
        transcript: "Remote transcript"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try writeAudio(in: store, recording: recording)
    try writeMeetingNotes(oldDocument, in: store)
    let server = InMemoryMeetingNotesTransport()
    try server.storeMeetingNotes(remoteDocument)
    server.corruptNextNoteDownload = true

    await #expect(throws: Error.self) {
        try await SyncEngine(transport: server).sync(library: store)
    }

    #expect(try readMeetingNotes(in: store, id: recording.id) == oldDocument)
}

@MainActor
@Test("meeting notes sync keeps a newer local generation completed during download")
func meetingNotesSyncKeepsNewerLocalGenerationCompletedDuringDownload() async throws {
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "83333333-4444-5555-8666-777777777777")),
        audioVersion: 1
    )
    let oldDocument = meetingNotesDocument(
        for: recording,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        markdown: "# Old",
        transcript: "Old transcript"
    )
    let remoteDocument = meetingNotesDocument(
        for: recording,
        generatedAt: Date(timeIntervalSince1970: 2_000),
        markdown: "# Remote",
        transcript: "Remote transcript"
    )
    let localWinner = meetingNotesDocument(
        for: recording,
        generatedAt: Date(timeIntervalSince1970: 3_000),
        markdown: "# Local winner",
        transcript: "New transcript"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try writeAudio(in: store, recording: recording)
    try writeMeetingNotes(oldDocument, in: store)
    let server = InMemoryMeetingNotesTransport()
    try server.storeMeetingNotes(remoteDocument)
    server.beforeNoteDownload = {
        try writeMeetingNotes(localWinner, in: store)
    }

    try await SyncEngine(transport: server).sync(library: store)

    #expect(try readMeetingNotes(in: store, id: recording.id) == localWinner)
    #expect(server.noteUploadCount(for: recording.id, audioVersion: 1) == 1)
}

@MainActor
@Test("meeting notes sync skips retained remote descriptors for older audio versions")
func meetingNotesSyncSkipsRetainedRemoteDescriptorsForOlderAudioVersions() async throws {
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "84444444-5555-6666-8777-888888888888")),
        audioVersion: 2
    )
    var remoteRecording = recording
    remoteRecording.audioVersion = 1
    let retainedRemoteDocument = meetingNotesDocument(for: remoteRecording, markdown: "# v1", transcript: "v1 transcript")
    let currentDocument = meetingNotesDocument(for: recording, markdown: "# v2", transcript: "v2 transcript")
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try writeAudio(in: store, recording: recording)
    try writeMeetingNotes(currentDocument, in: store)
    let server = InMemoryMeetingNotesTransport()
    try server.storeMeetingNotes(retainedRemoteDocument)

    try await SyncEngine(transport: server).sync(library: store)

    #expect(try readMeetingNotes(in: store, id: recording.id) == currentDocument)
    #expect(server.noteDownloadCount(for: recording.id, audioVersion: 1) == 0)
    #expect(server.noteUploadCount(for: recording.id, audioVersion: 2) == 1)
}

@MainActor
@Test("meeting notes sync keeps oversized local document and continues other notes")
func meetingNotesSyncKeepsOversizedLocalDocumentAndContinuesOtherNotes() async throws {
    let blockedRecording = notesSyncRecording(
        id: try #require(UUID(uuidString: "84444444-5555-6666-8777-999999999999")),
        audioVersion: 1
    )
    let healthyRecording = notesSyncRecording(
        id: try #require(UUID(uuidString: "84444444-5555-6666-8777-AAAAAAAAAAAA")),
        audioVersion: 1
    )
    let remoteReplacement = meetingNotesDocument(
        for: blockedRecording,
        generatedAt: Date(timeIntervalSince1970: 3_000),
        markdown: "# Remote replacement",
        transcript: "Remote replacement transcript"
    )
    let healthyDocument = meetingNotesDocument(for: healthyRecording, markdown: "# Healthy", transcript: "Healthy transcript")
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(blockedRecording)
    try store.add(healthyRecording)
    try writeAudio(in: store, recording: blockedRecording)
    try writeAudio(in: store, recording: healthyRecording)
    let oversizedData = Data(count: URLSessionSyncTransport.maxMeetingNotesByteCount + 1)
    try writeRawMeetingNotes(oversizedData, in: store, id: blockedRecording.id)
    try writeMeetingNotes(healthyDocument, in: store)
    let server = InMemoryMeetingNotesTransport()
    try server.storeMeetingNotes(remoteReplacement)

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: server).sync(library: store)
    }

    #expect(try Data(contentsOf: meetingNotesURL(in: store, id: blockedRecording.id)) == oversizedData)
    #expect(server.noteDownloadCount(for: blockedRecording.id, audioVersion: 1) == 0)
    #expect(server.noteUploadCount(for: healthyRecording.id, audioVersion: 1) == 1)
}

@MainActor
@Test("meeting notes sync skips locally purged recording directories")
func meetingNotesSyncSkipsLocallyPurgedRecordingDirectories() async throws {
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "85555555-6666-7777-8888-999999999999")),
        audioVersion: 1,
        deletedAt: Date(timeIntervalSince1970: 4_000)
    )
    let document = meetingNotesDocument(for: recording, markdown: "# Purged", transcript: "Purged transcript")
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try writeMeetingNotes(document, in: store)
    try Data().write(to: store.paths.directory(for: recording.id).appending(path: ".purged"), options: .atomic)
    let server = InMemoryMeetingNotesTransport()

    try await SyncEngine(transport: server).sync(library: store)

    #expect(server.noteUploadCount(for: recording.id, audioVersion: 1) == 0)
}

@MainActor
@Test("meeting notes sync responds to cancellation before note transfer")
func meetingNotesSyncRespondsToCancellationBeforeNoteTransfer() async throws {
    let recording = notesSyncRecording(
        id: try #require(UUID(uuidString: "86666666-7777-8888-8999-AAAAAAAAAAAA")),
        audioVersion: 1
    )
    let document = meetingNotesDocument(for: recording, markdown: "# Cancel", transcript: "Cancel transcript")
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueNotesSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try writeAudio(in: store, recording: recording)
    try writeMeetingNotes(document, in: store)
    let server = InMemoryMeetingNotesTransport()
    server.beforeNoteUpload = {
        throw CancellationError()
    }

    await #expect(throws: CancellationError.self) {
        try await SyncEngine(transport: server).sync(library: store)
    }
}

private func uniqueNotesSyncLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerNotesSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func notesSyncRecording(id: UUID, audioVersion: Int, deletedAt: Date? = nil) -> Recording {
    Recording(
        id: id,
        title: "Notes Sync",
        createdAt: Date(timeIntervalSince1970: 1_788_310_923),
        duration: 12,
        mode: .micOnly,
        deletedAt: deletedAt,
        audioVersion: audioVersion,
        modifiedAt: 1_788_310_923_000,
        mutationID: id.uuidString.uppercased()
    )
}

private func meetingNotesDocument(
    for recording: Recording,
    generatedAt: Date = Date(timeIntervalSince1970: 1_788_318_245),
    markdown: String,
    transcript: String
) -> MeetingNotesDocument {
    MeetingNotesDocument(
        recordingID: recording.id,
        audioVersion: recording.audioVersion,
        generatedAt: generatedAt,
        modelID: "openai/gpt-test",
        transcriptionModelID: "openai/whisper-test",
        markdown: markdown,
        transcript: transcript,
        costUSD: nil
    )
}

@MainActor
private func writeMeetingNotes(_ document: MeetingNotesDocument, in store: LibraryStore) throws {
    let data = try encodedMeetingNotes(document)
    let url = meetingNotesURL(in: store, id: document.recordingID)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

@MainActor
private func readMeetingNotes(in store: LibraryStore, id: UUID) throws -> MeetingNotesDocument {
    let data = try Data(contentsOf: meetingNotesURL(in: store, id: id))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MeetingNotesDocument.self, from: data)
}

@MainActor
private func meetingNotesURL(in store: LibraryStore, id: UUID) -> URL {
    store.paths.directory(for: id).appending(path: "meeting-notes.json")
}

private func encodedMeetingNotes(_ document: MeetingNotesDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
}

@MainActor
private func writeRawMeetingNotes(_ data: Data, in store: LibraryStore, id: UUID) throws {
    let url = meetingNotesURL(in: store, id: id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

@MainActor
private func writeAudio(in store: LibraryStore, recording: Recording) throws {
    let url = store.audioURL(for: recording)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: url)
}

private func meetingNotesDescriptor(for document: MeetingNotesDocument, data: Data) -> MeetingNotesDescriptor {
    MeetingNotesDescriptor(
        recordingID: document.recordingID,
        audioVersion: document.audioVersion,
        generatedAtMillis: Int64((document.generatedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
        revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        byteCount: data.count
    )
}

@MainActor
private final class InMemoryMeetingNotesTransport: MeetingNotesSyncTransport {
    var beforeNoteDownload: (() throws -> Void)?
    var beforeNoteUpload: (() throws -> Void)?
    var corruptNextNoteDownload = false

    private var recordings: [UUID: Recording] = [:]
    private var audio: [AudioKey: Data] = [:]
    private var notes: [NotesKey: StoredNote] = [:]
    private var noteUploadCounts: [NotesKey: Int] = [:]
    private var noteDownloadCounts: [NotesKey: Int] = [:]

    func health() async throws -> SyncHealth {
        SyncHealth(ok: true, schemaVersion: 1)
    }

    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        SyncRecordingPage(recordings: recordings.values.sorted { $0.id.uuidString < $1.id.uuidString }, nextCursor: nil)
    }

    func putRecording(_ recording: Recording) async throws -> Recording {
        recordings[recording.id] = recording
        return recording
    }

    func uploadAudio(for recording: Recording, from url: URL) async throws {
        audio[AudioKey(recordingID: recording.id, audioVersion: recording.audioVersion)] = try Data(contentsOf: url)
    }

    func downloadAudio(for recording: Recording, to url: URL) async throws {
        guard let data = audio[AudioKey(recordingID: recording.id, audioVersion: recording.audioVersion)] else {
            throw SyncError.missingAudio(recording.id)
        }
        try data.write(to: url)
    }

    func listMeetingNotes(cursor: String?) async throws -> MeetingNotesPage {
        let sorted = notes.values.sorted {
            if $0.descriptor.recordingID.uuidString == $1.descriptor.recordingID.uuidString {
                return $0.descriptor.audioVersion < $1.descriptor.audioVersion
            }
            return $0.descriptor.recordingID.uuidString < $1.descriptor.recordingID.uuidString
        }
        return MeetingNotesPage(notes: sorted.map(\.descriptor), nextCursor: nil)
    }

    func uploadMeetingNotes(_ document: MeetingNotesDocument, data: Data) async throws -> MeetingNotesDescriptor {
        try beforeNoteUpload?()
        try Task.checkCancellation()
        let descriptor = meetingNotesDescriptor(for: document, data: data)
        let key = NotesKey(recordingID: document.recordingID, audioVersion: document.audioVersion)
        if let current = notes[key], current.descriptor.wins(over: descriptor) {
            return current.descriptor
        }
        notes[key] = StoredNote(document: document, data: data, descriptor: descriptor)
        noteUploadCounts[key, default: 0] += 1
        return descriptor
    }

    func downloadMeetingNotes(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws {
        try beforeNoteDownload?()
        let key = NotesKey(recordingID: descriptor.recordingID, audioVersion: descriptor.audioVersion)
        guard let stored = notes[key] else {
            throw SyncError.invalidResponse
        }
        noteDownloadCounts[key, default: 0] += 1
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (corruptNextNoteDownload ? Data("corrupt".utf8) : stored.data).write(to: url)
        corruptNextNoteDownload = false
    }

    func storeMeetingNotes(_ document: MeetingNotesDocument) throws {
        let data = try encodedMeetingNotes(document)
        let descriptor = meetingNotesDescriptor(for: document, data: data)
        notes[NotesKey(recordingID: document.recordingID, audioVersion: document.audioVersion)] = StoredNote(
            document: document,
            data: data,
            descriptor: descriptor
        )
    }

    func noteUploadCount(for recordingID: UUID, audioVersion: Int) -> Int {
        noteUploadCounts[NotesKey(recordingID: recordingID, audioVersion: audioVersion), default: 0]
    }

    func noteDownloadCount(for recordingID: UUID, audioVersion: Int) -> Int {
        noteDownloadCounts[NotesKey(recordingID: recordingID, audioVersion: audioVersion), default: 0]
    }

    private struct AudioKey: Hashable {
        let recordingID: UUID
        let audioVersion: Int
    }

    private struct NotesKey: Hashable {
        let recordingID: UUID
        let audioVersion: Int
    }

    private struct StoredNote {
        let document: MeetingNotesDocument
        let data: Data
        let descriptor: MeetingNotesDescriptor
    }
}

private extension MeetingNotesDescriptor {
    func wins(over other: MeetingNotesDescriptor) -> Bool {
        if generatedAtMillis != other.generatedAtMillis {
            return generatedAtMillis > other.generatedAtMillis
        }
        return revision > other.revision
    }
}
