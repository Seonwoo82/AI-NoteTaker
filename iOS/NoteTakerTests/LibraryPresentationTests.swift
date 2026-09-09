import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Test("library filters keep deleted notes out of active search and favorites")
func libraryFiltersRespectDeletionAndSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root))
    try library.add(Recording(title: "Weekly meeting", duration: 10, mode: .micOnly, isFavorite: true))
    try library.add(Recording(title: "Walking ideas", duration: 20, mode: .micOnly))
    try library.add(Recording(title: "Old meeting", duration: 30, mode: .micOnly, isFavorite: true, deletedAt: .now))

    #expect(LibraryFilter.all.recordings(in: library, search: "MEETING").map(\.title) == ["Weekly meeting"])
    #expect(LibraryFilter.favorites.recordings(in: library, search: "").map(\.title) == ["Weekly meeting"])
    #expect(LibraryFilter.deleted.recordings(in: library, search: "meeting").map(\.title) == ["Old meeting"])
}

@MainActor
@Test("creating an empty folder preserves the current library filter selection and playback")
func creatingEmptyFolderPreservesCurrentLibraryState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = LibraryAppModel(services: .uiTesting(), aiEnvironment: .testing())
    await model.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
    let library = try #require(model.library)
    let first = Recording(title: "First", duration: 10, mode: .micOnly)
    let second = Recording(title: "Second", duration: 20, mode: .micOnly)
    try library.add(first)
    try library.add(second)
    model.selection = second.id
    model.player.recordingID = second.id
    model.player.isPlaying = true

    let folder = try #require(model.createFolder(named: "Project"))

    #expect(model.activeCustomFolders.map(\.id) == [folder.id])
    #expect(model.filter == .all)
    #expect(model.selectedCustomFolderID == nil)
    #expect(Set(model.visibleRecordings.map(\.id)) == [first.id, second.id])
    #expect(model.selection == second.id)
    #expect(model.player.recordingID == second.id)
    #expect(model.player.isPlaying)
}

@MainActor
@Test("selecting All Recordings returns from a custom folder to the full active library")
func selectingAllRecordingsReturnsFromCustomFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = LibraryAppModel(services: .uiTesting(), aiEnvironment: .testing())
    await model.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
    let library = try #require(model.library)
    let folder = try #require(model.createFolder(named: "Project"))
    var filed = Recording(title: "Filed", duration: 10, mode: .micOnly)
    filed.folderID = folder.id
    let unfiled = Recording(title: "Unfiled", duration: 20, mode: .micOnly)
    try library.add(filed)
    try library.add(unfiled)

    model.selectCustomFolder(folder.id)
    #expect(model.selectedCustomFolderID == folder.id)
    #expect(model.visibleRecordings.map(\.id) == [filed.id])

    model.selectFilter(.all)

    #expect(model.filter == .all)
    #expect(model.selectedCustomFolderID == nil)
    #expect(Set(model.visibleRecordings.map(\.id)) == [filed.id, unfiled.id])
}
