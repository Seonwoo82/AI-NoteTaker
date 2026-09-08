import Foundation
#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Owner voice manager")
struct OwnerVoiceManagerTests {
    @Test("production policy defaults use conservative enrollment and listening windows")
    func productionPolicyDefaultsAreConservative() {
        let policy = OwnerVoicePolicy()

        #expect(policy.minimumEnrollmentDuration == 10)
        #expect(policy.maximumEnrollmentDuration == 30)
        #expect(policy.listeningWindowDuration == 3)
    }

    @Test("preparing models updates presentation without creating a voice profile")
    func preparingModelsUpdatesPresentation() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService()
        let manager = OwnerVoiceManager(profile: store, backend: backend)

        await manager.prepareModels()

        #expect(manager.presentation.modelsReady)
        #expect(manager.presentation.isPreparing == false)
        #expect(manager.presentation.error == nil)
        #expect(store.localVoice == nil)
        #expect(backend.prepareCallCount == 1)
    }

    @Test("enrollment saves a validated local embedding without persisting raw audio")
    func enrollmentSavesValidatedLocalEmbedding() async throws {
        let root = temporaryDirectory()
        let store = MeetingProfileStore(root: root)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0, 0])
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 1.0, minimumSpeechRMS: 0.01)
        )
        await manager.prepareModels()

        await manager.beginEnrollment()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 16_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        await manager.finishEnrollment()

        let voice = try #require(store.localVoice)
        #expect(voice.modelID == "fake-speaker-v1")
        #expect(voice.embedding == [1, 0, 0])
        #expect(voice.sampleDuration == 1.0)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "owner-enrollment.wav").path))
        #expect(manager.presentation.isEnrolling == false)
        #expect(manager.presentation.error == nil)
    }

    @Test("enrollment rejects silence and invalid embeddings")
    func enrollmentRejectsSilenceAndInvalidEmbeddings() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService(embeddingResult: [])
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 0.5, minimumSpeechRMS: 0.05)
        )
        await manager.prepareModels()

        await manager.beginEnrollment()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0), sampleRate: 16_000, startTime: 0))
        await manager.finishEnrollment()

        #expect(store.localVoice == nil)
        #expect(manager.presentation.error != nil)
    }

    @Test("listening classifies owner other uncertain and model mismatch conservatively")
    func listeningClassifiesConservatively() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fake-speaker-v1",
            embedding: [1, 0, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 3
        ), allowedDimensions: 3...3)
        let backend = FakeSpeakerAnalysisService()
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(
                ownerThreshold: 0.85,
                otherThreshold: 0.45,
                listeningWindowDuration: 0.5,
                minimumSpeechRMS: 0.01
            )
        )

        await manager.prepareModels()
        manager.startListening()
        backend.embeddingResult = [0.95, 0.05, 0]
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        await waitForState(manager, .owner)

        backend.embeddingResult = [0, 1, 0]
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0.5))
        await waitForState(manager, .other)

        backend.embeddingResult = [0.7, 0.7, 0]
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 1.0))
        await waitForState(manager, .uncertain)

        backend.embeddingModelID = "new-model"
        backend.embeddingResult = [1, 0, 0]
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 1.5))
        await waitForState(manager, .uncertain)
    }

    @Test("silence gap and stale timeout keep an owner badge from sticking")
    func silenceGapAndStaleTimeoutClearOwnerBadge() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fake-speaker-v1",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 2
        ), allowedDimensions: 2...2)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(
                ownerThreshold: 0.8,
                listeningWindowDuration: 0.25,
                staleAfter: 0.05,
                maxContinuousAudioGap: 0.4,
                minimumSpeechRMS: 0.01
            )
        )

        await manager.prepareModels()
        manager.startListening()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 4_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        await waitForState(manager, .owner)

        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 4_000, amplitude: 0), sampleRate: 16_000, startTime: 0.25))
        await waitForState(manager, .silence)

        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 4_000, amplitude: 0.2), sampleRate: 16_000, startTime: 2.0))
        #expect(manager.state == .silence)
        await waitForState(manager, .owner)

        try await Task.sleep(for: .milliseconds(80))
        #expect(manager.state == .silence)
    }

    @Test("late embedding results cannot publish after listening stops or profile changes")
    func lateEmbeddingResultsCannotPublishAfterLifecycleChanges() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fake-speaker-v1",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 10
        ), allowedDimensions: 2...2)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        backend.holdEmbedding = true
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(listeningWindowDuration: 0.5, minimumSpeechRMS: 0.01)
        )

        await manager.prepareModels()
        manager.startListening()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        await backend.waitForEmbeddingCallCount(1)
        manager.stopListening()
        backend.releaseEmbedding()
        try await Task.sleep(for: .milliseconds(20))

        #expect(manager.state == .silence)

        await manager.prepareModels()
        manager.startListening()
        backend.holdEmbedding = true
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0.5))
        await backend.waitForEmbeddingCallCount(2)
        try manager.deleteEnrollment()
        backend.releaseEmbedding()
        try await Task.sleep(for: .milliseconds(20))

        #expect(manager.state == .unavailable)
    }

    @Test("backward audio time and sample rate changes reset the listening window")
    func discontinuousAudioResetsListeningWindow() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fake-speaker-v1",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 10
        ), allowedDimensions: 2...2)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(listeningWindowDuration: 1.0, minimumSpeechRMS: 0.01)
        )

        await manager.prepareModels()
        manager.startListening()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 1.0))
        await waitForState(manager, .listening)
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0.2))
        await waitForState(manager, .listening)
        #expect(backend.embeddingCallCount == 0)

        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 48_000, startTime: 0.7))
        try await Task.sleep(for: .milliseconds(20))
        #expect(backend.embeddingCallCount == 0)
    }

    @Test("queued chunks are coalesced into the latest listening window")
    func queuedChunksAreCoalescedIntoLatestWindow() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(
            modelID: "fake-speaker-v1",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 10
        ), allowedDimensions: 2...2)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        backend.holdEmbedding = true
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(listeningWindowDuration: 0.5, minimumSpeechRMS: 0.01)
        )

        await manager.prepareModels()
        manager.startListening()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.1),
            sampleRate: 16_000, startTime: 0))
        await backend.waitForEmbeddingCallCount(1)
        for index in 1..<6 {
            manager.audioHandler(LiveAudioSamples(
                samples: speechSamples(count: 8_000, amplitude: Float(index + 1) / 10),
                sampleRate: 16_000,
                startTime: Double(index) * 0.5
            ))
        }
        backend.releaseEmbedding()
        await backend.waitForEmbeddingCallCount(2)
        await waitForState(manager, .owner)

        #expect(backend.embeddingCallCount == 2)
        #expect(backend.lastEmbeddingInput?.samples.first == 0.6)
    }

    @Test("policy classification is reusable for batch owner attribution")
    func policyClassificationIsReusable() {
        let policy = OwnerVoicePolicy(ownerThreshold: 0.8, otherThreshold: 0.3)
        let profile = LocalVoiceProfile(
            modelID: "classic-256d",
            embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1),
            sampleDuration: 10
        )

        #expect(policy.classify(embedding: [0.9, 0.1], profile: profile, modelID: "classic-256d") == .owner)
        #expect(policy.classify(embedding: [0, 1], profile: profile, modelID: "classic-256d") == .other)
        #expect(policy.classify(embedding: [0.5, 0.5], profile: profile, modelID: "classic-256d") == .uncertain)
        #expect(policy.classify(embedding: [1, 0], profile: profile, modelID: "offline-v2") == .uncertain)
    }

    @Test("availability callback follows local voice profile creation and removal")
    func availabilityCallbackFollowsLocalVoiceProfileChanges() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 0.5, minimumSpeechRMS: 0.01)
        )
        var availability: [Bool] = []
        manager.onAvailabilityChanged = { availability.append($0) }
        await manager.prepareModels()

        await manager.beginEnrollment()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        await manager.finishEnrollment()
        try manager.deleteEnrollment()

        #expect(availability == [true, false])
    }

    @Test("canceling enrollment invalidates a pending embedding save")
    func cancelingEnrollmentInvalidatesPendingEmbeddingSave() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        backend.holdEmbedding = true
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 0.5, minimumSpeechRMS: 0.01)
        )
        await manager.prepareModels()

        await manager.beginEnrollment()
        manager.audioHandler(LiveAudioSamples(samples: speechSamples(count: 8_000, amplitude: 0.2), sampleRate: 16_000, startTime: 0))
        let finishTask = Task { @MainActor in await manager.finishEnrollment() }
        await backend.waitForEmbeddingCallCount(1)

        manager.cancelEnrollment()
        backend.releaseEmbedding()
        await finishTask.value

        #expect(store.localVoice == nil)
        #expect(manager.presentation.isProcessing == false)
        #expect(manager.state == .unavailable)
    }

    @Test("capture errors clear enrollment state and surface the message")
    func captureErrorsClearEnrollmentState() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService()
        let manager = OwnerVoiceManager(
            profile: store,
            backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 0.5, minimumSpeechRMS: 0.01)
        )
        await manager.prepareModels()
        await manager.beginEnrollment()

        manager.reportCaptureError(AIError(message: "microphone disconnected"))

        #expect(manager.presentation.isEnrolling == false)
        #expect(manager.presentation.isProcessing == false)
        #expect(manager.presentation.error == "microphone disconnected")
        #expect(manager.state == .unavailable)
    }

    @Test("speaker backend factory uses the local engine without implicitly preparing models")
    func linkedSpeakerBackendRequiresPreparation() async {
        let backend = SpeakerBackendFactory.make()
        #expect(backend is LocalSpeakerBackend)
        await #expect(throws: AIError.self) {
            _ = try await backend.embedding(samples: speechSamples(count: 16_000, amplitude: 0.2), sampleRate: 16_000)
        }
    }

    @Test("PCM window builder emits bounded ten second windows and preserves remainder")
    func pcmWindowBuilderEmitsBoundedWindows() {
        var builder = LocalSpeakerPCMWindowBuilder(windowDuration: 10, maximumBufferedDuration: 12)

        let emitted = builder.append(samples: Array(repeating: 0.1, count: 41), sampleRate: 2, startTime: 0)
        let tail = builder.finish()

        #expect(emitted.map(\.samples.count) == [20, 20])
        #expect(emitted.map(\.startTime) == [0, 10])
        #expect(tail?.samples.count == 1)
        #expect(tail?.startTime == 20)
    }

    @Test("PCM window builder tracks buffered start separately from expected input time")
    func pcmWindowBuilderTracksChunkedInputContinuously() {
        var builder = LocalSpeakerPCMWindowBuilder(windowDuration: 10, maximumBufferedDuration: 12)
        var emitted: [LocalSpeakerPCMWindow] = []

        for index in 0..<82 {
            emitted.append(contentsOf: builder.append(
                samples: [0.1],
                sampleRate: 2,
                startTime: Double(index) * 0.5
            ))
        }
        let tail = builder.finish()

        #expect(emitted.map(\.samples.count) == [20, 20, 20, 20])
        #expect(emitted.map(\.startTime) == [0, 10, 20, 30])
        #expect(tail?.samples.count == 2)
        #expect(tail?.startTime == 40)
    }

    @Test("PCM window builder rejects invalid input instead of emitting unusable windows")
    func pcmWindowBuilderRejectsInvalidInput() {
        var builder = LocalSpeakerPCMWindowBuilder(windowDuration: .nan, maximumBufferedDuration: -1)

        #expect(builder.append(samples: [0.1], sampleRate: 16_000, startTime: -1).isEmpty)
        #expect(builder.append(samples: [.nan], sampleRate: 16_000, startTime: 0).isEmpty)
        #expect(builder.append(samples: [0.1], sampleRate: .infinity, startTime: 0).isEmpty)
        #expect(builder.finish() == nil)
    }


    @Test("zero embeddings never produce a speaker identity")
    func zeroEmbeddingIsUncertain() {
        let policy = OwnerVoicePolicy()
        let voice = LocalVoiceProfile(modelID: "m", embedding: [1, 0], enrolledAt: .now, sampleDuration: 12)
        #expect(policy.classify(embedding: [0, 0], profile: voice, modelID: "m") == .uncertain)
        #expect(!policy.isValidEmbedding([0, 0]))
    }

    @Test("unprepared listening does not call the embedding backend")
    func unpreparedListeningRequiresModels() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        try store.saveVoiceProfile(LocalVoiceProfile(modelID: "fake-speaker-v1", embedding: [1, 0],
            enrolledAt: .now, sampleDuration: 12), allowedDimensions: 2...2)
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        let manager = OwnerVoiceManager(profile: store, backend: backend)
        manager.startListening()
        manager.audioHandler(LiveAudioSamples(samples: [Float](repeating: 0.2, count: 48_000),
            sampleRate: 16_000, startTime: 0))
        await Task.yield()
        #expect(manager.state == .unavailable)
        #expect(backend.embeddingCallCount == 0)
        #expect(backend.prepareCallCount == 0)
    }

    @Test("broken enrollment reports capture failure and never saves a mixed sample")
    func brokenEnrollmentStopsItsCaptureOwner() async throws {
        let store = MeetingProfileStore(root: temporaryDirectory())
        let backend = FakeSpeakerAnalysisService(embeddingResult: [1, 0])
        let manager = OwnerVoiceManager(profile: store, backend: backend,
            policy: OwnerVoicePolicy(minimumEnrollmentDuration: 0.1))
        var failures = 0
        manager.onCaptureFailure = { _ in failures += 1 }
        await manager.prepareModels()
        await manager.beginEnrollment()
        manager.audioHandler(LiveAudioSamples(samples: [Float](repeating: 0.2, count: 8_000),
            sampleRate: 16_000, startTime: 0))
        manager.audioHandler(LiveAudioSamples(samples: [Float](repeating: 0.2, count: 8_000),
            sampleRate: 48_000, startTime: 0.5))
        await manager.finishEnrollment()
        #expect(failures == 1)
        #expect(!manager.presentation.isEnrolling)
        #expect(store.localVoice == nil)
        #expect(backend.embeddingCallCount == 0)
    }

}

