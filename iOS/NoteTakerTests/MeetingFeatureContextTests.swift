import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Meeting feature context")
struct MeetingFeatureContextTests {
    @Test("default profile keeps automatic meeting analysis off and preserves original AI notes")
    func defaultProfileUsesOriginalNotesPipeline() async throws {
        let h = try await FeatureHarness.make(configured: true, autoGenerate: true, automaticallyAnalyze: false)

        h.context.recordingDidFinish(h.recording)
        try await h.waitForNotes()

        #expect(h.notes.document(for: h.recording.id)?.markdown.contains("Original AI notes") == true)
        #expect(h.context.store.document(for: h.recording.id) == nil)
        #expect(await h.client.detailedCallCount == 0)
    }

    @Test("non-cancelled meeting analysis failure falls back to original AI notes")
    func analysisFailureFallsBackToOriginalNotesPipeline() async throws {
        let h = try await FeatureHarness.make(configured: true, autoGenerate: true,
            automaticallyAnalyze: true, failsAnalysisCompletion: true)

        h.context.recordingDidFinish(h.recording)
        try await h.waitForNotes()

        #expect(h.notes.document(for: h.recording.id)?.markdown.contains("Original AI notes") == true)
        #expect(h.context.store.document(for: h.recording.id) == nil)
        #expect(await h.client.completionCallCount >= 2)
    }

    @Test("recording deletion and credential loss cancel the pending automatic analysis chain")
    func unavailableRecordingAndCredentialLossClearPendingAutoAnalysis() async throws {
        let h = try await FeatureHarness.make(configured: true, autoGenerate: true,
            automaticallyAnalyze: true, blocksDetailedTranscription: true)
        h.library.onRecordingUnavailable = { id in h.context.recordingUnavailable(id) }
        h.config.onCredentialsChanged = {
            h.notes.credentialsDidChange()
            h.context.credentialsDidChange()
        }

        h.context.recordingDidFinish(h.recording)
        try await h.waitForDetailedCall()
        #if os(iOS)
        var deleted = h.recording
        deleted.deletedAt = .now
        try h.library.update(deleted)
        #else
        try h.library.moveToRecentlyDeleted(id: h.recording.id)
        #endif
        try h.config.removeKey()
        try await h.waitUntilAnalysisStops()

        #expect(h.notes.document(for: h.recording.id) == nil)
        #expect(h.context.store.document(for: h.recording.id) == nil)
        #expect(!h.context.analysis.isRunning(for: h.recording.id))
    }

    @Test("meeting callbacks configured with automatic false do not request automatic sync")
    func automaticFalseDoesNotWireProfileStoreOrEditCallbacksToSync() async throws {
        let h = try await FeatureHarness.make(configured: true, autoGenerate: true, automaticallyAnalyze: false)
        let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
        settings.endpoint = "https://sync.example"
        settings.token = "secret"
        settings.isEnabled = true
        let transport = CountingSyncTransport()
        var factoryCalls = 0
        let sync = SyncCoordinator(settings: settings) { _ in
            factoryCalls += 1
            return transport
        }
        h.context.configureSync(sync, automatic: false)
        sync.configureAutomaticSync(library: h.library, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        sync.setAutomaticSyncActive(true)
        try await spinUntil { factoryCalls == 1 && !sync.isSyncing }

        try h.context.profile.updateProfile { profile in
            profile.displayName = "Seonwoo"
        }
        try await h.context.store.save(h.document(projectName: "Project Apollo"))
        try h.context.edits.append(recordingID: h.recording.id, audioVersion: h.recording.audioVersion,
            kind: .speakerName, targetID: "speaker-a", value: "Seonwoo")
        try await Task.sleep(for: .milliseconds(50))
        sync.setAutomaticSyncActive(false)

        #expect(factoryCalls == 1)
    }

    @Test("edits reject missing targets and stale audio while valid owner correction resolves")
    func editValidationAndResolution() async throws {
        let h = try await FeatureHarness.make(configured: true, autoGenerate: false, automaticallyAnalyze: false)
        try await h.context.store.save(h.document(projectName: "Project Apollo"))

        #expect(throws: MeetingStorageError.invalidEditPage) {
            try h.context.edit(h.recording, kind: .speakerOwner, targetID: "missing-speaker", value: "true")
        }
        #expect(throws: MeetingStorageError.invalidEditPage) {
            try h.context.edit(h.recording, kind: .turnSpeaker, targetID: "missing-turn", value: "speaker-a")
        }
        #expect(throws: MeetingStorageError.invalidEditPage) {
            try h.context.edit(h.recording, kind: .actionStatus, targetID: "missing-action", value: "done")
        }
        var stale = h.recording
        stale.audioVersion = h.recording.audioVersion - 1
        #expect(throws: MeetingStorageError.audioVersionMismatch) {
            try h.context.edit(stale, kind: .speakerOwner, targetID: "speaker-a", value: "true")
        }

        try h.context.edit(h.recording, kind: .speakerOwner, targetID: "speaker-a", value: "true")
        let resolved = try #require(h.context.resolved(h.recording))
        #expect(resolved.transcript.speakers.first(where: { $0.id == "speaker-a" })?.isOwner == true)
        #expect(resolved.ownerTurns.map(\.id) == ["turn-1"])
    }

    @Test("stale enrollment start does not cancel a replacement session")
    func staleEnrollmentStartDoesNotCancelReplacementSession() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        let capture = VoiceEnrollmentCapture(requestPermission: { await withCheckedContinuation { permission = $0 } })
        let h = try await FeatureHarness.make(configured: true, autoGenerate: false,
            automaticallyAnalyze: false, enrollmentCapture: capture)
        await h.context.prepareVoiceModels()
        var firstStopPlayback: CheckedContinuation<Void, Never>?
        var stopCalls = 0
        h.context.stopPlayback = {
            stopCalls += 1
            if stopCalls == 1 {
                await withCheckedContinuation { firstStopPlayback = $0 }
            }
        }

        let staleStart = Task { await h.context.beginEnrollment() }
        try await spinUntil { firstStopPlayback != nil }
        h.context.cancelEnrollment()

        let replacementStart = Task { await h.context.beginEnrollment() }
        try await spinUntil { permission != nil }
        firstStopPlayback?.resume()
        await staleStart.value

        #expect(h.context.enrollmentIsBusy)

        h.context.cancelEnrollment()
        permission?.resume(returning: false)
        await replacementStart.value
    }

    @Test("cancelled enrollment task does not request microphone access")
    func cancelledEnrollmentTaskDoesNotRequestMicrophoneAccess() async throws {
        var permissionRequests = 0
        let capture = VoiceEnrollmentCapture(requestPermission: {
            permissionRequests += 1
            return false
        })
        let h = try await FeatureHarness.make(configured: true, autoGenerate: false,
            automaticallyAnalyze: false, enrollmentCapture: capture)
        await h.context.prepareVoiceModels()

        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            await h.context.beginEnrollment()
        }
        task.cancel()
        await task.value

        #expect(!h.context.enrollmentIsBusy)
        #expect(permissionRequests == 0)
    }
}

