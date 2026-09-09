import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Transcript cleanup service")
struct TranscriptCleanupServiceTests {
    @Test("automatic cleanup feeds minutes and preserves the raw transcript")
    func automaticCleanupFeedsMinutes() async throws {
        let h = try await CleanupHarness.make()
        h.service.generate(h.recording)
        try await h.wait()
        let doc = try #require(h.service.document(for: h.recording.id))
        #expect(doc.transcript.contains("문 닫히는 소리"))
        #expect(doc.transcriptCleanup?.removedPassageCount == 1)
        #expect(await h.client.notesInputs.last?.contains("문 닫히는 소리") == false)
        #expect(await h.client.notesInputs.last?.contains("승인되지 않았습니다") == true)
        #expect(abs((doc.costUSD ?? 0) - 0.6) < 0.0001)
        h.service.generate(h.recording, regenerate: true)
        try await h.wait()
        #expect(await h.client.transcriptions == 1)
        #expect(await h.client.cleanups == 1)
        #expect(await h.client.notesInputs.count == 2)
    }

    @Test("disabled cleanup keeps the original generation path")
    func cleanupCanBeDisabled() async throws {
        let h = try await CleanupHarness.make(enabled: false)
        h.service.generate(h.recording)
        try await h.wait()
        #expect(h.service.document(for: h.recording.id)?.transcriptCleanup == nil)
        #expect(await h.client.cleanups == 0)
        #expect(await h.client.notesInputs.last?.contains("문 닫히는 소리") == true)
    }

    @Test("a bad cleanup falls back to raw input without failing minutes")
    func cleanupFailurePreservesGeneration() async throws {
        let h = try await CleanupHarness.make()
        await h.client.setInvalid(true)
        h.service.generate(h.recording)
        try await h.wait()
        #expect(h.service.progress(for: h.recording.id) == .completed)
        #expect(h.service.document(for: h.recording.id)?.transcriptCleanup == nil)
        #expect(h.service.cleanupNotice(for: h.recording.id)?.contains("원문") == true)
        #expect(await h.client.notesInputs.last?.contains("문 닫히는 소리") == true)
    }

    @Test("manual cleanup needs no STT model and keeps the existing minutes")
    func manualCleanupPreservesMinutes() async throws {
        let h = try await CleanupHarness.make(enabled: false)
        h.service.generate(h.recording)
        try await h.wait()
        let original = try #require(h.service.document(for: h.recording.id))
        h.config.transcriptionModelID = ""
        h.service.refineTranscript(h.recording)
        try await h.wait()
        let updated = try #require(h.service.document(for: h.recording.id))
        #expect(updated.markdown == original.markdown)
        #expect(updated.transcript == original.transcript)
        #expect(updated.transcriptCleanup != nil)
        #expect(updated.generatedAt > original.generatedAt)
        #expect(await h.client.transcriptions == 1)
        #expect(await h.client.notesInputs.count == 1)
    }

    @Test("a cancelled cleanup cannot publish a late response")
    func cancellationPreservesDocument() async throws {
        let h = try await CleanupHarness.make(enabled: false)
        h.service.generate(h.recording)
        try await h.wait()
        let original = h.service.document(for: h.recording.id)
        await h.client.setHold(true)
        h.service.refineTranscript(h.recording)
        for _ in 0..<200 {
            if await h.client.cleanups == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        h.service.cancel(h.recording.id)
        await h.client.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.service.document(for: h.recording.id) == original)
        #expect(h.service.progress(for: h.recording.id) == .cancelled)
    }

    @Test("a remote update cannot be overwritten by a pending cleanup")
    func remoteReplacementIsPreserved() async throws {
        let h = try await CleanupHarness.make(enabled: false)
        h.service.generate(h.recording)
        try await h.wait()
        let original = try #require(h.service.document(for: h.recording.id))
        await h.client.setHold(true)
        h.service.refineTranscript(h.recording)
        for _ in 0..<200 {
            if await h.client.cleanups == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let remote = MeetingNotesDocument(recordingID: original.recordingID, audioVersion: original.audioVersion,
            generatedAt: original.generatedAt.addingTimeInterval(60), modelID: original.modelID,
            transcriptionModelID: original.transcriptionModelID, markdown: "# New remote notes", transcript: original.transcript)
        try JSONFile.save(remote, to: h.notesURL)
        await h.client.release()
        try await h.wait()
        #expect(try JSONFile.load(MeetingNotesDocument.self, from: h.notesURL).markdown == remote.markdown)
        #expect(h.service.cleanupNotice(for: h.recording.id) != nil)
    }
}

@MainActor
private struct CleanupHarness {
    let root: URL
    let recording: Recording
    let config: AIConfiguration
    let client: CleanupFixtureClient
    let service: MeetingNotesService
    var notesURL: URL { root.appending(path: "Recordings/\(recording.id.uuidString)/meeting-notes.json") }

    static func make(enabled: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "TranscriptCleanup-\(UUID())")
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(title: "Budget discussion", duration: 10, mode: .micOnly)
        try library.add(recording)
        try Data("fixture audio".utf8).write(to: paths.audioURL(for: recording.id))
        let client = CleanupFixtureClient()
        let defaults = UserDefaults(suiteName: "TranscriptCleanup.\(UUID())")!
        let config = AIConfiguration(client: client, keyStore: InMemoryAPIKeyStore(), defaults: defaults)
        config.modelID = "fixture/minutes"
        config.transcriptionModelID = "fixture/stt"
        config.transcriptCleanupEnabled = enabled
        try config.saveKey("fixture-key")
        let service = MeetingNotesService(configuration: config, client: client, chunker: CleanupFixtureChunker(), library: library)
        return Self(root: root, recording: recording, config: config, client: client, service: service)
    }

    func wait() async throws {
        for _ in 0..<1_000 {
            if !service.progress(for: recording.id).isRunning { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Cleanup fixture did not finish")
    }
}

private struct CleanupFixtureChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("fixture".utf8), format: "wav", startTime: 0, duration: 10)
    }
}

private actor CleanupFixtureClient: OpenRouterServing {
    private(set) var transcriptions = 0
    private(set) var cleanups = 0
    private(set) var notesInputs: [String] = []
    private var invalid = false
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    func setInvalid(_ value: Bool) { invalid = value }
    func setHold(_ value: Bool) { hold = value }
    func release() { hold = false; pending?.resume(); pending = nil }
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws { }
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcriptions += 1
        return AITextResponse(text: "예산은 30만원입니다.\n\n[문 닫히는 소리]\n\n아직 승인되지 않았습니다.", costUSD: 0.3)
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        if system == TranscriptCleanupPrompts.system {
            cleanups += 1
            if hold { await withCheckedContinuation { pending = $0 } }
            if invalid { return AITextResponse(text: "not JSON") }
            let request = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
            let passages = (request["passages"] as! [[String: Any]]).map { item -> [String: String] in
                let text = item["text"] as! String
                return ["id": item["id"] as! String, "text": text.contains("[문 닫히는 소리]") ? "" : text]
            }
            let data = try JSONSerialization.data(withJSONObject: ["passages": passages])
            return AITextResponse(text: String(decoding: data, as: UTF8.self), costUSD: 0.1)
        }
        notesInputs.append(user)
        return AITextResponse(text: "# Budget discussion\nApproval is still pending.", costUSD: 0.2)
    }
}
