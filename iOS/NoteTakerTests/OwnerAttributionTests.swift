import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Owner attribution reapplication")
struct OwnerAttributionTests {
    @Test("reenrollment reapplies saved transcript ownership locally without changing turn content or insights")
    func reenrollmentReappliesSavedTranscriptOwnershipLocally() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        let original = try #require(h.store.document(for: h.recording.id))
        h.backend.diarization = h.standardDiarization
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)

        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let repaired = try #require(h.store.document(for: h.recording.id))
        #expect(repaired.transcript.turns.map(\.id) == original.transcript.turns.map(\.id))
        #expect(repaired.transcript.turns.map(\.text) == original.transcript.turns.map(\.text))
        #expect(repaired.transcript.turns.map(\.start) == original.transcript.turns.map(\.start))
        #expect(repaired.transcript.turns.map(\.end) == original.transcript.turns.map(\.end))
        #expect(repaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(repaired.transcript.speakers.first(where: { $0.id == "speaker-guest" })?.name == "Seonwoo")
        #expect(repaired.transcript.speakers.first(where: { $0.id == "speaker-guest" })?.isOwner == true)
        #expect(repaired.transcript.speakers.contains(where: { $0.id == "owner" }) == false)
        #expect(repaired.insights?.actions.first?.actorSpeakerID == "speaker-host")
        #expect(repaired.insights?.actions.first?.targetSpeakerID == "speaker-guest")
        #expect(repaired.actionStates == original.actionStates)
        #expect(await h.client.completionCalls == 0)
        #expect(await h.detailed.calls == 0)
    }

    @Test("deleting the voice profile removes generated owner turns while keeping valid raw speaker IDs")
    func deletingVoiceProfileRemovesGeneratedOwnerTurns() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        try h.profile.deleteVoiceProfile()

        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let repaired = try #require(h.store.document(for: h.recording.id))
        #expect(repaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(repaired.transcript.speakers.filter(\.isOwner).isEmpty)
        #expect(repaired.transcript.speakers.contains(where: { $0.id == "owner" }) == false)
        #expect(repaired.insights?.actions.first?.actorSpeakerID == "speaker-host")
        #expect(repaired.insights?.actions.first?.targetSpeakerID == "speaker-guest")
        #expect(await h.client.completionCalls == 0)
        #expect(await h.detailed.calls == 0)
    }

    @Test("cached local acoustics let a later profile-only change avoid another diarization pass")
    func cachedLocalAcousticsAvoidSecondDiarizationPass() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))

        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.service.reapplyOwnerAttributionForSavedMeetings()
        #expect(h.backend.diarizeCallCount == 1)

        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let repaired = try #require(h.store.document(for: h.recording.id))
        #expect(h.backend.diarizeCallCount == 1)
        #expect(repaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(repaired.transcript.speakers.first(where: { $0.id == "speaker-host" })?.isOwner == true)
        #expect(repaired.transcript.speakers.contains(where: { $0.id == "owner" }) == false)
    }

    @Test("unchanged stable documents still persist local sidecar and reuse it")
    func unchangedStableDocumentsPersistLocalSidecar() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "speaker-host", guestSpeakerID: "speaker-guest"))

        try await h.service.reapplyOwnerAttributionForSavedMeetings()
        #expect(h.backend.diarizeCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: h.sidecarURL.path))

        try await h.service.reapplyOwnerAttributionForSavedMeetings()
        #expect(h.backend.diarizeCallCount == 1)
    }

    @Test("empty cached embeddings are valid local acoustics and avoid repeat diarization")
    func emptyCachedEmbeddingsAvoidRepeatDiarization() async throws {
        let h = try await OwnerAttributionHarness.make()
        try await h.store.save(h.document(ownerSpeakerID: "speaker-host", guestSpeakerID: "speaker-guest"))
        h.backend.diarization = AcousticDiarization(
            speakers: [
                AcousticSpeaker(id: "host", embedding: []),
                AcousticSpeaker(id: "guest", embedding: [])
            ],
            spans: [
                AcousticSpeakerSpan(start: 0, end: 1, speakerID: "host"),
                AcousticSpeakerSpan(start: 1.2, end: 2.0, speakerID: "guest")
            ])

        try await h.service.reapplyOwnerAttributionForSavedMeetings()
        #expect(h.backend.diarizeCallCount == 1)

        try await h.service.reapplyOwnerAttributionForSavedMeetings()
        #expect(h.backend.diarizeCallCount == 1)
    }

    @Test("fresh ambiguous acoustics do not publish phantom owner or stale speaker IDs")
    func ambiguousFreshAcousticsDoNotPublishPhantomOwner() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        h.backend.diarization = AcousticDiarization(
            speakers: [
                AcousticSpeaker(id: "host", embedding: [1, 0]),
                AcousticSpeaker(id: "guest", embedding: [0, 1])
            ],
            spans: [
                AcousticSpeakerSpan(start: 0, end: 2, speakerID: "host"),
                AcousticSpeakerSpan(start: 0, end: 2, speakerID: "guest")
            ])

        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let repaired = try #require(h.store.document(for: h.recording.id))
        #expect(repaired.transcript.turns.map(\.speakerID) == [nil, nil])
        #expect(repaired.transcript.speakers.isEmpty)
        #expect(repaired.transcript.speakers.contains(where: { $0.id == "owner" }) == false)
        #expect(repaired.insights?.actions.first?.actorSpeakerID == nil)
        #expect(repaired.insights?.actions.first?.targetSpeakerID == nil)
    }

    @Test("corrupt sidecar is ignored instead of crashing or reusing invalid mappings")
    func corruptSidecarIsIgnored() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        let corrupt = OwnerAttributionSidecar(recordingID: h.recording.id,
            audioVersion: h.recording.audioVersion,
            documentRevision: try h.currentRevision(),
            embeddingModelID: h.backend.embeddingModelID,
            profileFingerprint: "corrupt",
            speakers: [
                CachedAcousticSpeaker(AcousticSpeaker(id: "dup", embedding: [1, 0])),
                CachedAcousticSpeaker(AcousticSpeaker(id: "dup", embedding: [0, 1]))
            ],
            turnRawSpeakerIDs: ["turn-host": "dup"])
        try JSONEncoder().encode(corrupt).write(to: h.sidecarURL, options: .atomic)

        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let repaired = try #require(h.store.document(for: h.recording.id))
        #expect(h.backend.diarizeCallCount == 1)
        #expect(repaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
    }

    @Test("deferred local repair does not overwrite a newer saved document")
    func deferredLocalRepairDoesNotOverwriteNewerDocument() async throws {
        let h = try await OwnerAttributionHarness.make()
        let gate = DiarizeGate()
        h.backend.gate = gate
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))

        let repair = Task { @MainActor in
            try await h.service.reapplyOwnerAttributionForSavedMeetings()
        }
        await gate.waitForStart()
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest",
            modifiedAt: 1_000, mutationID: UUID(), hostText: "Remote text wins."))
        await gate.release()
        try await repair.value

        let final = try #require(h.store.document(for: h.recording.id))
        #expect(final.transcript.turns.first?.text == "Remote text wins.")
        #expect(final.modifiedAt == 1_000)
    }

    @Test("a newer owner reapplication cancels an older serialized repair")
    func newerOwnerReapplicationCancelsOlderRepair() async throws {
        let h = try await OwnerAttributionHarness.make()
        try h.profile.saveVoiceProfile(h.voiceA, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        h.backend.delay = .milliseconds(120)

        let first = h.service.scheduleOwnerAttributionReapplication()
        try await Task.sleep(for: .milliseconds(20))
        let second = h.service.scheduleOwnerAttributionReapplication()
        await first.value
        await second.value

        #expect(h.backend.diarizeCallCount == 1)
        #expect(!h.service.isRunning(for: h.recording.id))
    }

    @Test("selected refresh waits for a blocked full sweep instead of cancelling remaining records")
    func selectedRefreshWaitsForBlockedFullSweep() async throws {
        let h = try await OwnerAttributionHarness.make()
        let second = try h.addRecording(title: "Second owner attribution")
        let gate = DiarizeGate()
        h.backend.gate = gate
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        try await h.store.save(h.document(recording: second, ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))

        let sweep = h.service.scheduleOwnerAttributionReapplication()
        await gate.waitForStart()
        let refresh = h.service.scheduleOwnerAttributionRefresh(recording: second)
        #expect(h.backend.diarizeCallCount == 0)
        await gate.release()
        await sweep.value
        await refresh.value

        let firstRepaired = try #require(h.store.document(for: h.recording.id))
        let secondRepaired = try #require(h.store.document(for: second.id))
        #expect(firstRepaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(secondRepaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(firstRepaired.transcript.speakers.first(where: { $0.id == "speaker-guest" })?.isOwner == true)
        #expect(secondRepaired.transcript.speakers.first(where: { $0.id == "speaker-guest" })?.isOwner == true)
    }

    @Test("full sweep records local owner attribution failures and continues other records")
    func fullSweepRecordsLocalFailuresAndContinues() async throws {
        let h = try await OwnerAttributionHarness.make()
        let second = try h.addRecording(title: "Second owner attribution")
        h.backend.failedAudioPathFragments = [h.recording.id.uuidString]
        try h.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.store.save(h.document(ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))
        try await h.store.save(h.document(recording: second, ownerSpeakerID: "owner", guestSpeakerID: "speaker-guest"))

        try await h.service.reapplyOwnerAttributionForSavedMeetings()

        let first = try #require(h.store.document(for: h.recording.id))
        let repairedSecond = try #require(h.store.document(for: second.id))
        #expect(first.transcript.turns.map(\.speakerID) == ["owner", "speaker-guest"])
        #expect(repairedSecond.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(h.service.ownerAttributionIssue(for: h.recording.id)?.contains("refused local diarization") == true)
        #expect(h.service.status(for: h.recording.id).contains("refused local diarization"))
        #expect(h.service.ownerAttributionIssue(for: second.id) == nil)
    }

    @Test("feature context accepts virtual owner edits only when the resolved transcript has an owner")
    func featureContextAllowsValidVirtualOwnerEdits() async throws {
        let h = try await OwnerAttributionFeatureHarness.make()
        try await h.context.store.save(h.document(includeOwner: true))

        try h.context.edit(h.recording, kind: .turnSpeaker, targetID: "turn-guest", value: "owner")
        try h.context.edit(h.recording, kind: .speakerName, targetID: "owner", value: "Seonwoo")
        try h.context.edit(h.recording, kind: .speakerOwner, targetID: "owner", value: "true")

        #expect(h.context.edits.edits(for: h.recording.id, audioVersion: h.recording.audioVersion).map(\.value) == [
            "owner", "Seonwoo", "true"
        ])

        let missing = try await OwnerAttributionFeatureHarness.make()
        try await missing.context.store.save(missing.document(includeOwner: false))
        #expect(throws: MeetingStorageError.invalidEditPage) {
            try missing.context.edit(missing.recording, kind: .turnSpeaker, targetID: "turn-guest", value: "owner")
        }
    }

    @Test("feature context load refreshes one saved recording owner attribution")
    func featureContextLoadRefreshesSavedOwnerAttribution() async throws {
        let h = try await OwnerAttributionFeatureHarness.make()
        try h.context.profile.updateProfile { profile in profile.displayName = "Seonwoo" }
        try h.context.profile.saveVoiceProfile(h.voiceB, allowedDimensions: 2...2)
        try await h.context.store.save(h.repairableDocument())

        await h.context.load(h.recording)

        let repaired = try #require(h.context.store.document(for: h.recording.id))
        #expect(h.backend.diarizeCallCount == 1)
        #expect(repaired.transcript.turns.map(\.speakerID) == ["speaker-host", "speaker-guest"])
        #expect(repaired.transcript.speakers.first(where: { $0.id == "speaker-guest" })?.isOwner == true)
        #expect(repaired.transcript.speakers.contains(where: { $0.id == "owner" }) == false)
    }
}