@MainActor
private struct FeatureHarness {
    let root: URL
    let library: LibraryStore
    let recording: Recording
    let client: FeatureOpenRouterClient
    let config: AIConfiguration
    let notes: MeetingNotesService
    let context: MeetingFeatureContext

    static func make(
        configured: Bool,
        autoGenerate: Bool,
        automaticallyAnalyze: Bool,
        blocksDetailedTranscription: Bool = false,
        failsAnalysisCompletion: Bool = false,
        enrollmentCapture: VoiceEnrollmentCapture? = nil
    ) async throws -> FeatureHarness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingFeatureContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Feature meeting", createdAt: Date(timeIntervalSince1970: 1_788_310_923),
            duration: 12, mode: .micOnly, audioVersion: 2, hasTranscript: true,
            modifiedAt: 1_788_310_923_000)
        try library.add(recording)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: library.audioURL(for: recording), options: .atomic)

        let client = FeatureOpenRouterClient(blocksDetailedTranscription: blocksDetailedTranscription,
            failsAnalysisCompletion: failsAnalysisCompletion)
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "MeetingFeatureContextTests.\(UUID().uuidString)")!
        let config = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults)
        if configured {
            try config.saveKey("fixture-key")
            config.modelID = "fixture/summary"
            config.transcriptionModelID = "fixture/transcription"
        }
        config.autoGenerate = autoGenerate
        let chunker = FeatureChunker()
        let environment = AIEnvironment(client: client, keyStore: keyStore, chunker: chunker, defaults: defaults)
        let notes = MeetingNotesService(configuration: config, client: client, chunker: chunker, library: library)
        let context = MeetingFeatureContext(library: library, configuration: config,
            environment: environment, notes: notes, backend: FeatureSpeakerBackend(),
            enrollmentCapture: enrollmentCapture)
        if automaticallyAnalyze {
            try context.profile.updateProfile { profile in
                profile.automaticallyAnalyze = true
            }
        }
        return FeatureHarness(root: root, library: library, recording: recording,
            client: client, config: config, notes: notes, context: context)
    }

    func waitForNotes() async throws {
        try await spinUntil {
            if notes.document(for: recording.id) != nil { return true }
            if case .failed = notes.progress(for: recording.id) { return true }
            return false
        }
        _ = try #require(notes.document(for: recording.id))
    }

    func waitUntilAnalysisStops() async throws {
        try await spinUntil { !context.analysis.isRunning(for: recording.id) }
    }

    func waitForDetailedCall() async throws {
        for _ in 0..<300 {
            if await client.detailedCallCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AIError(message: "Timed out waiting for detailed transcription.")
    }

    func document(projectName: String) -> MeetingIntelligenceDocument {
        let transcript = MeetingTranscript(recordingID: recording.id, audioVersion: recording.audioVersion,
            transcriptionModelID: "fixture/transcription",
            speakers: [
                MeetingSpeaker(id: "speaker-a", name: "Speaker A", isOwner: false),
                MeetingSpeaker(id: "speaker-b", name: "Speaker B", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-1", start: 0, end: 2, speakerID: "speaker-a", text: "I will send notes."),
                TranscriptTurn(id: "turn-2", start: 2, end: 4, speakerID: "speaker-b", text: "Can you review them?")
            ])
        let insights = MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Send notes",
                actorSpeakerID: "speaker-a", targetSpeakerID: nil, dueText: nil, evidenceTurnIDs: ["turn-1"]),
            MeetingAction(id: "action-2", kind: .request, text: "Review notes",
                actorSpeakerID: "speaker-b", targetSpeakerID: "speaker-a", dueText: nil, evidenceTurnIDs: ["turn-2"])
        ], questions: [], decisions: [])
        return MeetingIntelligenceDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
            modifiedAt: 30, mutationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            projectName: projectName, transcript: transcript, insights: insights,
            actionStates: ["action-1": "open"], analysisModelID: "fixture/summary")
    }
}

