import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Meeting notes enhancement")
struct MeetingNotesEnhancementTests {
    @Test("corrections produce a preview with the selected model and apply without retranscription")
    func previewAndApply() async throws {
        let h = try await EnhancementHarness.make()
        let original = try #require(h.service.document(for: h.recording.id))
        await h.client.setMarkdown("# 수정된 회의록\n승원이 다음 주까지 제안서를 전달합니다.")
        h.service.enhance(h.recording, instructions: "승현은 승원입니다. 전달 일정은 다음 주입니다.")
        try await h.wait()
        let preview = try #require(h.service.enhancementPreview(for: h.recording.id))
        #expect(h.service.document(for: h.recording.id) == original)
        #expect(preview.markdown.contains("승원"))
        #expect(await h.client.modelsUsed == ["fixture/summary", "fixture/enhance"])
        #expect(await h.client.transcriptions == 1)
        #expect(await h.client.prompts.last?.contains("승현은 승원") == true)
        try h.service.applyEnhancement(h.recording)
        let applied = try #require(h.service.document(for: h.recording.id))
        #expect(applied.markdown == preview.markdown)
        #expect(applied.transcript == original.transcript)
        #expect(applied.enhancement?.modelID == "fixture/enhance")
        #expect(applied.generatedAt > original.generatedAt)
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
        let saved = try JSONFile.load(MeetingNotesDocument.self, from: h.notesURL)
        #expect(saved.markdown == preview.markdown)
    }

    @Test("failed or discarded enhancement never replaces the existing notes")
    func failureAndDiscardPreserveOriginal() async throws {
        let h = try await EnhancementHarness.make()
        let original = h.service.document(for: h.recording.id)
        await h.client.setFails(true)
        h.service.enhance(h.recording, instructions: "이름을 승원으로 수정")
        try await h.wait()
        #expect(h.service.document(for: h.recording.id) == original)
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
        await h.client.setFails(false)
        h.service.enhance(h.recording, instructions: "이름을 승원으로 수정")
        try await h.wait()
        h.service.discardEnhancement(h.recording.id)
        #expect(h.service.document(for: h.recording.id) == original)
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
    }

    @Test("a synced replacement on disk prevents an old preview from overwriting it")
    func syncedReplacementWins() async throws {
        let h = try await EnhancementHarness.make()
        h.service.enhance(h.recording, instructions: "이름 수정")
        try await h.wait()
        let old = try #require(h.service.document(for: h.recording.id))
        let remote = MeetingNotesDocument(recordingID: old.recordingID, audioVersion: old.audioVersion,
            generatedAt: old.generatedAt.addingTimeInterval(60), modelID: old.modelID,
            transcriptionModelID: old.transcriptionModelID, markdown: "# 다른 기기의 최신 회의록", transcript: old.transcript)
        try JSONFile.save(remote, to: h.notesURL)
        #expect(throws: AIError.self) { try h.service.applyEnhancement(h.recording) }
        #expect(try JSONFile.load(MeetingNotesDocument.self, from: h.notesURL).markdown == remote.markdown)
    }

