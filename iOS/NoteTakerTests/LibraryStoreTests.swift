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
@Test("LibraryStore open returns empty library for new temp root")
func libraryStoreOpenReturnsEmptyLibraryForNewTempRoot() async {
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: []))

    #expect(store.recordings == [])
}

@MainActor
@Test("LibraryStore open loads valid metadata newest first and skips malformed metadata")
func libraryStoreOpenLoadsValidMetadataNewestFirstAndSkipsMalformedMetadata() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let older = recording(
        id: try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-111111111111")),
        title: "Older",
        createdAt: Date(timeIntervalSince1970: 100)
    )
    let newer = recording(
        id: try #require(UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-222222222222")),
        title: "Newer",
        createdAt: Date(timeIntervalSince1970: 200)
    )
    let brokenID = try #require(UUID(uuidString: "FFFFFFFF-0000-1111-2222-333333333333"))

    try JSONFile.save(older, to: paths.metadataURL(for: older.id))
    try JSONFile.save(newer, to: paths.metadataURL(for: newer.id))
    try FileManager.default.createDirectory(at: paths.directory(for: brokenID), withIntermediateDirectories: true)
    try Data(#"{"not":"recording"}"#.utf8).write(to: paths.metadataURL(for: brokenID))

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recordings.map(\.id) == [newer.id, older.id])
}

@MainActor
@Test("LibraryStore add writes metadata and survives reopen")
func libraryStoreAddWritesMetadataAndSurvivesReopen() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let added = recording(title: "Added")

    try store.add(added)

    #expect(FileManager.default.fileExists(atPath: paths.metadataURL(for: added.id).path))
    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.recording(id: added.id) == added)
}

@MainActor
@Test("LibraryStore update persists changed recording")
func libraryStoreUpdatePersistsChangedRecording() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    var stored = recording(title: "Before")
    try store.add(stored)

    stored.title = "After"
    try store.update(stored)

    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.recording(id: stored.id)?.title == "After")
}

@MainActor
@Test("LibraryStore update of unknown recording throws typed not found error")
func libraryStoreUpdateOfUnknownRecordingThrowsTypedNotFoundError() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let missing = try #require(UUID(uuidString: "ABABABAB-CDCD-EFEF-0101-232323232323"))

    do {
        try store.update(recording(id: missing, title: "Missing"))
        Issue.record("Expected updating an unknown recording to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .recordingNotFound(missing))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }
}

@MainActor
@Test("LibraryStore nextTitle uses explicit Korean base and includes deleted recordings")
func libraryStoreNextTitleUsesExplicitKoreanBaseAndIncludesDeletedRecordings() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let empty = await LibraryStore.open(paths: paths)
    #expect(empty.nextTitle(base: "새로운 녹음") == "새로운 녹음")

    try empty.add(recording(title: "새로운 녹음"))
    try empty.add(recording(title: "새로운 녹음 2"))
    try empty.add(recording(title: "새로운 녹음 7", deletedAt: Date(timeIntervalSince1970: 300)))

    #expect(empty.nextTitle(base: "새로운 녹음") == "새로운 녹음 8")
}

private func recording(
    id: UUID = UUID(),
    title: String = "Recording",
    createdAt: Date = Date(timeIntervalSince1970: 100),
    deletedAt: Date? = nil
) -> Recording {
    Recording(
        id: id,
        title: title,
        createdAt: createdAt,
        duration: 10,
        mode: CaptureMode.micAndSystem,
        deletedAt: deletedAt
    )
}

private func uniqueLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerLibraryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