private actor FeatureOpenRouterClient: OpenRouterServing, DetailedTranscriptionServing {
    private(set) var detailedCallCount = 0
    private(set) var completionCallCount = 0
    private let blocksDetailedTranscription: Bool
    private let failsAnalysisCompletion: Bool

    init(blocksDetailedTranscription: Bool = false, failsAnalysisCompletion: Bool = false) {
        self.blocksDetailedTranscription = blocksDetailedTranscription
        self.failsAnalysisCompletion = failsAnalysisCompletion
    }

    func models() async throws -> [OpenRouterModel] {
        [
            OpenRouterModel(id: "fixture/summary", name: "Summary", contextLength: 32_000,
                inputModalities: ["text"], outputModalities: ["text"]),
            OpenRouterModel(id: "fixture/transcription", name: "Transcription", contextLength: 0,
                inputModalities: ["audio"], outputModalities: ["transcription"])
        ]
    }

    func validateKey(_ apiKey: String) async throws {}

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "Original transcript")
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionCallCount += 1
        if system == MeetingAnalysisPrompt.systemPrompt {
            if failsAnalysisCompletion { throw AIError(message: "Fixture meeting analysis failure.") }
            let turnID = firstTurnID(in: user) ?? "turn-missing"
            return AITextResponse(text: #"{"schemaVersion":1,"actions":[],"questions":[],"decisions":[{"id":"decision-1","topic":"Follow up","status":"decided","steps":[{"kind":"decision","text":"Follow up after the meeting","speakerID":null,"evidenceTurnIDs":["\#(turnID)"]}]}]}"#)
        }
        return AITextResponse(text: "# Original AI notes\n\nThe original notes pipeline ran.")
    }

    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String,
                            language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        detailedCallCount += 1
        if blocksDetailedTranscription {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }
        return DetailedTranscriptionResult(text: "I will send notes.",
            words: [], segments: [
                TimedTranscriptionSegment(text: "I will send notes.", start: 0, end: 1, speakerID: "speaker-a")
            ])
    }

    private func firstTurnID(in text: String) -> String? {
        guard let range = text.range(of: "[turn-") else { return nil }
        let start = text.index(after: range.lowerBound)
        guard let end = text[start...].firstIndex(of: "]") else { return nil }
        return String(text[start..<end])
    }
}

private struct FeatureChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("audio".utf8), format: "wav", startTime: 0, duration: 1)
    }
}

private struct FeatureSpeakerBackend: SpeakerAnalysisServing {
    let embeddingModelID = "fixture/embedding"
    func prepare() async throws {}
    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        AcousticDiarization(speakers: [AcousticSpeaker(id: "speaker-a", embedding: [1, 0])],
            spans: [AcousticSpeakerSpan(start: 0, end: 1, speakerID: "speaker-a")])
    }
    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] { [1, 0] }
}

@MainActor
private final class CountingSyncTransport: SyncTransport {
    func health() async throws -> SyncHealth { SyncHealth(ok: true, schemaVersion: 1) }
    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        SyncRecordingPage(recordings: [], nextCursor: nil)
    }
    func putRecording(_ recording: Recording) async throws -> Recording { recording }
    func uploadAudio(for recording: Recording, from url: URL) async throws {}
    func downloadAudio(for recording: Recording, to url: URL) async throws {}
}

@MainActor
private final class StubSyncTokenStore: SyncTokenStore {
    var token: String?
    func loadToken() throws -> String? { token }
    func saveToken(_ token: String) throws { self.token = token }
}

private func syncDefaults() throws -> UserDefaults {
    let name = "MeetingFeatureContextTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func spinUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AIError(message: "Timed out waiting for meeting feature test condition.")
}
