import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated enum LibraryFileActions {
    static let audioContentType = UTType(importedAs: "public.mpeg-4-audio")

    static func safeAudioFilename(for title: String) -> String {
        let sanitized = title
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "/"
                    || scalar == ":"
                {
                    return "-"
                }
                return Character(scalar)
            }
        let base = String(sanitized)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
        return "\((base.isEmpty ? String(localized: "Recording") : base)).m4a"
    }

    static func copyAudio(from source: URL, to destination: URL) throws {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedSource.path != resolvedDestination.path else {
            throw CocoaError(.fileWriteFileExists)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            if (try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func temporarySharedAudioCopy(from source: URL, title: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerExports", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: safeAudioFilename(for: title))
        try copyAudio(from: source, to: destination)
        return destination
    }

    @MainActor
    static func exportAudio(recording: Recording, source: URL) async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.audioContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeAudioFilename(for: recording.title)
        panel.isExtensionHidden = false

        guard await panel.begin() == .OK, let destination = panel.url else { return }
        try copyAudio(from: source, to: destination)
    }
}

nonisolated struct SharedAudioFile: Transferable {
    let sourceURL: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: LibraryFileActions.audioContentType) { file in
            SentTransferredFile(try file.temporaryCopy())
        }
    }

    private func temporaryCopy() throws -> URL {
        try LibraryFileActions.temporarySharedAudioCopy(from: sourceURL, title: title)
    }
}
