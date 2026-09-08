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
