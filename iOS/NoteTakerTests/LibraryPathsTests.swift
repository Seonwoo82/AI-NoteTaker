import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Test("LibraryPaths explicit root wins over arguments")
func libraryPathsExplicitRootWinsOverArguments() {
    let explicit = URL(filePath: "/tmp/explicit", directoryHint: .isDirectory)
    let paths = LibraryPaths(
        libraryRoot: explicit,
        arguments: ["NoteTaker", "-libraryRoot", "/tmp/from-arguments"]
    )

    #expect(paths.libraryRoot == explicit)
}

@Test("LibraryPaths parses library root argument")
func libraryPathsParsesLibraryRootArgument() {
    let paths = LibraryPaths(arguments: ["NoteTaker", "-libraryRoot", "/tmp/example"])

    #expect(paths.libraryRoot == URL(filePath: "/tmp/example", directoryHint: .isDirectory))
}

@Test("LibraryPaths builds exact recording metadata paths")
func libraryPathsBuildsExactRecordingMetadataPaths() throws {
    let id = try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000"))
    let root = URL(filePath: "/tmp/library", directoryHint: .isDirectory)
    let paths = LibraryPaths(libraryRoot: root, arguments: [])

    #expect(paths.recordingsRoot == root.appending(path: "Recordings", directoryHint: .isDirectory))
    #expect(paths.directory(for: id) == root.appending(path: "Recordings/\(id.uuidString)", directoryHint: .isDirectory))
    #expect(paths.metadataURL(for: id) == root.appending(path: "Recordings/\(id.uuidString)/meta.json"))
}
