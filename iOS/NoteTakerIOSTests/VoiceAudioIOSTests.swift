import Foundation
import Testing
@testable import NoteTakerIOS

@MainActor
@Test("iOS shared library stores microphone recordings with the shared metadata model")
func iOSSharedLibraryStoresMicrophoneRecordingsWithSharedMetadataModel() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueIOSVoiceLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    let recorder = VoiceRecorder(backend: IOSStubRecordingBackend(
        id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
        duration: 4.5
    ))

    await recorder.start(library: store, mode: .micOnly)
    let recording = await recorder.finish(library: store)

    #expect(recording?.id == UUID(uuidString: "33333333-4444-5555-6666-777777777777"))
    #expect(recording?.mode == .micOnly)
    #expect(recording?.duration == 4.5)
    #expect(store.recordings.count == 1)
    #expect(FileManager.default.fileExists(atPath: paths.directory(for: store.recordings[0].id).appending(path: "audio.m4a").path))
}

private func uniqueIOSVoiceLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerIOSVoiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
private final class IOSStubRecordingBackend: VoiceRecordingBackend {
    let id: UUID
    let duration: TimeInterval

    init(id: UUID, duration: TimeInterval) {
        self.id = id
        self.duration = duration
    }

    func makeRecordingID() -> UUID {
        id
    }

    func start(outputURL: URL, mode: CaptureMode, interruptionHandler: @escaping @MainActor @Sendable () async -> Void) async throws -> any VoiceRecordingSession {
        IOSStubRecordingSession(outputURL: outputURL, duration: duration)
    }
}

@MainActor
private final class IOSStubRecordingSession: VoiceRecordingSession {
    let outputURL: URL
    let duration: TimeInterval
    let canPause = true

    init(outputURL: URL, duration: TimeInterval) {
        self.outputURL = outputURL
        self.duration = duration
    }

    func pause() throws {}
    func resume() throws {}

    func finish() async throws -> VoiceRecordingResult {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: outputURL)
        return VoiceRecordingResult(duration: duration, warnings: [])
    }

    func cancel() async {}
}