@MainActor
private struct OwnerAttributionHarness {
    let root: URL
    let library: LibraryStore
    let recording: Recording
    let configuration: AIConfiguration
    let profile: MeetingProfileStore
    let store: MeetingIntelligenceStore
    let edits: MeetingEditLog
    let backend: OwnerAttributionBackend
    let client: OwnerAttributionClient
    let detailed: OwnerAttributionDetailedClient
    let service: MeetingAnalysisService

    let voiceA = LocalVoiceProfile(modelID: "fixture-speakers", embedding: [1, 0],
        enrolledAt: Date(timeIntervalSince1970: 1), sampleDuration: 12)
    let voiceB = LocalVoiceProfile(modelID: "fixture-speakers", embedding: [0, 1],
        enrolledAt: Date(timeIntervalSince1970: 2), sampleDuration: 12)
    let standardDiarization = AcousticDiarization(
        speakers: [
            AcousticSpeaker(id: "host", embedding: [1, 0]),
            AcousticSpeaker(id: "guest", embedding: [0, 1])
        ],
        spans: [
            AcousticSpeakerSpan(start: 0, end: 1, speakerID: "host"),
            AcousticSpeakerSpan(start: 1.2, end: 2.0, speakerID: "guest")
        ]
    )

    var sidecarURL: URL {
        library.paths.directory(for: recording.id).appending(path: ".owner-attribution.json")
    }

