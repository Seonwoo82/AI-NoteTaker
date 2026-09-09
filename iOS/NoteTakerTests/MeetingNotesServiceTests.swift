import Foundation
import Testing
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite
struct MeetingNotesServiceTests {
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
#if os(macOS)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        #expect(newService.copyMarkdown(for: h.recording.id, pasteboard: clipboard))
        #expect(clipboard.string(forType: .string) == notes.markdown)
#elseif canImport(UIKit)
        let clipboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: clipboard.name) }
        #expect(newService.copyMarkdown(for: h.recording.id, pasteboard: clipboard))
        #expect(clipboard.string == notes.markdown)
#endif
    }

    @Test("Saved completed minutes notify sync after durable publication")
    func savedCompletedMinutesNotifySync() async throws {
        let h = try await MinutesHarness.make()
        var savedIDs: [UUID] = []
        h.service.onDocumentSaved = { savedIDs.append($0) }

        h.service.generate(h.recording)
        try await h.waitUntilFinished()

        #expect(savedIDs == [h.recording.id])
        #expect(h.service.document(for: h.recording.id) != nil)
    }

    @Test("Reload publishes newer synced minutes without another paid request")
    func reloadPublishesNewerSyncedMinutes() async throws {
        let h = try await MinutesHarness.make()
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let originalCalls = await h.client.completionCalls
        let synced = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 60),
            modelID: "cloud/model",
            transcriptionModelID: "cloud/transcription",
            markdown: "# Synced minutes",
            transcript: "Synced transcript",
            costUSD: nil
        )
        try AIArtifactStore(paths: h.library.paths).saveDocument(synced, recording: h.recording)

        await h.service.reload(h.recording)

        #expect(h.service.document(for: h.recording.id) == synced)
        #expect(await h.client.completionCalls == originalCalls)
    }

    @Test("Reload never overwrites newer visible minutes with an older synced file")
    func reloadKeepsNewerVisibleMinutes() async throws {
        let h = try await MinutesHarness.make()
        let newer = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            modelID: "newer/model",
            transcriptionModelID: "newer/transcription",
            markdown: "# Newer minutes",
            transcript: "Newer transcript",
            costUSD: nil
        )
        let older = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: newer.generatedAt.addingTimeInterval(-60),
            modelID: "older/model",
            transcriptionModelID: "older/transcription",
            markdown: "# Older minutes",
            transcript: "Older transcript",
            costUSD: nil
        )
        try AIArtifactStore(paths: h.library.paths).saveDocument(newer, recording: h.recording)
        await h.service.load(h.recording)
        try AIArtifactStore(paths: h.library.paths).saveDocument(older, recording: h.recording)

        await h.service.reload(h.recording)

        #expect(h.service.document(for: h.recording.id) == newer)
    }

    @Test("Reload does not mutate visible minutes while generation is running")
    func reloadSkipsRunningGeneration() async throws {
        let h = try await MinutesHarness.make(delay: .milliseconds(100))
        let visible = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            modelID: "visible/model",
            transcriptionModelID: "visible/transcription",
            markdown: "# Visible minutes",
            transcript: "Visible transcript",
            costUSD: nil
        )
        let synced = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: visible.generatedAt.addingTimeInterval(60),
            modelID: "synced/model",
            transcriptionModelID: "synced/transcription",
            markdown: "# Synced minutes",
            transcript: "Synced transcript",
            costUSD: nil
        )
        try AIArtifactStore(paths: h.library.paths).saveDocument(visible, recording: h.recording)
        await h.service.load(h.recording)
        h.service.generate(h.recording, regenerate: true)
        for _ in 0..<100 {
            if h.service.progress(for: h.recording.id).isRunning { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try AIArtifactStore(paths: h.library.paths).saveDocument(synced, recording: h.recording)

        await h.service.reload(h.recording)

        #expect(h.service.document(for: h.recording.id) == visible)
        h.service.cancel(h.recording.id)
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

    @Test("Regeneration reuses a synced completed transcript without local transcript cache")
    func regenerationReusesSyncedCompletedTranscript() async throws {
        let h = try await MinutesHarness.make()
        let synced = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: .now,
            modelID: "cloud/model",
            transcriptionModelID: h.config.transcriptionModelID,
            markdown: "# Synced minutes",
            transcript: "[00:00]\nSYNCED_TRANSCRIPT_SENTINEL",
            costUSD: nil
        )
        try AIArtifactStore(paths: h.library.paths).saveDocument(synced, recording: h.recording)
        await h.service.load(h.recording)

        h.service.generate(h.recording, regenerate: true)
        try await h.waitUntilFinished()

        #expect(await h.client.transcriptionCalls == 0)
        #expect(await h.client.completionCalls == 1)
        #expect(await h.client.sawSyncedTranscriptSentinel)
    }

    @Test("Changing the transcription model invalidates synced transcript reuse")
    func transcriptionModelChangeInvalidatesSyncedTranscriptReuse() async throws {
        let h = try await MinutesHarness.make()
        let synced = MeetingNotesDocument(
            recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            generatedAt: .now,
            modelID: "cloud/model",
            transcriptionModelID: "other/transcription",
            markdown: "# Synced minutes",
            transcript: "[00:00]\nSYNCED_TRANSCRIPT_SENTINEL",
            costUSD: nil
        )
        try AIArtifactStore(paths: h.library.paths).saveDocument(synced, recording: h.recording)
        await h.service.load(h.recording)

        h.service.generate(h.recording, regenerate: true)
        try await h.waitUntilFinished()

        #expect(await h.client.transcriptionCalls == 1)
        #expect(await h.client.completionCalls == 1)
        #expect(await h.client.sawSyncedTranscriptSentinel == false)
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

    @Test("Deleting a recording while AI is running never recreates AI sidecars")
    func deletionCancelsLateResults() async throws {
        let h = try await MinutesHarness.make(delay: .milliseconds(100))
        h.service.generate(h.recording)
        for _ in 0..<100 {
            if await h.client.transcriptionCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await h.client.transcriptionCalls == 1)
        var deleted = h.recording
        deleted.deletedAt = .now
        try h.library.update(deleted)
        h.service.cancel(h.recording.id)
        try? FileManager.default.removeItem(at: h.library.paths.audioURL(for: h.recording.id))
        try? FileManager.default.removeItem(at: h.library.paths.directory(for: h.recording.id).appending(path: "meeting-notes.json"))
        try? FileManager.default.removeItem(at: h.library.paths.directory(for: h.recording.id).appending(path: "ai-transcript.json"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.service.document(for: h.recording.id) == nil)
        #expect(FileManager.default.fileExists(atPath: h.library.paths.directory(for: h.recording.id).path))
        #expect(FileManager.default.fileExists(atPath: h.library.paths.metadataURL(for: h.recording.id).path))
        #expect(!FileManager.default.fileExists(atPath: h.library.paths.audioURL(for: h.recording.id).path))
        #expect(!FileManager.default.fileExists(atPath: h.library.paths.directory(for: h.recording.id).appending(path: "meeting-notes.json").path))
        #expect(!FileManager.default.fileExists(atPath: h.library.paths.directory(for: h.recording.id).appending(path: "ai-transcript.json").path))
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

    @Test("A thirty kilobyte transcript on a large context model uses one final synthesis")
    func largeContextTranscriptAvoidsUnnecessaryCompaction() async throws {
        let h = try await MinutesHarness.make(summaryModel: OpenRouterModel(
            id: "fixture/large-context",
            name: "Large Context",
            contextLength: 1_000_000,
            inputModalities: ["text"],
            outputModalities: ["text"]
        ))
        let transcript = String(repeating: "A", count: 30_000) + "FINAL_SENTINEL"
        await h.client.setTranscript(transcript)

        h.service.generate(h.recording)
        try await h.waitUntilFinished()

        #expect(await h.client.completionCalls == 1)
        let requests = await h.client.completionRequests
        #expect(requests.map(\.maxTokens) == [131_072])
        #expect(requests.first?.user.contains("FINAL_SENTINEL") == true)
    }

    @Test("GLM 5.3 partial summaries get a reasoning-safe token budget")
    func glmPartialSummariesUseLargerBudget() async throws {
        let h = try await MinutesHarness.make(summaryModel: OpenRouterModel(
            id: "z-ai/glm-5.3",
            name: "GLM 5.3",
            contextLength: 1_000_000,
            inputModalities: ["text"],
            outputModalities: ["text"]
        ))
        await h.client.setTranscript(String(repeating: "B", count: 110_000) + "FINAL_SENTINEL")

        h.service.generate(h.recording)
        try await h.waitUntilFinished()

        let requests = await h.client.completionRequests
        let partials = requests.filter { $0.user.contains("Meeting excerpt") }
        #expect(partials.count == 2)
        #expect(partials.allSatisfy { $0.maxTokens == 32_768 })
        #expect(partials.allSatisfy { $0.user.utf8.count <= 97_000 })
        #expect(requests.last?.maxTokens == 131_072)
        #expect(await h.client.sawFinalSentinel)
    }

    @Test("hour-long Qwen meetings retain every excerpt with a larger output allowance")
    func qwenHourLongMeetingHasRoomForReasoningAndNotes() async throws {
        let h = try await MinutesHarness.make(summaryModel: OpenRouterModel(
            id: "qwen/qwen3.8-max-0902", name: "Qwen3.8 Max", contextLength: 1_000_000,
            inputModalities: ["text"], outputModalities: ["text"]), duration: 75 * 60)
        await h.client.setTranscript(String(repeating: "회의 안건과 결정 사항. ", count: 5_000) + "FINAL_SENTINEL")
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let requests = await h.client.completionRequests
        #expect(requests.last?.maxTokens == 131_072)
        let partials = requests.filter { $0.user.contains("Meeting excerpt") }
        #expect(!partials.isEmpty)
        #expect(partials.allSatisfy { $0.maxTokens == 32_768 })
        #expect(await h.client.sawFinalSentinel)
        #expect(h.service.document(for: h.recording.id) != nil)
    }

    @Test("the provider output ceiling caps larger meeting requests")
    func respectsProviderOutputLimit() async throws {
        let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(#"{"id":"fixture/capped","name":"Capped","contextLength":1000000,"inputModalities":["text"],"outputModalities":["text"],"maxCompletionTokens":16384}"#.utf8))
        let h = try await MinutesHarness.make(summaryModel: model)
        h.service.generate(h.recording)
        try await h.waitUntilFinished()
        let requests = await h.client.completionRequests
        #expect(requests.map(\.maxTokens) == [16_384])
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

    static func make(
        delay: Duration = .zero,
        chunker: any MeetingAudioChunking = FakeMeetingAudioChunker(),
        summaryModel: OpenRouterModel? = nil,
        duration: TimeInterval = 10
    ) async throws -> MinutesHarness {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerMinutesTests-\(UUID())")
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(title: "회의", duration: duration, mode: .micOnly)
        try library.add(recording)
        try Data("fixture".utf8).write(to: paths.audioURL(for: recording.id))
        let client = MinutesTestClient(delay: delay)
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "NoteTakerMinutesTests.\(UUID())")!
        if let summaryModel {
            let models = [
                summaryModel,
                OpenRouterModel(
                    id: "fixture/transcription",
                    name: "Transcription",
                    contextLength: 0,
                    inputModalities: ["audio"],
                    outputModalities: ["transcription"]
                )
            ]
            defaults.set(try JSONEncoder().encode(models), forKey: "ai.modelCatalog")
        }
        let config = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults)
        try config.saveKey("fixture-key")
        config.modelID = summaryModel?.id ?? "fixture/summary"
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
    struct CompletionRequest: Sendable {
        let system: String
        let user: String
        let model: String
        let maxTokens: Int
    }

    let delay: Duration
    private(set) var transcriptionCalls = 0
    private(set) var completionCalls = 0
    private(set) var completionRequests: [CompletionRequest] = []
    private var fails = false
    private var transcript = "회의에서 다음 주 출시를 논의했습니다."
    private(set) var sawFinalSentinel = false
    private(set) var sawSyncedTranscriptSentinel = false
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
        completionRequests.append(CompletionRequest(system: system, user: user, model: model, maxTokens: maxTokens))
        if user.contains("LAST_SENTINEL") || user.contains("FINAL_SENTINEL") { sawFinalSentinel = true }
        if user.contains("SYNCED_TRANSCRIPT_SENTINEL") { sawSyncedTranscriptSentinel = true }
        if fails { throw AIError(message: "요청 실패") }
        return AITextResponse(text: "# 회의록\n\n## 요약\n다음 주 출시를 논의했습니다.\n\n## 할 일\n- [ ] 출시 일정 확인")
    }
}
