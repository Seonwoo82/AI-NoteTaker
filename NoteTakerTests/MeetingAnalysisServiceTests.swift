import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Meeting analysis service")
struct MeetingAnalysisServiceTests {
    @Test("analysis publishes timed transcript insights and keeps manual edits outside the generated artifact")
    func publishesAnalysisDocument() async throws {
        let harness = try await AnalysisHarness.make()
        try harness.profile.updateProfile { profile in
            profile.displayName = "Seonwoo"
            profile.aliases = ["SW"]
            profile.terms = [GlossaryTerm(term: "OpenRouter", spokenAs: "오픈 라우터")]
        }
        try harness.profile.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fixture-speakers",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 12
        ), allowedDimensions: 2...2)
        var finished: [(UUID, Bool)] = []
        harness.service.onFinished = { recording, saved in
            finished.append((recording.id, saved))
        }
        harness.service.analyze(harness.recording)

        try await harness.waitUntilFinished()

        let document = try #require(harness.store.document(for: harness.recording.id))
        let plainCache = try JSONFile.load(AITranscriptCache.self,
            from: harness.library.paths.directory(for: harness.recording.id).appending(path: "ai-transcript.json"))
        let resolved = try document.resolved(edits: harness.edits.edits(for: harness.recording.id,
            audioVersion: harness.recording.audioVersion))
        #expect(document.recordingID == harness.recording.id)
        #expect(document.audioVersion == harness.recording.audioVersion)
        #expect(document.analysisModelID == "fixture/analysis")
        #expect(document.transcript.turns.map(\.speakerID) == ["owner", "speaker-guest"])
        #expect(document.insights?.actions.first?.actorSpeakerID == "owner")
        #expect(resolved.myCommitments.map(\.text) == ["Send the revised proposal tomorrow."])
        #expect(document.transcript.speakers.allSatisfy { $0.id != "SW" })
        #expect(plainCache.segments.map(\.text) == ["I will send the revised proposal tomorrow. Can you review it?"])
        #expect(plainCache.language == "auto")
        #expect(await harness.client.completionCalls == 1)
        #expect(await harness.detailedClient.calls == 1)
        #expect(harness.service.status(for: harness.recording.id) == String(localized: "Meeting analysis is complete."))
        #expect(finished.count == 1)
        #expect(finished.first?.0 == harness.recording.id)
        #expect(finished.first?.1 == true)
    }

    @Test("structured meeting insights use the same large provider-aware output allowance", arguments: [131_072, 16_384])
    func structuredInsightsRespectOutputAllowance(providerLimit: Int) async throws {
        let model = OpenRouterModel(id: "fixture/analysis", name: "Analysis", contextLength: 1_000_000,
            inputModalities: ["text"], outputModalities: ["text"], maxCompletionTokens: providerLimit)
        let h = try await AnalysisHarness.make(summaryModel: model)
        h.service.analyze(h.recording)
        try await h.waitUntilFinished()
        #expect(await h.client.outputAllowances == [providerLimit])
        #expect(h.store.document(for: h.recording.id)?.insights != nil)
    }

    @Test("reanalysis reuses the timed transcription cache and applies speaker corrections to analysis prompts")
    func reusesTimedCacheAndAppliesCorrectionsToPrompt() async throws {
        let harness = try await AnalysisHarness.make()
        harness.service.analyze(harness.recording)
        try await harness.waitUntilFinished()
        let firstDocument = try #require(harness.store.document(for: harness.recording.id))
        let guestTurn = try #require(firstDocument.transcript.turns.last)
        _ = try harness.edits.append(recordingID: harness.recording.id,
            audioVersion: harness.recording.audioVersion, kind: .turnSpeaker,
            targetID: guestTurn.id, value: "owner")
        harness.configuration.outputLanguage = "en"

        harness.service.analyze(harness.recording, forceTranscription: false)
        try await harness.waitUntilFinished()

        #expect(await harness.detailedClient.calls == 1)
        let prompts = await harness.client.userPrompts
        #expect(prompts.last?.contains("[\(guestTurn.id)] 1.200-2.000 [owner]") == true)
        #expect(prompts.last?.contains("Write all generated action, question, answer, decision, and topic text in English.") == true)
    }

    @Test("stable insight IDs preserve existing action states when model wording changes")
    func stableInsightIDsPreserveActionStatesAcrossTextChanges() async throws {
        let harness = try await AnalysisHarness.make()
        harness.service.analyze(harness.recording)
        try await harness.waitUntilFinished()
        let original = try #require(harness.store.document(for: harness.recording.id))
        let actionID = try #require(original.insights?.actions.first?.id)
        try await harness.store.save(MeetingIntelligenceDocument(recordingID: original.recordingID,
            audioVersion: original.audioVersion,
            modifiedAt: original.modifiedAt + 1,
            mutationID: UUID(),
            projectName: original.projectName,
            transcript: original.transcript,
            insights: original.insights,
            actionStates: [actionID: MeetingActionStatus.done.rawValue],
            analysisModelID: original.analysisModelID))
        await harness.client.setActionText("Send the revised proposal by tomorrow morning.")

        harness.service.analyze(harness.recording, forceTranscription: false)
        try await harness.waitUntilFinished()

        let regenerated = try #require(harness.store.document(for: harness.recording.id))
        #expect(regenerated.insights?.actions.first?.id == actionID)
        #expect(regenerated.actionStates[actionID] == MeetingActionStatus.done.rawValue)
    }

    @Test("force transcription resolves edits against the new base transcript")
    func forceTranscriptionUsesNewBaseTranscriptForAnalysis() async throws {
        let harness = try await AnalysisHarness.make()
        harness.service.analyze(harness.recording)
        try await harness.waitUntilFinished()
        let original = try #require(harness.store.document(for: harness.recording.id))
        let staleTurnID = try #require(original.transcript.turns.last?.id)
        _ = try harness.edits.append(recordingID: harness.recording.id,
            audioVersion: harness.recording.audioVersion, kind: .turnSpeaker,
            targetID: staleTurnID, value: "owner")
        await harness.detailedClient.setResult(DetailedTranscriptionResult(
            text: "New transcript begins later: I will send the proposal tomorrow.",
            words: [],
            segments: [
                TimedTranscriptionSegment(text: "New transcript begins later: I will send the proposal tomorrow.",
                    start: 2.5, end: 3.5, speakerID: nil)
            ]
        ))

        harness.service.analyze(harness.recording, forceTranscription: true)
        try await harness.waitUntilFinished()

        let prompts = await harness.client.userPrompts
        #expect(prompts.last?.contains("New transcript begins later: I will send the proposal tomorrow.") == true)
        #expect(prompts.last?.contains(staleTurnID) == false)
        #expect(prompts.last?.contains("[owner] New transcript begins later: I will send the proposal tomorrow.") == false)
        #expect(harness.store.document(for: harness.recording.id)?.transcript.turns.first?.start == 2.5)
    }

    @Test("missing API key never calls detailed transcription diarization or analysis")
    func keylessAnalysisDoesNotCallExternalServices() async throws {
        let harness = try await AnalysisHarness.make(configured: false)

        harness.service.analyze(harness.recording)

        #expect(await harness.detailedClient.calls == 0)
        #expect(await harness.client.completionCalls == 0)
        #expect(harness.speakerBackend.diarizeCallCount == 0)
        #expect(harness.service.isRunning(for: harness.recording.id) == false)
        #expect(harness.store.document(for: harness.recording.id) == nil)
    }

    @Test("speaker backend preparation fails before paid transcription and preserves any prior artifact")
    func speakerPreparationFailureDoesNotTranscribeOrReplaceArtifact() async throws {
        let harness = try await AnalysisHarness.make()
        let original = try fixtureDocument(for: harness.recording, modifiedAt: 1_788_508_800_000, actionState: .done)
        try await harness.store.save(original)
        harness.speakerBackend.failPrepare = true

        harness.service.analyze(harness.recording, forceTranscription: true)
        try await harness.waitUntilFinished()

        #expect(await harness.detailedClient.calls == 0)
        #expect(await harness.client.completionCalls == 0)
        #expect(harness.speakerBackend.prepareCallCount == 1)
        #expect(harness.speakerBackend.diarizeCallCount == 0)
        #expect(harness.store.document(for: harness.recording.id) == original)
        #expect(harness.service.status(for: harness.recording.id).contains("Speaker backend is unavailable."))
    }

    @Test("reanalysis wins over a future-timestamped synced artifact and keeps matching action state")
    func reanalysisWinsOverFutureTimestampedArtifact() async throws {
        let harness = try await AnalysisHarness.make()
        harness.service.analyze(harness.recording)
        try await harness.waitUntilFinished()
        let generated = try #require(harness.store.document(for: harness.recording.id))
        let actionID = try #require(generated.insights?.actions.first?.id)
        let futureTimestamp = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        let futureArtifact = MeetingIntelligenceDocument(recordingID: generated.recordingID,
            audioVersion: generated.audioVersion,
            modifiedAt: futureTimestamp,
            mutationID: UUID(),
            projectName: "Future synced project",
            transcript: generated.transcript,
            insights: generated.insights,
            actionStates: [actionID: MeetingActionStatus.done.rawValue],
            analysisModelID: generated.analysisModelID)
        try await harness.store.save(futureArtifact)

        harness.service.analyze(harness.recording, forceTranscription: false)
        try await harness.waitUntilFinished()

        let regenerated = try #require(harness.store.document(for: harness.recording.id))
        #expect(regenerated.mutationID != futureArtifact.mutationID)
        #expect(regenerated.modifiedAt > futureArtifact.modifiedAt)
        #expect(regenerated.projectName == futureArtifact.projectName)
        #expect(regenerated.actionStates[actionID] == MeetingActionStatus.done.rawValue)
    }

    @Test("bad analysis citations fail without replacing a previous successful artifact")
    func badCitationsPreserveOldArtifact() async throws {
        let harness = try await AnalysisHarness.make()
        harness.service.analyze(harness.recording)
        try await harness.waitUntilFinished()
        let original = try #require(harness.store.document(for: harness.recording.id))
        await harness.client.setMalformedCitations(true)

        harness.service.analyze(harness.recording, forceTranscription: true)
        try await harness.waitUntilFinished()

        #expect(harness.store.document(for: harness.recording.id) == original)
        #expect(harness.service.isRunning(for: harness.recording.id) == false)
    }

    @Test("deleted or stale version recordings cannot publish late analysis")
    func deletedOrStaleRecordingCancelsLatePublication() async throws {
        let harness = try await AnalysisHarness.make(delay: .milliseconds(100))
        var finished: [(UUID, Bool)] = []
        harness.service.onFinished = { recording, saved in
            finished.append((recording.id, saved))
        }

        harness.service.analyze(harness.recording)
        await harness.detailedClient.waitForCalls(1)
        #if os(iOS)
        var deleted = harness.recording
        deleted.deletedAt = .now
        try harness.library.update(deleted)
        harness.service.cancel(harness.recording.id)
        try FileManager.default.removeItem(at: harness.library.paths.directory(for: harness.recording.id))
        #else
        try harness.library.moveToRecentlyDeleted(id: harness.recording.id)
        harness.service.cancel(harness.recording.id)
        try harness.library.deletePermanently(id: harness.recording.id)
        #endif
        try await Task.sleep(for: .milliseconds(150))

        #expect(harness.store.document(for: harness.recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "meeting-intelligence.json").path))
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "meeting-transcript-cache.json").path))
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "ai-transcript.json").path))
        #expect(finished.count == 1)
        #expect(finished.first?.0 == harness.recording.id)
        #expect(finished.first?.1 == false)
    }

    @Test("credential changes cancel running analysis before any sidecar is published")
    func credentialChangesCancelRunningAnalysis() async throws {
        let harness = try await AnalysisHarness.make(delay: .milliseconds(100))
        var finished: [(UUID, Bool)] = []
        harness.service.onFinished = { recording, saved in
            finished.append((recording.id, saved))
        }

        harness.service.analyze(harness.recording)
        await harness.detailedClient.waitForCalls(1)
        harness.service.credentialsDidChange()
        try await Task.sleep(for: .milliseconds(150))

        #expect(harness.store.document(for: harness.recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "meeting-intelligence.json").path))
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "meeting-transcript-cache.json").path))
        #expect(!FileManager.default.fileExists(atPath: harness.library.paths.directory(for: harness.recording.id).appending(path: "ai-transcript.json").path))
        #expect(finished.count == 1)
        #expect(finished.first?.0 == harness.recording.id)
        #expect(finished.first?.1 == false)
        #expect(harness.service.wasCancelled(for: harness.recording.id))
    }
}