private final class FakeSpeakerAnalysisService: SpeakerAnalysisServing, @unchecked Sendable {
    private let lock = NSLock()
    private var modelID: String
    private var result: [Float]
    private var holds = false
    private var recordedPrepareCallCount = 0
    private var recordedEmbeddingCallCount = 0
    private var heldEmbeddings: [CheckedContinuation<Void, Never>] = []
    private var recordedLastEmbeddingInput: (samples: [Float], sampleRate: Double)?

    var embeddingModelID: String {
        get { lock.withLock { modelID } }
        set { lock.withLock { modelID = newValue } }
    }
    var embeddingResult: [Float] {
        get { lock.withLock { result } }
        set { lock.withLock { result = newValue } }
    }
    var holdEmbedding: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
    var prepareCallCount: Int { lock.withLock { recordedPrepareCallCount } }
    var embeddingCallCount: Int { lock.withLock { recordedEmbeddingCallCount } }
    var lastEmbeddingInput: (samples: [Float], sampleRate: Double)? { lock.withLock { recordedLastEmbeddingInput } }

    init(embeddingModelID: String = "fake-speaker-v1", embeddingResult: [Float] = [1, 0, 0]) {
        modelID = embeddingModelID
        result = embeddingResult
    }

    func prepare() async throws { lock.withLock { recordedPrepareCallCount += 1 } }

    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        AcousticDiarization(speakers: [], spans: [])
    }

    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                recordedEmbeddingCallCount += 1
                recordedLastEmbeddingInput = (samples, sampleRate)
                if holds { heldEmbeddings.append(continuation); return false }
                return true
            }
            if shouldResume { continuation.resume() }
        }
        return embeddingResult
    }

    func waitForEmbeddingCallCount(_ expected: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let ready = lock.withLock {
                recordedEmbeddingCallCount >= expected && (!holds || !heldEmbeddings.isEmpty)
            }
            if ready { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for embedding call")
    }

    func releaseEmbedding() {
        let continuations = lock.withLock {
            holds = false
            let values = heldEmbeddings
            heldEmbeddings.removeAll()
            return values
        }
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor
private func waitForState(_ manager: OwnerVoiceManager, _ state: OwnerSpeechState) async {
    for _ in 0..<100 {
        if manager.state == state {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for owner speech state \(state); current state is \(manager.state)")
}

private func speechSamples(count: Int, amplitude: Float) -> [Float] {
    Array(repeating: amplitude, count: count)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "OwnerVoiceManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
