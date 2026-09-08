import AppKit
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct MeetingNotesServiceTests {
    @Test("Finishing a recording automatically publishes minutes through the app container")
    func appContainerAutoGeneration() async throws {
        var services = AppServices.uiTesting()
        services.aiEnvironment = .testing(configured: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerAutoMinutes-\(UUID())")
        let container = await AppContainer.load(services: services, paths: LibraryPaths(libraryRoot: root, arguments: []))
        await container.session.start()
        await container.session.finish()
        let recording = try #require(container.library.recordings.first)
        for _ in 0..<300 {
            if !container.meetingNotes.progress(for: recording.id).isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(container.meetingNotes.document(for: recording.id) != nil)
        #expect(container.meetingNotes.progress(for: recording.id) == .completed)
    }

    @Test("Minutes persist and reopening does not send another paid request")
    func persistsAndLoads() async throws {
        let h = try await MinutesHarness.make()
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let notes = try #require(h.service.document(for: h.recording.id))
        #expect(notes.markdown.contains("##"))
        #expect(notes.transcript.contains("회의"))
        #expect(h.service.progress(for: h.recording.id) == .completed)
        let newService = MeetingNotesService(configuration: h.config, client: h.client,
            chunker: FakeMeetingAudioChunker(), library: h.library)
        await newService.load(h.recording)
        #expect(newService.document(for: h.recording.id)?.markdown == notes.markdown)
        #expect(newService.document(for: h.recording.id)?.transcript == notes.transcript)
        #expect(newService.document(for: h.recording.id)?.modelID == notes.modelID)
        #expect(await h.client.completionCalls == 1)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        #expect(newService.copyMarkdown(for: h.recording.id, pasteboard: clipboard))
        #expect(clipboard.string(forType: .string) == notes.markdown)
    }

    @Test("Automatic generation respects opt-out and does not backfill existing recordings")
    func automaticOptOut() async throws {
        let h = try await MinutesHarness.make()
        #expect(h.service.progress(for: h.recording.id) == .idle)
        h.config.autoGenerate = false
        h.service.recordingDidFinish(h.recording)
        #expect(h.service.progress(for: h.recording.id) == .idle)
        h.config.autoGenerate = true
        h.service.recordingDidFinish(h.recording)
        try await h.waitUntilFinished()
        #expect(h.service.document(for: h.recording.id) != nil)
    }

    @Test("Duplicate generation is coalesced and regeneration reuses transcript cache")
    func duplicateAndCache() async throws {
        let h = try await MinutesHarness.make()
        h.service.generate(h.recording)
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        #expect(await h.client.transcriptionCalls == 1)
        #expect(await h.client.completionCalls == 1)
        h.service.generate(h.recording, regenerate: true)
        try await h.waitUntilFinished()
        #expect(await h.client.transcriptionCalls == 1)
        #expect(await h.client.completionCalls == 2)
    }

    @Test("A failed regeneration leaves the prior successful minutes intact")
    func retainsOldDocument() async throws {
        let h = try await MinutesHarness.make()
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let original = h.service.document(for: h.recording.id)
        await h.client.setFailure(true)
        h.service.generate(h.recording, regenerate: true)
        try await h.waitUntilFinished()
        #expect(h.service.document(for: h.recording.id) == original)
        guard case .failed = h.service.progress(for: h.recording.id) else {
            Issue.record("Expected failed regeneration")
            return
        }
    }

    @Test("Deleting a recording while AI is running never recreates its directory")
    func deletionCancelsLateResults() async throws {
        let h = try await MinutesHarness.make(delay: .milliseconds(100))
        h.service.generate(h.recording)
        for _ in 0..<100 {
            if await h.client.transcriptionCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await h.client.transcriptionCalls == 1)
        try h.library.moveToRecentlyDeleted(id: h.recording.id)
        h.service.cancel(h.recording.id)
        try h.library.deletePermanently(id: h.recording.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.service.document(for: h.recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.library.paths.directory(for: h.recording.id).path))
    }

    @Test("An unconfigured key never triggers network work")
    func unconfiguredNeverSends() async throws {
        let h = try await MinutesHarness.make()
        try h.config.removeKey()
        h.service.generate(h.recording)
        #expect(await h.client.transcriptionCalls == 0)
        #expect(await h.client.completionCalls == 0)
        #expect(!h.service.progress(for: h.recording.id).isRunning)
    }

    @Test("UTF8 chunking preserves all text under its byte budget")
    func textChunking() {
        let input = String(repeating: "한글과 English 회의입니다.\n", count: 100)
        let chunks = MeetingNotesPrompts.split(input, maximumBytes: 300)
        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { $0.utf8.count <= 300 })
        #expect(chunks.count > 1)
    }

    @Test("Long transcripts are summarized without dropping the final portion")
    func hierarchicalSummary() async throws {
        let h = try await MinutesHarness.make()
        await h.client.setTranscript(String(repeating: "회의 내용입니다. ", count: 1_000) + "LAST_SENTINEL")
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        #expect(h.service.document(for: h.recording.id)?.transcript.hasSuffix("LAST_SENTINEL") == true)
        #expect(await h.client.completionCalls > 1)
        #expect(await h.client.sawFinalSentinel)
    }

    @Test("Excessive audio length is rejected before any paid request")
    func limitsAudioRequests() async throws {
        let h = try await MinutesHarness.make(chunker: OversizedMeetingChunker())
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        #expect(await h.client.transcriptionCalls == 0)
        #expect(await h.client.completionCalls == 0)
        guard case .failed = h.service.progress(for: h.recording.id) else {
            Issue.record("Expected a duration limit error")
            return
        }
    }

    @Test("Too many summary parts are rejected before completion fanout")
    func limitsSummaryRequests() async throws {
        let h = try await MinutesHarness.make()
        await h.client.setTranscript(String(repeating: "A", count: 140_000))
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        #expect(await h.client.completionCalls == 0)
        guard case .failed = h.service.progress(for: h.recording.id) else {
            Issue.record("Expected a context limit error")
            return
        }
    }

    @Test("Cancel after publication keeps a completed document completed")
    func lateCancelDoesNotCreateCancelledDocument() async throws {
        let h = try await MinutesHarness.make()
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let doc = h.service.document(for: h.recording.id)
        h.service.cancel(h.recording.id)
        #expect(h.service.progress(for: h.recording.id) == .completed)
        #expect(h.service.document(for: h.recording.id) == doc)
    }
}

private struct OversizedMeetingChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 181 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        throw AIError(message: "The guard must run before reading chunks")
    }
}