private func fixtureDocument(for recording: Recording, modifiedAt: Int64, actionState: MeetingActionStatus) throws -> MeetingIntelligenceDocument {
    let transcript = MeetingTranscript(recordingID: recording.id,
        audioVersion: recording.audioVersion,
        transcriptionModelID: "fixture/stt",
        speakers: [MeetingSpeaker(id: "owner", name: "Seonwoo", isOwner: true)],
        turns: [TranscriptTurn(id: "turn-fixture", start: 0, end: 1, speakerID: "owner",
            text: "I will send the revised proposal tomorrow.")])
    let insights = MeetingInsights(actions: [MeetingAction(id: "action-fixture", kind: .commitment,
        text: "Send the revised proposal tomorrow.", actorSpeakerID: "owner", targetSpeakerID: nil,
        dueText: "tomorrow", evidenceTurnIDs: ["turn-fixture"])])
    return MeetingIntelligenceDocument(recordingID: recording.id,
        audioVersion: recording.audioVersion,
        modifiedAt: modifiedAt,
        mutationID: UUID(),
        projectName: "Existing project",
        transcript: transcript,
        insights: insights,
        actionStates: ["action-fixture": actionState.rawValue],
        analysisModelID: "fixture/analysis")
}

@MainActor
private struct AnalysisHarness {
    let library: LibraryStore
    let recording: Recording
    let configuration: AIConfiguration
    let profile: MeetingProfileStore
    let store: MeetingIntelligenceStore
    let edits: MeetingEditLog
    let speakerBackend: AnalysisSpeakerBackend
    let client: AnalysisOpenRouterClient
    let detailedClient: AnalysisDetailedClient
    let service: MeetingAnalysisService

