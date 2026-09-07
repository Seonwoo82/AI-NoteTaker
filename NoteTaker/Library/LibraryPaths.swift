import Foundation

nonisolated struct LibraryPaths: Equatable, Sendable {
    let libraryRoot: URL

    var recordingsRoot: URL {
        libraryRoot.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    init(libraryRoot: URL? = nil, arguments: [String] = ProcessInfo.processInfo.arguments) {
        if let libraryRoot {
            self.libraryRoot = libraryRoot
        } else if let root = Self.libraryRootArgument(in: arguments) {
            self.libraryRoot = root
        } else {
            self.libraryRoot = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "NoteTaker", directoryHint: .isDirectory)
        }
    }

    func directory(for id: UUID) -> URL {
        recordingsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func metadataURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "meta.json")
    }

    func audioURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "audio.m4a")
    }

    func segmentsDirectory(for id: UUID) -> URL {
        directory(for: id).appending(path: "segments", directoryHint: .isDirectory)
    }

    func segmentURL(for id: UUID, index: Int) -> URL {
        segmentsDirectory(for: id).appending(path: String(format: "%03d.m4a", index))
    }

    func previewURL(for id: UUID) -> URL {
        segmentsDirectory(for: id).appending(path: "preview.m4a")
    }

    private static func libraryRootArgument(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-libraryRoot"),
              arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        return URL(filePath: arguments[arguments.index(after: index)], directoryHint: .isDirectory)
    }
}