    static func make() async throws -> OwnerAttributionHarness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OwnerAttributionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            title: "Owner attribution", duration: 3, mode: .micOnly, audioVersion: 1)
        try library.add(recording)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: library.audioURL(for: recording), options: .atomic)

        let client = OwnerAttributionClient()
        let detailed = OwnerAttributionDetailedClient()
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "OwnerAttributionTests.\(UUID().uuidString)")!
        let configuration = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults,
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") })
        configuration.processingMode = .onDevice
        let profile = MeetingProfileStore(root: root.appending(path: "Profile", directoryHint: .isDirectory))
        try profile.updateProfile { profile in
            profile.displayName = "Seonwoo"
        }
        let store = MeetingIntelligenceStore(library: library)
        let edits = MeetingEditLog(root: root.appending(path: "Edits", directoryHint: .isDirectory))
        let backend = OwnerAttributionBackend()
        let service = MeetingAnalysisService(library: library, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: backend,
            client: client, detailedClient: detailed, chunker: OwnerAttributionChunker())
        return OwnerAttributionHarness(root: root, library: library, recording: recording,
            configuration: configuration, profile: profile, store: store, edits: edits,
            backend: backend, client: client, detailed: detailed, service: service)
    }

    func currentRevision() throws -> String {
        let current = try #require(try store.localDocumentWithData(for: recording))
        return current.descriptor.revision
    }

    func addRecording(title: String) throws -> Recording {
        let recording = Recording(id: UUID(), title: title, duration: 3, mode: .micOnly, audioVersion: 1)
        try library.add(recording)
        try FileManager.default.createDirectory(at: library.paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: library.audioURL(for: recording), options: .atomic)
        return recording
    }

    func document(
        recording: Recording? = nil,
        ownerSpeakerID: String,
        guestSpeakerID: String,
        modifiedAt: Int64 = 10,
        mutationID: UUID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
        hostText: String = "I will send notes tomorrow."
    ) -> MeetingIntelligenceDocument {
        let target = recording ?? self.recording
        let transcript = MeetingTranscript(recordingID: target.id, audioVersion: target.audioVersion,
            transcriptionModelID: "fixture/stt",
            speakers: [
                MeetingSpeaker(id: ownerSpeakerID, name: "Seonwoo", isOwner: true),
                MeetingSpeaker(id: guestSpeakerID, name: "Guest", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-host", start: 0, end: 1, speakerID: ownerSpeakerID,
                    text: hostText),
                TranscriptTurn(id: "turn-guest", start: 1.2, end: 2.0, speakerID: guestSpeakerID,
                    text: "Please review them tomorrow.")
            ])
        let insights = MeetingInsights(actions: [
            MeetingAction(id: "action-review", kind: .request, text: "Review the notes tomorrow.",
                actorSpeakerID: ownerSpeakerID, targetSpeakerID: guestSpeakerID, dueText: "tomorrow",
                evidenceTurnIDs: ["turn-host", "turn-guest"])
        ])
        return MeetingIntelligenceDocument(recordingID: target.id, audioVersion: target.audioVersion,
            modifiedAt: modifiedAt, mutationID: mutationID,
            projectName: "Project", transcript: transcript, insights: insights,
            actionStates: ["action-review": MeetingActionStatus.done.rawValue],
            analysisModelID: "fixture/analysis")
    }
}

