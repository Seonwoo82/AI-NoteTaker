import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Local AI pipeline")
struct LocalAIPipelineTests {
    @Test("local regeneration uses local model IDs, no API key, no speaker callback, and zero cost")
    func localRegenerationDoesNotReuseCloudTranscriptOrCallCloudCallbacks() async throws {
        let h = try await LocalAIMinutesHarness.make()
        h.cloudConfiguration.transcriptCleanupEnabled = false
        h.cloudService.generate(h.recording)
        try await h.cloudService.waitUntilFinished(recording: h.recording)
        let cloudDocument = try #require(h.cloudService.document(for: h.recording.id))
        #expect(cloudDocument.transcript.contains("cloud transcript"))

        h.localConfiguration.processingMode = .onDevice
        h.localConfiguration.transcriptCleanupEnabled = true
        h.localService.speakerTranscriptProvider = { _, _ in
            await h.client.recordUnexpectedSpeakerCallback()
            throw AIError(message: "speaker callback must not run in local mode")
        }
        await h.client.setTranscript("local transcript")

        h.localService.generate(h.recording, regenerate: true)
        try await h.localService.waitUntilFinished(recording: h.recording)

        let localDocument = try #require(h.localService.document(for: h.recording.id))
        #expect(localDocument.transcript.contains("local transcript"))
        #expect(!localDocument.transcript.contains("cloud transcript"))
        #expect(localDocument.modelID == LocalAIModel.summaryID)
        #expect(localDocument.transcriptionModelID == LocalAIModel.transcriptionID(localeIdentifier: "ko-KR"))
        #expect(localDocument.costUSD == 0)
        #expect(localDocument.transcriptCleanup == nil)
        #expect(localDocument.speakerTranscript == nil)
        #expect(await h.client.speakerCallbackCount == 0)
        let transcriptions = await h.client.transcriptionRequests
        #expect(transcriptions.map(\.model) == ["fixture/cloud-transcription", LocalAIModel.transcriptionID(localeIdentifier: "ko-KR")])
        #expect(transcriptions.map(\.apiKey) == ["fixture-key", ""])
        let completions = await h.client.completionRequests
        #expect(completions.map(\.model) == ["fixture/cloud-summary", LocalAIModel.summaryID])
        #expect(completions.map(\.apiKey) == ["fixture-key", ""])
    }
}

@MainActor
private struct LocalAIMinutesHarness {
    let client: LocalAIPipelineClient
    let cloudConfiguration: AIConfiguration
    let localConfiguration: AIConfiguration
    let library: LibraryStore
    let recording: Recording
    let cloudService: MeetingNotesService
    let localService: MeetingNotesService

    static func make() async throws -> LocalAIMinutesHarness {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerLocalAIPipelineTests-\(UUID())")
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(title: "회의", duration: 10, mode: .micOnly)
        try library.add(recording)
        try Data("fixture".utf8).write(to: paths.audioURL(for: recording.id))
        let client = LocalAIPipelineClient()
        let cloudConfiguration = AIConfiguration(
            client: client,
            keyStore: InMemoryAPIKeyStore("fixture-key"),
            defaults: try isolatedLocalAIPipelineDefaults(),
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") },
            localPreparation: { _ in LocalAIStatus(isAvailable: true, message: "ready") }
        )
        cloudConfiguration.modelID = "fixture/cloud-summary"
        cloudConfiguration.transcriptionModelID = "fixture/cloud-transcription"
        let localConfiguration = AIConfiguration(
            client: client,
            keyStore: InMemoryAPIKeyStore(),
            defaults: try isolatedLocalAIPipelineDefaults(),
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") },
            localPreparation: { _ in LocalAIStatus(isAvailable: true, message: "ready") }
        )
        let cloudService = MeetingNotesService(
            configuration: cloudConfiguration,
            client: client,
            chunker: LocalAIPipelineChunker(),
            library: library
        )
        let localService = MeetingNotesService(
            configuration: localConfiguration,
            client: client,
            chunker: LocalAIPipelineChunker(),
            library: library
        )
        return LocalAIMinutesHarness(
            client: client,
            cloudConfiguration: cloudConfiguration,
            localConfiguration: localConfiguration,
            library: library,
            recording: recording,
            cloudService: cloudService,
            localService: localService
        )
    }
}

private struct LocalAIPipelineChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("fixture audio".utf8), format: "wav", startTime: 0, duration: 10)
    }
}

private actor LocalAIPipelineClient: OpenRouterServing {
    struct TranscriptionRequest: Sendable {
        let model: String
        let apiKey: String
    }
    struct CompletionRequest: Sendable {
        let model: String
        let apiKey: String
    }

    private var transcript = "cloud transcript"
    private(set) var transcriptionRequests: [TranscriptionRequest] = []
    private(set) var completionRequests: [CompletionRequest] = []
    private(set) var speakerCallbackCount = 0

    func setTranscript(_ value: String) { transcript = value }
    func recordUnexpectedSpeakerCallback() { speakerCallbackCount += 1 }
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcriptionRequests.append(TranscriptionRequest(model: model, apiKey: apiKey))
        return AITextResponse(text: transcript, costUSD: apiKey.isEmpty ? 0 : 0.01)
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionRequests.append(CompletionRequest(model: model, apiKey: apiKey))
        return AITextResponse(text: "# 회의록\n\n## 요약\n\(transcript)", costUSD: apiKey.isEmpty ? 0 : 0.02)
    }
}

private extension MeetingNotesService {
    func waitUntilFinished(recording: Recording) async throws {
        for _ in 0..<300 {
            if !progress(for: recording.id).isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AIError(message: "Test timed out")
    }
}

private func isolatedLocalAIPipelineDefaults() throws -> UserDefaults {
    let suiteName = "NoteTakerLocalAIPipelineTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
