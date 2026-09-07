import Foundation
import Testing
@testable import NoteTaker

@Suite
struct LibraryFileActionsTests {
    @Test("safe export filename replaces path separators colons and controls")
    func safeExportFilenameReplacesPathSeparatorsColonsAndControls() {
        let filename = LibraryFileActions.safeAudioFilename(for: "Q3/Plan:Review\n")

        #expect(filename == "Q3-Plan-Review.m4a")
    }

    @Test("copy export preserves source bytes and surfaces destination write failure")
    func copyExportPreservesSourceBytesAndSurfacesDestinationWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerLibraryFileActionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.m4a")
        let destination = root.appending(path: "blocked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original audio".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try LibraryFileActions.copyAudio(from: source, to: destination)
            Issue.record("Expected copying over a directory to throw")
        } catch {
            #expect(try Data(contentsOf: source) == Data("original audio".utf8))
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }

        let validDestination = root.appending(path: "export.m4a")
        try LibraryFileActions.copyAudio(from: source, to: validDestination)

        #expect(try Data(contentsOf: source) == Data("original audio".utf8))
        #expect(try Data(contentsOf: validDestination) == Data("original audio".utf8))
    }

    @Test("copy export refuses resolved source destinations")
    func copyExportRefusesResolvedSourceDestinations() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerLibraryFileActionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.m4a")
        let sourceLink = root.appending(path: "source-link.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original audio".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)

        do {
            try LibraryFileActions.copyAudio(from: source, to: source)
            Issue.record("Expected copying to the source file to throw")
        } catch {
            #expect(try Data(contentsOf: source) == Data("original audio".utf8))
        }

        do {
            try LibraryFileActions.copyAudio(from: source, to: sourceLink)
            Issue.record("Expected copying to a symlink resolving to the source file to throw")
        } catch {
            #expect(try Data(contentsOf: source) == Data("original audio".utf8))
        }
    }

    @Test("shared audio copy uses safe title outside recording directory")
    func sharedAudioCopyUsesSafeTitleOutsideRecordingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerLibraryFileActionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let recordingDirectory = root.appending(path: "recording", directoryHint: .isDirectory)
        let source = recordingDirectory.appending(path: "audio.m4a")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        try Data("original audio".utf8).write(to: source)

        let sharedCopy = try LibraryFileActions.temporarySharedAudioCopy(from: source, title: "Q3/Plan:Review")

        #expect(sharedCopy.lastPathComponent == "Q3-Plan-Review.m4a")
        #expect(!sharedCopy.path.hasPrefix(recordingDirectory.path))
        #expect(try Data(contentsOf: sharedCopy) == Data("original audio".utf8))
        #expect(try Data(contentsOf: source) == Data("original audio".utf8))
    }
}