    @Test("cancelled model responses cannot publish a preview or change existing notes")
    func cancellationPreservesNotes() async throws {
        let h = try await EnhancementHarness.make()
        let original = h.service.document(for: h.recording.id)
        await h.client.setHold(true)
        h.service.enhance(h.recording, instructions: "이름 수정")
        for _ in 0..<200 {
            if await h.client.modelsUsed.count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        h.service.cancel(h.recording.id)
        await h.client.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
        #expect(h.service.document(for: h.recording.id) == original)
    }

    @Test("enhancement works without an STT model and key changes discard pending previews")
    func enhancementIsIndependentOfSTT() async throws {
        let h = try await EnhancementHarness.make()
        let original = h.service.document(for: h.recording.id)
        h.config.transcriptionModelID = ""
        h.service.enhance(h.recording, instructions: "승현은 승원입니다.")
        try await h.wait()
        #expect(h.service.enhancementPreview(for: h.recording.id) != nil)
        #expect(await h.client.transcriptions == 1)
        h.service.credentialsDidChange()
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
        #expect(h.service.document(for: h.recording.id) == original)
    }

    @Test("empty correction feedback does not make a model request")
    func emptyFeedbackRejected() async throws {
        let h = try await EnhancementHarness.make()
        h.service.enhance(h.recording, instructions: " \n ")
        try await h.wait()
        #expect(await h.client.modelsUsed.count == 1)
        #expect(h.service.enhancementPreview(for: h.recording.id) == nil)
    }

    @Test("numbered transcript preparation uses the provider once and survives notes persistence")
    func speakerTranscriptPersistence() async throws {
        let h = try await EnhancementHarness.make()
        let original = try #require(h.service.document(for: h.recording.id))
        var calls = 0
        let transcript = MeetingTranscript(recordingID: h.recording.id, audioVersion: h.recording.audioVersion,
            transcriptionModelID: "fixture/stt", speakers: [MeetingSpeaker(id: "p1", name: "Speaker", isOwner: false)],
            turns: [TranscriptTurn(id: "turn1", start: 0, end: 1, speakerID: "p1", text: "승현이 제안서를 전달합니다.")])
        h.config.transcriptionModelID = "fixture/new-stt"
        var requestedModel: String?
        h.service.speakerTranscriptProvider = { _, model in calls += 1; requestedModel = model; return transcript }
        h.service.identifyParticipants(h.recording)
        try await h.wait()
        let saved = try #require(h.service.document(for: h.recording.id))
        #expect(calls == 1)
        #expect(requestedModel == "fixture/stt")
        #expect(saved.speakerTranscript?.transcriptionModelID == saved.transcriptionModelID)
        #expect(saved.markdown == original.markdown)
        #expect(saved.transcript == original.transcript)
        #expect(saved.speakerTranscript == transcript)
        #expect(await h.client.modelsUsed.count == 1)
    }
}

@MainActor
private struct EnhancementHarness {
    let root: URL
    let library: LibraryStore
    let recording: Recording
    let service: MeetingNotesService
    let config: AIConfiguration
    let client: EnhancementClient
    var notesURL: URL { library.paths.directory(for: recording.id).appending(path: "meeting-notes.json") }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "enhancement-\(UUID())")
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root, arguments: []))
        let recording = Recording(title: "회의", duration: 75 * 60, mode: .micOnly)
        try library.add(recording)
        try Data("fixture".utf8).write(to: library.paths.audioURL(for: recording.id))
        let client = EnhancementClient()
        let defaults = UserDefaults(suiteName: "enhancement-\(UUID())")!
        let models = ["fixture/summary", "fixture/enhance"].map {
            OpenRouterModel(id: $0, name: $0, contextLength: 1_000_000,
                inputModalities: ["text"], outputModalities: ["text"], maxCompletionTokens: 131_072)
        } + [OpenRouterModel(id: "fixture/stt", name: "STT", contextLength: 0,
            inputModalities: ["audio"], outputModalities: ["transcription"]),
            OpenRouterModel(id: "fixture/new-stt", name: "New STT", contextLength: 0,
                inputModalities: ["audio"], outputModalities: ["transcription"])]
        defaults.set(try JSONEncoder().encode(models), forKey: "ai.modelCatalog")
        let config = AIConfiguration(client: client, keyStore: InMemoryAPIKeyStore(), defaults: defaults)
        try config.saveKey("fixture")
        config.modelID = "fixture/summary"
        config.transcriptionModelID = "fixture/stt"
        config.enhancementModelID = "fixture/enhance"
        let service = MeetingNotesService(configuration: config, client: client, chunker: EnhancementChunker(), library: library)
        let h = Self(root: root, library: library, recording: recording, service: service, config: config, client: client)
        service.generate(recording)
        try await h.wait()
        return h
    }

    func wait() async throws {
        for _ in 0..<500 {
            if !service.progress(for: recording.id).isRunning { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AIError(message: "Enhancement test timeout")
    }
}

private struct EnhancementChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("fixture".utf8), format: "wav", startTime: 0, duration: 1)
    }
}

private actor EnhancementClient: OpenRouterServing {
    private(set) var transcriptions = 0
    private(set) var modelsUsed: [String] = []
    private(set) var prompts: [String] = []
    private var markdown = "# 회의록\n승현이 제안서를 전달합니다."
    private var fails = false
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func setMarkdown(_ value: String) { markdown = value }
    func setFails(_ value: Bool) { fails = value }
    func setHold(_ value: Bool) { hold = value }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcriptions += 1
        return AITextResponse(text: "승현이 제안서를 전달합니다.")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        modelsUsed.append(model)
        prompts.append(user)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fails { throw AIError(message: "Model failed") }
        return AITextResponse(text: markdown, costUSD: 0.01)
    }
}