    static func make(configured: Bool = true, delay: Duration = .zero, summaryModel: OpenRouterModel? = nil) async throws -> AnalysisHarness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingAnalysisServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            title: "Product meeting", duration: 4, mode: .micOnly)
        try library.add(recording)
        try Data("audio".utf8).write(to: paths.audioURL(for: recording.id), options: .atomic)

        let client = AnalysisOpenRouterClient()
        let detailedClient = AnalysisDetailedClient(delay: delay)
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "MeetingAnalysisServiceTests.\(UUID().uuidString)")!
        if let summaryModel {
            let models = [summaryModel, OpenRouterModel(id: "fixture/stt", name: "STT", contextLength: 0,
                inputModalities: ["audio"], outputModalities: ["transcription"])]
            defaults.set(try JSONEncoder().encode(models), forKey: "ai.modelCatalog")
        }
        let configuration = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults)
        configuration.modelID = "fixture/analysis"
        configuration.transcriptionModelID = "fixture/stt"
        configuration.outputLanguage = "ko"
        if configured { try configuration.saveKey("fixture-key") }
        let profile = MeetingProfileStore(root: root.appending(path: "Profile", directoryHint: .isDirectory))
        try profile.updateProfile { profile in
            profile.displayName = "Seonwoo"
        }
        try profile.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fixture-speakers",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 12
        ), allowedDimensions: 2...2)
        let store = MeetingIntelligenceStore(library: library)
        let edits = MeetingEditLog(root: root.appending(path: "Edits", directoryHint: .isDirectory))
        let speakerBackend = AnalysisSpeakerBackend()
        let service = MeetingAnalysisService(library: library, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: speakerBackend,
            client: client, detailedClient: detailedClient, chunker: AnalysisChunker())
        return AnalysisHarness(library: library, recording: recording, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: speakerBackend,
            client: client, detailedClient: detailedClient, service: service)
    }

    func waitUntilFinished() async throws {
        for _ in 0..<300 {
            if !service.isRunning(for: recording.id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AIError(message: "Timed out waiting for meeting analysis")
    }
}

private struct AnalysisChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("audio".utf8), format: "wav", startTime: 0, duration: 4)
    }
}

