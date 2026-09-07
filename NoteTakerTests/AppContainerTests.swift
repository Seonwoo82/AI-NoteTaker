import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Test("AppContainer load opens the library and selects the newest recording")
func appContainerLoadOpensLibraryAndSelectsNewestRecording() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueAppContainerLibraryRoot(), arguments: [])
    let older = Recording(
        id: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
        title: "Older",
        createdAt: Date(timeIntervalSince1970: 100),
        duration: 4,
        mode: CaptureMode.micOnly
    )
    let newest = Recording(
        id: try #require(UUID(uuidString: "22222222-3333-4444-5555-666666666666")),
        title: "Newest",
        createdAt: Date(timeIntervalSince1970: 200),
        duration: 8,
        mode: CaptureMode.micAndSystem
    )
    try JSONFile.save(older, to: paths.metadataURL(for: older.id))
    try JSONFile.save(newest, to: paths.metadataURL(for: newest.id))

    let container = await AppContainer.load(
        services: AppServices(
            recorder: FakeRecorderEngine(),
            player: FakePlayerEngine(),
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
        ),
        paths: paths
    )

    #expect(container.library.recordings.map(\.id) == [newest.id, older.id])
    #expect(container.model.selectedRecordingID == newest.id)
    #expect(container.library.paths == paths)
    #expect(container.session.phase == .idle)
}

@MainActor
@Test("AppContainer routes recording starts through playback controller stop")
func appContainerRoutesRecordingStartsThroughPlaybackControllerStop() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueAppContainerLibraryRoot(), arguments: [])
    let recording = Recording(title: "Playable", duration: 10, mode: .micOnly)
    try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: paths.audioURL(for: recording.id))
    try JSONFile.save(recording, to: paths.metadataURL(for: recording.id))
    let player = FakePlayerEngine()
    let container = await AppContainer.load(
        services: AppServices(
            recorder: FakeRecorderEngine(),
            player: player,
            audioDeviceProvider: StaticAudioDeviceProvider(inputDevices: [], defaultInputDeviceUID: nil)
        ),
        paths: paths
    )

    try await container.playback.load(recording: recording)
    await container.playback.play()
    await container.session.start()

    #expect(player.stopCallCount == 1)
    #expect(!container.playback.isPlaying)
    #expect(container.playback.currentTime == 0)
    #expect(container.session.phase == .recording)
}

private func uniqueAppContainerLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerAppContainerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
