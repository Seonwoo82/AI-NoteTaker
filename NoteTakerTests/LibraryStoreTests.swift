import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

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
@Test("LibraryStore open skips metadata whose ID does not match its UUID directory")
func libraryStoreOpenSkipsMetadataWhoseIDDoesNotMatchItsUUIDDirectory() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let directoryID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let metadataID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let mismatched = recording(id: metadataID, title: "Mismatched")

    try JSONFile.save(mismatched, to: paths.directory(for: directoryID).appending(path: "meta.json"))

    let store = await LibraryStore.open(paths: paths, now: distantReferenceDate)

    #expect(store.recordings.isEmpty)
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
@Test("LibraryStore add rejects duplicate IDs without replacing the original")
func libraryStoreAddRejectsDuplicateIDsWithoutReplacingTheOriginal() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let id = try #require(UUID(uuidString: "22222222-3333-4444-5555-666666666666"))
    let original = recording(id: id, title: "Original")
    let duplicate = recording(id: id, title: "Duplicate")
    try store.add(original)

    do {
        try store.add(duplicate)
        Issue.record("Expected adding a duplicate recording ID to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .duplicateRecording(id))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    #expect(store.recordings == [original])
    #expect(try JSONFile.load(Recording.self, from: paths.metadataURL(for: id)).title == "Original")
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
@Test("LibraryStore named mutations persist and compose with smart folders")
func libraryStoreNamedMutationsPersistAndComposeWithSmartFolders() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let id = try #require(UUID(uuidString: "33333333-4444-5555-6666-777777777777"))
    let original = recording(id: id, title: "Draft", createdAt: Date(timeIntervalSince1970: 400))
    let originalBytes = Data("selected audio bytes".utf8)
    try saveFixture(original, audio: originalBytes, paths: paths)
    let loaded = await LibraryStore.open(paths: paths, now: distantReferenceDate)

    try loaded.rename(id: id, to: "  회의 Budget  ")
    try loaded.setFavorite(id: id, isFavorite: true)
    try loaded.moveToRecentlyDeleted(id: id, now: referenceDate)

    #expect(loaded.filteredRecordings(in: .all).isEmpty)
    #expect(loaded.filteredRecordings(in: .favorites).isEmpty)
    #expect(loaded.filteredRecordings(in: .recentlyDeleted).map(\.id) == [id])
    #expect(try Data(contentsOf: paths.audioURL(for: id)) == originalBytes)

    let reopenedDeleted = await LibraryStore.open(paths: paths, now: referenceDate)
    #expect(reopenedDeleted.recording(id: id)?.title == "회의 Budget")
    #expect(reopenedDeleted.recording(id: id)?.isFavorite == true)
    #expect(reopenedDeleted.recording(id: id)?.deletedAt == referenceDate)
    #expect(reopenedDeleted.filteredRecordings(in: .all).isEmpty)

    try reopenedDeleted.restore(id: id)

    #expect(reopenedDeleted.filteredRecordings(in: .all).map(\.id) == [id])
    #expect(reopenedDeleted.filteredRecordings(in: .favorites).map(\.id) == [id])
    #expect(reopenedDeleted.filteredRecordings(in: .recentlyDeleted).isEmpty)
    #expect(try Data(contentsOf: paths.audioURL(for: id)) == originalBytes)

    let reopenedRestored = await LibraryStore.open(paths: paths, now: distantReferenceDate)
    #expect(reopenedRestored.recording(id: id)?.deletedAt == nil)
    #expect(reopenedRestored.filteredRecordings(in: .favorites, matching: " budget ").map(\.id) == [id])
    #expect(reopenedRestored.filteredRecordings(in: .all, matching: "회의").map(\.id) == [id])
}

@MainActor
@Test("LibraryStore search trims query and is localized case insensitive within each folder")
func libraryStoreSearchTrimsQueryAndIsLocalizedCaseInsensitiveWithinEachFolder() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let allMatch = recording(
        id: try #require(UUID(uuidString: "44444444-5555-6666-7777-888888888888")),
        title: "회의 Budget",
        createdAt: Date(timeIntervalSince1970: 300)
    )
    let favoriteMatch = recording(
        id: try #require(UUID(uuidString: "55555555-6666-7777-8888-999999999999")),
        title: "예산 Review",
        createdAt: Date(timeIntervalSince1970: 200),
        isFavorite: true
    )
    let deletedMatch = recording(
        id: try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")),
        title: "budget Archive",
        createdAt: Date(timeIntervalSince1970: 100),
        isFavorite: true,
        deletedAt: referenceDate
    )

    try saveFixture(allMatch, paths: paths)
    try saveFixture(favoriteMatch, paths: paths)
    try saveFixture(deletedMatch, paths: paths)

    let store = await LibraryStore.open(paths: paths, now: referenceDate)

    #expect(store.filteredRecordings(in: .all, matching: " budget ").map(\.id) == [allMatch.id])
    #expect(store.filteredRecordings(in: .favorites, matching: "예산").map(\.id) == [favoriteMatch.id])
    #expect(store.filteredRecordings(in: .recentlyDeleted, matching: "BUDGET").map(\.id) == [deletedMatch.id])
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
@Test("LibraryStore named mutations reject missing IDs and invalid deleted item edits")
func libraryStoreNamedMutationsRejectMissingIDsAndInvalidDeletedItemEdits() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let missing = try #require(UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB"))
    let deletedID = try #require(UUID(uuidString: "88888888-9999-AAAA-BBBB-CCCCCCCCCCCC"))
    let deleted = recording(id: deletedID, title: "Deleted", deletedAt: referenceDate)
    try store.add(deleted)

    for operation in missingIDOperations(missing, on: store) {
        do {
            try operation()
            Issue.record("Expected missing ID operation to throw")
        } catch let error as LibraryStoreError {
            #expect(error == .recordingNotFound(missing))
        } catch {
            Issue.record("Expected LibraryStoreError, got \(error)")
        }
    }

    do {
        try store.rename(id: deletedID, to: "Renamed")
        Issue.record("Expected rename of deleted recording to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .recordingDeleted(deletedID))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    do {
        try store.setFavorite(id: deletedID, isFavorite: false)
        Issue.record("Expected favorite edit of deleted recording to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .recordingDeleted(deletedID))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    do {
        var edited = deleted
        edited.title = "Updated"
        try store.update(edited)
        Issue.record("Expected update of deleted recording to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .recordingDeleted(deletedID))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }
}

@MainActor
@Test("LibraryStore rename rejects empty trimmed titles")
func libraryStoreRenameRejectsEmptyTrimmedTitles() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let stored = recording(title: "Original")
    try store.add(stored)

    do {
        try store.rename(id: stored.id, to: " \n\t ")
        Issue.record("Expected empty title rename to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .emptyTitle)
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    #expect(store.recording(id: stored.id)?.title == "Original")
}

@MainActor
@Test("LibraryStore failed metadata write leaves memory unchanged")
func libraryStoreFailedMetadataWriteLeavesMemoryUnchanged() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let stored = recording(title: "Before")
    try store.add(stored)
    try FileManager.default.removeItem(at: paths.metadataURL(for: stored.id))
    try FileManager.default.createDirectory(at: paths.metadataURL(for: stored.id), withIntermediateDirectories: true)

    do {
        try store.rename(id: stored.id, to: "After")
        Issue.record("Expected metadata write failure to throw")
    } catch {
        #expect(store.recording(id: stored.id)?.title == "Before")
    }
}

@MainActor
@Test("LibraryStore permanent deletion requires deleted item and removes only selected deleted directory")
func libraryStorePermanentDeletionRequiresDeletedItemAndRemovesOnlySelectedDeletedDirectory() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let active = recording(
        id: try #require(UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")),
        title: "Active"
    )
    let deleted = recording(
        id: try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF")),
        title: "Deleted",
        deletedAt: referenceDate
    )
    let otherDeleted = recording(
        id: try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-000000000000")),
        title: "Other Deleted",
        deletedAt: referenceDate
    )
    try saveFixture(active, audio: Data("active".utf8), paths: paths)
    try saveFixture(deleted, audio: Data("deleted".utf8), paths: paths)
    try saveFixture(otherDeleted, audio: Data("other".utf8), paths: paths)
    let unknownDirectory = paths.recordingsRoot.appending(path: "not-a-recording", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)

    let store = await LibraryStore.open(paths: paths, now: referenceDate)

    do {
        try store.deletePermanently(id: active.id)
        Issue.record("Expected active permanent deletion to throw")
    } catch let error as LibraryStoreError {
        #expect(error == .recordingNotDeleted(active.id))
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    try store.deletePermanently(id: deleted.id)

    #expect(FileManager.default.fileExists(atPath: paths.directory(for: active.id).path))
    #expect(!FileManager.default.fileExists(atPath: paths.directory(for: deleted.id).path))
    #expect(FileManager.default.fileExists(atPath: paths.directory(for: otherDeleted.id).path))
    #expect(FileManager.default.fileExists(atPath: unknownDirectory.path))
    #expect(store.recordings.map(\.id).contains(deleted.id) == false)
}

@MainActor
@Test("LibraryStore failed permanent deletion leaves deleted recording visible")
func libraryStoreFailedPermanentDeletionLeavesDeletedRecordingVisible() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let deleted = recording(
        id: try #require(UUID(uuidString: "B0B0B0B0-C0C0-D0D0-E0E0-F0F0F0F0F0F0")),
        title: "Deleted",
        deletedAt: referenceDate
    )
    try saveFixture(deleted, paths: paths)
    let store = await LibraryStore.open(paths: paths, now: referenceDate)
    try FileManager.default.removeItem(at: paths.directory(for: deleted.id))

    do {
        try store.deletePermanently(id: deleted.id)
        Issue.record("Expected missing directory removal to throw")
    } catch let error as LibraryStoreError {
        guard case .deletionFailed(deleted.id, _) = error else {
            Issue.record("Expected deletionFailed, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LibraryStoreError, got \(error)")
    }

    #expect(store.filteredRecordings(in: .recentlyDeleted).map(\.id) == [deleted.id])
}

@MainActor
@Test("LibraryStore purge keeps 29d23h deleted entries and removes 30d entries")
func libraryStorePurgeKeeps29d23hDeletedEntriesAndRemoves30dEntries() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueLibraryRoot(), arguments: [])
    let now = Date(timeIntervalSince1970: 3_000_000)
    let kept = recording(
        id: try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-111111111111")),
        title: "Kept",
        deletedAt: now.addingTimeInterval(-((29 * 24 + 23) * 60 * 60))
    )
    let purged = recording(
        id: try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-0000-222222222222")),
        title: "Purged",
        deletedAt: now.addingTimeInterval(-(30 * 24 * 60 * 60))
    )
    let activeOld = recording(
        id: try #require(UUID(uuidString: "EEEEEEEE-FFFF-0000-1111-333333333333")),
        title: "Active Old"
    )
    try saveFixture(kept, paths: paths)
    try saveFixture(purged, paths: paths)
    try saveFixture(activeOld, paths: paths)

    let store = await LibraryStore.open(paths: paths, now: now)

    #expect(store.recordings.map(\.id).sorted(by: uuidStringAscending) == [activeOld.id, kept.id].sorted(by: uuidStringAscending))
    #expect(FileManager.default.fileExists(atPath: paths.directory(for: kept.id).path))
    #expect(!FileManager.default.fileExists(atPath: paths.directory(for: purged.id).path))
    #expect(FileManager.default.fileExists(atPath: paths.directory(for: activeOld.id).path))
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

private let referenceDate = Date(timeIntervalSince1970: 1_000_000)
private let distantReferenceDate = Date(timeIntervalSince1970: 2_000_000)

private func recording(
    id: UUID = UUID(),
    title: String = "Recording",
    createdAt: Date = Date(timeIntervalSince1970: 100),
    isFavorite: Bool = false,
    deletedAt: Date? = nil
) -> Recording {
    Recording(
        id: id,
        title: title,
        createdAt: createdAt,
        duration: 10,
        mode: CaptureMode.micAndSystem,
        isFavorite: isFavorite,
        deletedAt: deletedAt
    )
}

private func saveFixture(
    _ recording: Recording,
    audio: Data = Data("audio".utf8),
    paths: LibraryPaths
) throws {
    try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
    try audio.write(to: paths.audioURL(for: recording.id))
    try JSONFile.save(recording, to: paths.metadataURL(for: recording.id))
}

@MainActor
private func missingIDOperations(_ id: UUID, on store: LibraryStore) -> [() throws -> Void] {
    [
        { try store.rename(id: id, to: "Missing") },
        { try store.setFavorite(id: id, isFavorite: true) },
        { try store.moveToRecentlyDeleted(id: id, now: referenceDate) },
        { try store.restore(id: id) },
        { try store.deletePermanently(id: id) }
    ]
}

private func uuidStringAscending(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}

private func uniqueLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerLibraryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
