import Foundation
import Testing
#if canImport(AudioPipeline)
import AudioPipeline
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Test("app exposes existing AI minutes without requiring an API key")
func appExposesExistingAIMinutesWithoutAPIKey() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeAIAppModel(configured: false)
    await model.open(paths: LibraryPaths(libraryRoot: root))
    let library = try #require(model.library)
    let service = try #require(model.meetingNotes)
    let recording = Recording(title: "Meeting", duration: 1, mode: .micOnly)
    try library.add(recording)
    let document = appDocument(recording: recording, markdown: "# Existing minutes", date: 100)
    try JSONFile.save(document, to: library.paths.directory(for: recording.id).appending(path: "meeting-notes.json"))

    await service.load(recording)

    #expect(model.aiConfiguration.hasAPIKey == false)
    #expect(service.document(for: recording.id)?.markdown == "# Existing minutes")
    #expect(service.document(for: recording.id)?.transcript == "Existing transcript")
}

@MainActor
@Test("app automatically generates AI minutes after a recording is finalized")
func appAutomaticallyGeneratesAIMinutesAfterRecordingSave() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeAIAppModel(configured: true)
    await model.open(paths: LibraryPaths(libraryRoot: root))
    await model.startRecording()
    await model.finishRecording()
    let id = try #require(model.selection)
    let service = try #require(model.meetingNotes)
    defer { service.prepareForTermination() }
    for _ in 0..<150 {
        if service.document(for: id) != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }

    let document = try #require(service.document(for: id))
    #expect(document.modelID == "fixture/summary")
    #expect(!document.markdown.isEmpty)
    #expect(!document.transcript.isEmpty)
    let library = try #require(model.library)
    #expect(FileManager.default.fileExists(atPath: library.paths.directory(for: id).appending(path: "meeting-notes.json").path))
}

@MainActor
@Test("app refreshes visible minutes after a cloud document changes")
func appRefreshesVisibleMinutesAfterCloudDocumentChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeAIAppModel(configured: false)
    await model.open(paths: LibraryPaths(libraryRoot: root))
    let library = try #require(model.library)
    let service = try #require(model.meetingNotes)
    let recording = Recording(title: "Meeting", duration: 1, mode: .micOnly)
    try library.add(recording)
    let file = library.paths.directory(for: recording.id).appending(path: "meeting-notes.json")
    try JSONFile.save(appDocument(recording: recording, markdown: "Old", date: 100), to: file)
    await service.load(recording)
    try JSONFile.save(appDocument(recording: recording, markdown: "Updated remotely", date: 200), to: file)

    model.sync.onNotesChanged?(recording.id)
    for _ in 0..<100 {
        if service.document(for: recording.id)?.markdown == "Updated remotely" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.document(for: recording.id)?.markdown == "Updated remotely")
}

@MainActor
private func makeAIAppModel(configured: Bool) -> LibraryAppModel {
    let defaults = UserDefaults(suiteName: "AIAppIntegration.\(UUID().uuidString)")!
    let settings = SyncSettings(defaults: defaults, tokenStore: AIAppTokenStore())
    return LibraryAppModel(
        services: AppServices(recorder: VoiceRecorder(backend: AIAppRecordingBackend()), player: VoicePlayer()),
        aiEnvironment: .testing(configured: configured), syncSettings: settings
    )
}

private func appDocument(recording: Recording, markdown: String, date: TimeInterval) -> MeetingNotesDocument {
    MeetingNotesDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
                         generatedAt: Date(timeIntervalSince1970: date), modelID: "fixture/summary",
                         transcriptionModelID: "fixture/transcription", markdown: markdown,
                         transcript: "Existing transcript", costUSD: 0)
}

@MainActor
private final class AIAppTokenStore: SyncTokenStore {
    func loadToken() throws -> String? { nil }
    func saveToken(_ token: String) throws {}
}

@MainActor
private final class AIAppRecordingBackend: VoiceRecordingBackend {
    func makeRecordingID() -> UUID { UUID() }
    func start(
        outputURL: URL,
        mode: CaptureMode,
        liveAudioHandler: LiveAudioSampleHandler?,
        interruptionHandler: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> any VoiceRecordingSession {
        AIAppRecordingSession(url: outputURL)
    }
}

@MainActor
private final class AIAppRecordingSession: VoiceRecordingSession {
    let url: URL
    let canPause = true
    init(url: URL) { self.url = url }
    func pause() throws {}
    func resume() throws {}
    func cancel() async {}
    func finish() async throws -> VoiceRecordingResult {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Audio fixture for the injected AI chunker".utf8).write(to: url)
        return VoiceRecordingResult(duration: 1, warnings: [])
    }
}
