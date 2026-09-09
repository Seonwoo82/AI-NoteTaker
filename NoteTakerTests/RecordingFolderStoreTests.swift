#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Test("folder store persists active folders and tombstones across reopen")
func folderStorePersistsActiveFoldersAndTombstonesAcrossReopen() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)

    let folder = try store.folderStore.create(name: "  Clients  ")
    try store.folderStore.rename(id: folder.id, name: "Clients 2026")
    try store.folderStore.delete(id: folder.id)

    #expect(store.folderStore.activeFolders.isEmpty)
    #expect(store.folderStore.folder(id: folder.id)?.deletedAt != nil)

    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.folderStore.activeFolders.isEmpty)
    #expect(reopened.folderStore.folder(id: folder.id)?.name == "Clients 2026")
    #expect(reopened.folderStore.folder(id: folder.id)?.deletedAt != nil)
}

@MainActor
@Test("folder store rejects duplicate live names and keeps memory unchanged after failed write")
func folderStoreRejectsDuplicateLiveNamesAndKeepsMemoryUnchangedAfterFailedWrite() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let folder = try store.folderStore.create(name: "Projects")

    #expect(throws: RecordingFolderStoreError.self) {
        try store.folderStore.create(name: " projects ")
    }

    try FileManager.default.removeItem(at: paths.libraryRoot.appending(path: "recording-folders.json"))
    try FileManager.default.createDirectory(
        at: paths.libraryRoot.appending(path: "recording-folders.json"),
        withIntermediateDirectories: false
    )

    #expect(throws: RecordingFolderStoreError.self) {
        try store.folderStore.rename(id: folder.id, name: "Renamed")
    }
    #expect(store.folderStore.folder(id: folder.id)?.name == "Projects")
}

@MainActor
@Test("folder store refuses to overwrite malformed existing metadata")
func folderStoreRefusesToOverwriteMalformedExistingMetadata() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let metadataURL = paths.libraryRoot.appending(path: "recording-folders.json")
    try FileManager.default.createDirectory(at: paths.libraryRoot, withIntermediateDirectories: true)
    try Data(#"{"folders":"not an array"}"#.utf8).write(to: metadataURL)

    let store = await LibraryStore.open(paths: paths)

    #expect(throws: RecordingFolderStoreError.self) {
        try store.folderStore.create(name: "Recovered")
    }
    #expect(try Data(contentsOf: metadataURL) == Data(#"{"folders":"not an array"}"#.utf8))
}

@MainActor
@Test("folder store rejects oversized names before writing")
func folderStoreRejectsWritesOverBoundedMetadataSize() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let longName = String(repeating: "가", count: 171)

    #expect(throws: RecordingFolderStoreError.self) {
        try store.folderStore.create(name: longName)
    }
    #expect(store.folderStore.activeFolders.isEmpty)
}

@MainActor
@Test("a folder collection larger than the old 64KiB limit survives reopening")
func largeFolderCollectionSurvivesReopening() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    for index in 0..<160 { try store.folderStore.create(name: "\(index)-" + String(repeating: "가", count: 115)) }
    let size = try Data(contentsOf: paths.libraryRoot.appending(path: "recording-folders.json")).count
    #expect(size > 64 * 1024)
    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.folderStore.activeFolders.count == 160)
    #expect(!reopened.folderStore.isActive(id: UUID()))
}

@MainActor
@Test("library move recording sets and clears explicit folder assignment")
func libraryMoveRecordingSetsAndClearsExplicitFolderAssignment() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let folder = try store.folderStore.create(name: "Calls")
    let recording = folderRecording(id: try #require(UUID(uuidString: "12345678-1234-4234-9234-123456789ABC")))
    try store.add(recording)

    try store.moveRecording(id: recording.id, toFolder: folder.id)
    #expect(store.recording(id: recording.id)?.folderID == folder.id)
    #expect(store.recording(id: recording.id)?.folderAssignment == RecordingFolderAssignment(id: folder.id))

    try store.moveRecording(id: recording.id, toFolder: nil)
    #expect(store.recording(id: recording.id)?.folderID == nil)
    #expect(store.recording(id: recording.id)?.folderAssignment == RecordingFolderAssignment(id: nil))
}

@MainActor
@Test("folder store merges each folder by last write wins")
func folderStoreMergesEachFolderByLastWriteWins() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueFolderLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let id = try #require(UUID(uuidString: "ABCDEF12-3456-4789-9ABC-DEF123456789"))
    let stale = RecordingCollectionFolder(
        id: id,
        name: "Stale",
        createdAt: Date(timeIntervalSince1970: 10),
        modifiedAt: 10,
        mutationID: "11111111-2222-4333-8444-555555555555"
    )
    let winner = RecordingCollectionFolder(
        id: id,
        name: "Winner",
        createdAt: Date(timeIntervalSince1970: 10),
        modifiedAt: 20,
        mutationID: "11111111-2222-4333-8444-555555555556"
    )

    try store.folderStore.applyRemote(stale)
    try store.folderStore.applyRemote(winner)
    try store.folderStore.applyRemote(stale)

    #expect(store.folderStore.folder(id: id)?.name == "Winner")
    #expect(store.folderStore.activeFolders.map(\.id) == [id])
}

@Test("legacy recording metadata decodes without an explicit folder assignment")
func legacyRecordingMetadataDecodesWithoutExplicitFolderAssignment() throws {
    let id = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    let data = try #require("""
    {
      "schemaVersion": 1,
      "id": "\(id.uuidString)",
      "title": "Legacy",
      "createdAt": "2026-09-02T01:02:03Z",
      "duration": 42.5,
      "mode": "micOnly"
    }
    """.data(using: .utf8))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let recording = try decoder.decode(Recording.self, from: data)

    #expect(recording.folderID == nil)
    #expect(recording.folderAssignment == nil)
}

@Test("recording folder assignment round trips and explicit clear is encoded")
func recordingFolderAssignmentRoundTripsAndExplicitClearIsEncoded() throws {
    var assigned = folderRecording()
    assigned.folderID = try #require(UUID(uuidString: "22222222-3333-4444-8555-666666666666"))
    var cleared = assigned
    cleared.folderID = nil
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let assignedRoundTrip = try decoder.decode(Recording.self, from: encoder.encode(assigned))
    let clearedRoundTrip = try decoder.decode(Recording.self, from: encoder.encode(cleared))

    #expect(assignedRoundTrip.folderID == assigned.folderID)
    #expect(clearedRoundTrip.folderAssignment == RecordingFolderAssignment(id: nil))
}

private func folderRecording(
    id: UUID = UUID(),
    title: String = "Folder Recording"
) -> Recording {
    Recording(
        id: id,
        title: title,
        createdAt: Date(timeIntervalSince1970: 100),
        duration: 10,
        mode: .micOnly,
        modifiedAt: 1_000,
        mutationID: "33333333-4444-4555-8666-777777777777"
    )
}

private func uniqueFolderLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
