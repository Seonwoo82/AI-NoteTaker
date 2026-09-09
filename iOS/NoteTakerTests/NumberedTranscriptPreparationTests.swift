import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Numbered transcript preparation")
struct NumberedTranscriptPreparationTests {
    @Test("preparation reuses existing compatible meeting transcript without AI completion")
    func reusesExistingCompatibleTranscript() async throws {
        let h = try await NumberedPreparationHarness.make()
        let original = h.document(insights: MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Ship notes.",
                actorSpeakerID: "speaker-a", targetSpeakerID: nil, dueText: nil,
                evidenceTurnIDs: ["turn-1"])
        ]), modifiedAt: 1_788_500_000_000)
        try await h.store.save(original)

        let transcript = try await h.service.prepareNumberedTranscript(h.recording)

        #expect(transcript == original.transcript)
        #expect(h.store.document(for: h.recording.id) == original)
        #expect(await h.detailedClient.calls == 0)
        #expect(await h.client.completionCalls == 0)
        #expect(h.speakerBackend.prepareCallCount == 0)
        #expect(h.speakerBackend.diarizeCallCount == 0)
    }

    @Test("preparation persists transcript only when no complete artifact exists")
    func persistsTranscriptOnlyWithoutCompletion() async throws {
        let h = try await NumberedPreparationHarness.make()

        let transcript = try await h.service.prepareNumberedTranscript(h.recording)

        let saved = try #require(h.store.document(for: h.recording.id))
        #expect(saved.transcript == transcript)
        #expect(saved.insights == nil)
        #expect(saved.actionStates.isEmpty)
        #expect(saved.analysisModelID == "fixture/analysis")
        #expect(transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(await h.detailedClient.calls == 1)
        #expect(await h.client.completionCalls == 0)
        #expect(h.speakerBackend.prepareCallCount == 1)
        #expect(h.speakerBackend.diarizeCallCount == 1)
    }

    @Test("preparation returns a fresh transcript without overwriting complete insights")
    func completeInsightsAreNotOverwrittenByTranscriptOnlyPreparation() async throws {
        let h = try await NumberedPreparationHarness.make()
        let original = h.document(insights: MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Ship notes.",
                actorSpeakerID: "speaker-a", targetSpeakerID: nil, dueText: nil,
                evidenceTurnIDs: ["turn-1"])
        ]), modifiedAt: 1_788_500_000_000, transcriptionModelID: "older/stt")
        try await h.store.save(original)

        let transcript = try await h.service.prepareNumberedTranscript(h.recording)

        #expect(transcript.transcriptionModelID == h.configuration.transcriptionModelID)
        #expect(h.store.document(for: h.recording.id) == original)
        #expect(await h.detailedClient.calls == 1)
        #expect(await h.client.completionCalls == 0)
    }
}

@MainActor
private struct NumberedPreparationHarness {
    let library: LibraryStore
    let recording: Recording
    let configuration: AIConfiguration
    let profile: MeetingProfileStore
    let store: MeetingIntelligenceStore
    let edits: MeetingEditLog
    let speakerBackend: NumberedPreparationSpeakerBackend
    let client: NumberedPreparationOpenRouterClient
    let detailedClient: NumberedPreparationDetailedClient
    let service: MeetingAnalysisService

    static func make() async throws -> NumberedPreparationHarness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NumberedTranscriptPreparationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(id: UUID(uuidString: "BBBBBBBB-1234-1234-1234-BBBBBBBBBBBB")!,
            title: "Prep meeting", duration: 4, mode: .micOnly)
        try library.add(recording)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id), options: .atomic)

        let client = NumberedPreparationOpenRouterClient()
        let detailedClient = NumberedPreparationDetailedClient()
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "NumberedTranscriptPreparationTests.\(UUID().uuidString)")!
        let configuration = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults)
        configuration.modelID = "fixture/analysis"
        configuration.transcriptionModelID = "fixture/stt"
        configuration.outputLanguage = "ko"
        try configuration.saveKey("fixture-key")

        let profile = MeetingProfileStore(root: root.appending(path: "Profile", directoryHint: .isDirectory))
        let store = MeetingIntelligenceStore(library: library)
        let edits = MeetingEditLog(root: root.appending(path: "Edits", directoryHint: .isDirectory))
        let speakerBackend = NumberedPreparationSpeakerBackend()
        let service = MeetingAnalysisService(library: library, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: speakerBackend,
            client: client, detailedClient: detailedClient, chunker: NumberedPreparationChunker())
        return NumberedPreparationHarness(library: library, recording: recording,
            configuration: configuration, profile: profile, store: store, edits: edits,
            speakerBackend: speakerBackend, client: client, detailedClient: detailedClient,
            service: service)
    }

    func document(
        insights: MeetingInsights?,
        modifiedAt: Int64,
        transcriptionModelID: String? = nil
    ) -> MeetingIntelligenceDocument {
        let transcript = MeetingTranscript(recordingID: recording.id,
            audioVersion: recording.audioVersion,
            transcriptionModelID: transcriptionModelID ?? configuration.transcriptionModelID,
            speakers: [MeetingSpeaker(id: "speaker-a", name: "Avery", isOwner: false)],
            turns: [TranscriptTurn(id: "turn-1", start: 0, end: 1, speakerID: "speaker-a", text: "Existing transcript.")])
        return MeetingIntelligenceDocument(recordingID: recording.id,
            audioVersion: recording.audioVersion,
            modifiedAt: modifiedAt,
            mutationID: UUID(),
            projectName: "Existing",
            transcript: transcript,
            insights: insights,
            analysisModelID: configuration.modelID)
    }
}

private struct NumberedPreparationChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("audio".utf8), format: "wav", startTime: 0, duration: 4)
    }
}

private final class NumberedPreparationSpeakerBackend: SpeakerAnalysisServing, @unchecked Sendable {
    let embeddingModelID = "fixture-speakers"
    private let lock = NSLock()
    private var recordedPrepareCallCount = 0
    private var recordedDiarizeCallCount = 0

    var prepareCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedPrepareCallCount
    }

    var diarizeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedDiarizeCallCount
    }

    func prepare() async throws {
        lock.withLock { recordedPrepareCallCount += 1 }
    }

    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        lock.withLock { recordedDiarizeCallCount += 1 }
        return AcousticDiarization(
            speakers: [
                AcousticSpeaker(id: "host", embedding: [1, 0]),
                AcousticSpeaker(id: "guest", embedding: [0, 1])
            ],
            spans: [
                AcousticSpeakerSpan(start: 0, end: 1, speakerID: "host"),
                AcousticSpeakerSpan(start: 1, end: 3, speakerID: "guest")
            ]
        )
    }

    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] { [1, 0] }
}

private actor NumberedPreparationDetailedClient: DetailedTranscriptionServing {
    private(set) var calls = 0

    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String,
                            language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1
        return DetailedTranscriptionResult(text: "Host opens. Guest replies.",
            words: [],
            segments: [
                TimedTranscriptionSegment(text: "Host opens.", start: 0, end: 1, speakerID: nil),
                TimedTranscriptionSegment(text: "Guest replies.", start: 1.2, end: 2, speakerID: nil)
            ])
    }
}

private actor NumberedPreparationOpenRouterClient: OpenRouterServing {
    private(set) var completionCalls = 0

    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionCalls += 1
        return AITextResponse(text: "{}")
    }
}