@MainActor
private struct MinutesHarness {
    let client: MinutesTestClient
    let config: AIConfiguration
    let library: LibraryStore
    let recording: Recording
    let service: MeetingNotesService

    static func make(delay: Duration = .zero, chunker: any MeetingAudioChunking = FakeMeetingAudioChunker()) async throws -> MinutesHarness {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerMinutesTests-\(UUID())")
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(title: "회의", duration: 10, mode: .micOnly)
        try library.add(recording)
        try Data("fixture".utf8).write(to: paths.audioURL(for: recording.id))
        let client = MinutesTestClient(delay: delay)
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "NoteTakerMinutesTests.\(UUID())")!
        let config = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults)
        try config.saveKey("fixture-key")
        config.modelID = "fixture/summary"
        config.transcriptionModelID = "fixture/transcription"
        let service = MeetingNotesService(configuration: config, client: client,
            chunker: chunker, library: library)
        return MinutesHarness(client: client, config: config, library: library, recording: recording, service: service)
    }

    func waitUntilFinished() async throws {
        for _ in 0..<300 {
            if !service.progress(for: recording.id).isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AIError(message: "Test timed out")
    }
}

private actor MinutesTestClient: OpenRouterServing {
    let delay: Duration
    private(set) var transcriptionCalls = 0
    private(set) var completionCalls = 0
    private var fails = false
    private var transcript = "회의에서 다음 주 출시를 논의했습니다."
    private(set) var sawFinalSentinel = false
    init(delay: Duration) { self.delay = delay }
    func setFailure(_ value: Bool) { fails = value }
    func setTranscript(_ value: String) { transcript = value }
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcriptionCalls += 1
        try? await Task.sleep(for: delay) // Deliberately allows a late reply after cancellation.
        return AITextResponse(text: transcript)
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionCalls += 1
        if user.contains("LAST_SENTINEL") { sawFinalSentinel = true }
        if fails { throw AIError(message: "요청 실패") }
        return AITextResponse(text: "# 회의록\n\n## 요약\n다음 주 출시를 논의했습니다.\n\n## 할 일\n- [ ] 출시 일정 확인")
    }
}