private final class AnalysisSpeakerBackend: SpeakerAnalysisServing, @unchecked Sendable {
    let embeddingModelID = "fixture-speakers"
    private let lock = NSLock()
    var failPrepare = false
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
        if recordPrepareCallAndShouldFail() {
            throw AIError(message: "Speaker backend is unavailable.")
        }
    }

    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        recordDiarizeCall()
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

    private func recordPrepareCallAndShouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recordedPrepareCallCount += 1
        return failPrepare
    }

    private func recordDiarizeCall() {
        lock.lock()
        defer { lock.unlock() }
        recordedDiarizeCallCount += 1
    }
}

private actor AnalysisDetailedClient: DetailedTranscriptionServing {
    let delay: Duration
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var result = DetailedTranscriptionResult(
        text: "I will send the revised proposal tomorrow. Can you review it?",
        words: [],
        segments: [
            TimedTranscriptionSegment(text: "I will send the revised proposal tomorrow.",
                start: 0, end: 1, speakerID: nil),
            TimedTranscriptionSegment(text: "Can you review it?",
                start: 1.2, end: 2.0, speakerID: nil)
        ]
    )

    init(delay: Duration) {
        self.delay = delay
    }

    func setResult(_ result: DetailedTranscriptionResult) {
        self.result = result
    }

    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String,
                            language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        try? await Task.sleep(for: delay)
        return result
    }

    func waitForCalls(_ expected: Int) async {
        if calls >= expected { return }
        await withCheckedContinuation { continuation in
            if calls >= expected {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor AnalysisOpenRouterClient: OpenRouterServing {
    private(set) var completionCalls = 0
    private(set) var userPrompts: [String] = []
    private(set) var outputAllowances: [Int] = []
    private var malformedCitations = false
    private var actionText = "Send the revised proposal tomorrow."

    func setMalformedCitations(_ value: Bool) {
        malformedCitations = value
    }

    func setActionText(_ value: String) {
        actionText = value
    }

    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionCalls += 1
        userPrompts.append(user)
        outputAllowances.append(maxTokens)
        let turnID = malformedCitations ? "missing-turn" : firstTurnID(in: user)
        let speakerPattern = #"\[turn-[A-Fa-f0-9]+\].*?\[([A-Za-z0-9_-]+)\]"#
        let regex = try NSRegularExpression(pattern: speakerPattern)
        let match = regex.firstMatch(in: user, range: NSRange(user.startIndex..., in: user))
        let actor = match.flatMap { Range($0.range(at: 1), in: user) }.map { String(user[$0]) }
        let actorJSON = actor.flatMap { $0 == "unknown" ? nil : "\"\($0)\"" } ?? "null"
        return AITextResponse(text: """
        {
          "schemaVersion": 1,
              "actions": [
            {
              "id": "model-action",
              "kind": "commitment",
              "text": "\(actionText)",
              "actorSpeakerID": \(actorJSON),
              "targetSpeakerID": null,
              "dueText": "tomorrow",
              "evidenceTurnIDs": ["\(turnID)"]
            }
          ],
          "questions": [],
          "decisions": []
        }
        """)
    }

    private func firstTurnID(in prompt: String) -> String {
        let pattern = #"\[(turn-[A-Fa-f0-9]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let range = Range(match.range(at: 1), in: prompt) else {
            return "missing-turn"
        }
        return String(prompt[range])
    }
}