@MainActor
private struct OwnerAttributionFeatureHarness {
    let root: URL
    let library: LibraryStore
    let recording: Recording
    let backend: OwnerAttributionBackend
    let context: MeetingFeatureContext
    let voiceB = LocalVoiceProfile(modelID: "fixture-speakers", embedding: [0, 1],
        enrolledAt: Date(timeIntervalSince1970: 2), sampleDuration: 12)

    static func make() async throws -> OwnerAttributionFeatureHarness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OwnerAttributionFeatureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(id: UUID(), title: "Feature owner", duration: 3, mode: .micOnly, audioVersion: 1)
        try library.add(recording)
        try FileManager.default.createDirectory(at: paths.directory(for: recording.id), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: library.audioURL(for: recording), options: .atomic)
        let client = OwnerAttributionClient()
        let keyStore = InMemoryAPIKeyStore()
        let defaults = UserDefaults(suiteName: "OwnerAttributionFeatureTests.\(UUID().uuidString)")!
        let configuration = AIConfiguration(client: client, keyStore: keyStore, defaults: defaults,
            localStatusProvider: { _ in LocalAIStatus(isAvailable: true, message: "ready") })
        let chunker = OwnerAttributionChunker()
        let environment = AIEnvironment(client: client, keyStore: keyStore, chunker: chunker, defaults: defaults)
        let notes = MeetingNotesService(configuration: configuration, client: client, chunker: chunker, library: library)
        let backend = OwnerAttributionBackend()
        let context = MeetingFeatureContext(library: library, configuration: configuration,
            environment: environment, notes: notes, backend: backend)
        return OwnerAttributionFeatureHarness(root: root, library: library, recording: recording,
            backend: backend, context: context)
    }

    func document(includeOwner: Bool) -> MeetingIntelligenceDocument {
        var speakers = [MeetingSpeaker(id: "speaker-guest", name: "Guest", isOwner: false)]
        if includeOwner {
            speakers.insert(MeetingSpeaker(id: "owner", name: "Seonwoo", isOwner: true), at: 0)
        }
        let transcript = MeetingTranscript(recordingID: recording.id, audioVersion: recording.audioVersion,
            transcriptionModelID: "fixture/stt", speakers: speakers,
            turns: [TranscriptTurn(id: "turn-guest", start: 0, end: 1, speakerID: "speaker-guest", text: "Please review.")])
        return MeetingIntelligenceDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
            modifiedAt: 10, mutationID: UUID(), projectName: "", transcript: transcript,
            insights: nil, analysisModelID: "fixture/analysis")
    }

    func repairableDocument() -> MeetingIntelligenceDocument {
        let transcript = MeetingTranscript(recordingID: recording.id, audioVersion: recording.audioVersion,
            transcriptionModelID: "fixture/stt",
            speakers: [
                MeetingSpeaker(id: "owner", name: "Seonwoo", isOwner: true),
                MeetingSpeaker(id: "speaker-guest", name: "Guest", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-host", start: 0, end: 1, speakerID: "owner", text: "I will send notes."),
                TranscriptTurn(id: "turn-guest", start: 1.2, end: 2.0, speakerID: "speaker-guest", text: "Please review.")
            ])
        return MeetingIntelligenceDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
            modifiedAt: 10, mutationID: UUID(), projectName: "", transcript: transcript,
            insights: nil, analysisModelID: "fixture/analysis")
    }
}

