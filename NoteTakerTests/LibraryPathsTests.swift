import Foundation
import Testing
@testable import NoteTaker

@Suite
struct LibraryPathsTests {
    @Test("LibraryPaths explicit root wins over arguments")
    func explicitRootWinsOverArguments() {
        let explicit = URL(filePath: "/tmp/explicit", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            libraryRoot: explicit,
            arguments: ["NoteTaker", "-libraryRoot", "/tmp/from-arguments"]
        )

        #expect(paths.libraryRoot == explicit)
    }

    @Test("LibraryPaths parses library root argument")
    func parsesLibraryRootArgument() {
        let paths = LibraryPaths(arguments: ["NoteTaker", "-libraryRoot", "/tmp/example"])

        #expect(paths.libraryRoot == URL(filePath: "/tmp/example", directoryHint: .isDirectory))
    }

    @Test("LibraryPaths builds exact recording metadata paths")
    func buildsExactRecordingMetadataPaths() throws {
        let id = try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000"))
        let root = URL(filePath: "/tmp/library", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])

        #expect(paths.recordingsRoot == root.appending(path: "Recordings", directoryHint: .isDirectory))
        #expect(paths.directory(for: id) == root.appending(path: "Recordings/\(id.uuidString)", directoryHint: .isDirectory))
        #expect(paths.metadataURL(for: id) == root.appending(path: "Recordings/\(id.uuidString)/meta.json"))
        #expect(paths.audioURL(for: id) == paths.directory(for: id).appending(path: "audio.m4a"))
        #expect(paths.segmentsDirectory(for: id) == paths.directory(for: id).appending(path: "segments", directoryHint: .isDirectory))
        #expect(paths.segmentURL(for: id, index: 0).lastPathComponent == "000.m4a")
        #expect(paths.previewURL(for: id).lastPathComponent == "preview.m4a")
    }
}