private actor DiarizeGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markStartedAndWait() async {
        if started { return }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class OwnerAttributionBackend: SpeakerAnalysisServing, @unchecked Sendable {
    let embeddingModelID = "fixture-speakers"
    var diarization = AcousticDiarization(
        speakers: [
            AcousticSpeaker(id: "host", embedding: [1, 0]),
            AcousticSpeaker(id: "guest", embedding: [0, 1])
        ],
        spans: [
            AcousticSpeakerSpan(start: 0, end: 1, speakerID: "host"),
            AcousticSpeakerSpan(start: 1.2, end: 2.0, speakerID: "guest")
        ]
    )
    var delay: Duration = .zero
    var gate: DiarizeGate?
    var failedAudioPathFragments: Set<String> = []
    nonisolated(unsafe) private var recordedDiarizeCallCount = 0
    var diarizeCallCount: Int { recordedDiarizeCallCount }

    func prepare() async throws {}

    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let gate { await gate.markStartedAndWait() }
        try Task.checkCancellation()
        recordedDiarizeCallCount += 1
        if failedAudioPathFragments.contains(where: { audioURL.path.contains($0) }) {
            throw AIError(message: "refused local diarization")
        }
        return diarization
    }

    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] { [1, 0] }
}

private actor OwnerAttributionClient: OpenRouterServing {
    private(set) var completionCalls = 0
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        AITextResponse(text: "")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completionCalls += 1
        return AITextResponse(text: #"{"schemaVersion":1,"actions":[],"questions":[],"decisions":[]}"#)
    }
}

private actor OwnerAttributionDetailedClient: DetailedTranscriptionServing {
    private(set) var calls = 0
    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String,
                            language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1
        return DetailedTranscriptionResult(text: "", words: [], segments: [])
    }
}

private struct OwnerAttributionChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("audio".utf8), format: "wav", startTime: 0, duration: 1)
    }
}
