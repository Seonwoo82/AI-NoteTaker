import Foundation
import Observation
#if canImport(AudioPipeline)
import AudioPipeline
#endif

/// App-lifetime owner for analysis, local voice capture, and synced meeting data.
@MainActor
@Observable
final class MeetingFeatureContext {
    let profile: MeetingProfileStore
    let voice: OwnerVoiceManager
    let analysis: MeetingAnalysisService
    let store: MeetingIntelligenceStore
    let edits: MeetingEditLog
    var errorMessage: String?
    private(set) var evidenceRequest: MeetingEvidenceRequest?
    private(set) var enrollmentIsBusy = false
    @ObservationIgnored var recordingIsBusy: () -> Bool = { false }
    @ObservationIgnored var stopPlayback: () async -> Void = {}
    @ObservationIgnored var attachLiveAudio: (LiveAudioSampleHandler?) -> Void = { _ in }
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let configuration: AIConfiguration
    @ObservationIgnored private let notes: MeetingNotesService
    @ObservationIgnored private let enrollmentCapture: VoiceEnrollmentCapture
    @ObservationIgnored private var enrollmentGeneration = UUID()
    @ObservationIgnored private var pendingNotes: Set<UUID> = []
    @ObservationIgnored private var isTerminating = false

    init(library: LibraryStore, configuration: AIConfiguration, environment: AIEnvironment,
         notes: MeetingNotesService, backend: (any SpeakerAnalysisServing)? = nil,
         enrollmentCapture: VoiceEnrollmentCapture? = nil) {
        self.library = library
        self.configuration = configuration
        self.notes = notes
        self.enrollmentCapture = enrollmentCapture ?? VoiceEnrollmentCapture()
        let backend = backend ?? SpeakerBackendFactory.make()
        let root = library.paths.libraryRoot
        let profile = MeetingProfileStore(root: root)
        let store = MeetingIntelligenceStore(library: library)
        let edits = MeetingEditLog(root: root)
        self.profile = profile
        self.store = store
        self.edits = edits
        self.voice = OwnerVoiceManager(profile: profile, backend: backend)
        self.analysis = MeetingAnalysisService(library: library, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: backend,
            client: environment.client,
            detailedClient: (environment.client as? any DetailedTranscriptionServing) ?? UnavailableTimedTranscription(),
            chunker: environment.chunker)
        analysis.onFinished = { [weak self] recording, _ in
            guard let self, self.pendingNotes.remove(recording.id) != nil,
                  !self.analysis.wasCancelled(for: recording.id), !self.isTerminating,
                  let current = self.library.recording(id: recording.id),
                  current.deletedAt == nil, current.audioVersion == recording.audioVersion else { return }
            self.notes.recordingDidFinish(current)
        }
        if environment.client is any DetailedTranscriptionServing {
            notes.speakerTranscriptProvider = { [weak self] recording, modelID in
                guard let self else { throw CancellationError() }
                return try await self.analysis.prepareNumberedTranscript(recording, transcriptionModelID: modelID)
            }
        }
        voice.onCaptureFailure = { [weak self] error in
            guard let self, self.enrollmentIsBusy else { return }
            self.enrollmentGeneration = UUID()
            self.enrollmentCapture.stop()
            self.enrollmentIsBusy = false
            self.errorMessage = error.localizedDescription
        }
        voice.onAvailabilityChanged = { [weak self] _ in self?.refreshVoiceObservation() }
        self.enrollmentCapture.onInterrupted = { [weak self] in
            guard let self else { return }
            self.cancelEnrollment()
            let error = AIError(message: "마이크 연결이 변경되어 목소리 등록을 중단했어요. 다시 녹음해 주세요.")
            self.voice.reportCaptureError(error)
            self.errorMessage = error.localizedDescription
        }
    }

    func configureSync(_ sync: SyncCoordinator, automatic: Bool) {
        sync.configureMeetingDataSync(profile: profile, store: store, edits: edits)
        guard automatic else { return }
        profile.onProfileChanged = { [weak sync] in sync?.requestAutomaticSync() }
        store.onDocumentSaved = { [weak sync] _ in sync?.requestAutomaticSync() }
        edits.onChange = { [weak sync] in sync?.requestAutomaticSync() }
    }

    func load(_ recording: Recording) async { _ = await store.load(recording) }

    func restoreLocalVoiceModels() async {
        guard !isTerminating else { return }
        await voice.prepareCachedModelsIfAvailable()
        refreshVoiceObservation()
    }

    func loadLibrary() async {
        for recording in library.recordings where recording.deletedAt == nil {
            guard !Task.isCancelled else { return }
            await load(recording)
            await Task.yield()
        }
    }

    func resolved(_ recording: Recording) -> MeetingResolvedDocument? {
        guard let document = store.document(for: recording.id) else { return nil }
        return try? document.resolved(edits: edits.edits(for: recording.id, audioVersion: recording.audioVersion))
    }

    var briefingSources: [MeetingBriefingSource] {
        library.recordings.compactMap { recording in
            guard recording.deletedAt == nil, let document = resolved(recording) else { return nil }
            return MeetingBriefingSource(recordingID: recording.id, title: recording.title,
                createdAt: recording.createdAt, resolvedDocument: document)
        }
    }

    func requestEvidence(recordingID: UUID, turnIDs: [String]) {
        evidenceRequest = MeetingEvidenceRequest(id: UUID(), recordingID: recordingID, turnIDs: turnIDs)
    }

    func clearEvidenceRequest(_ id: UUID) {
        if evidenceRequest?.id == id { evidenceRequest = nil }
    }

    func edit(_ recording: Recording, kind: MeetingEditKind, targetID: String, value: String) throws {
        guard let current = library.recording(id: recording.id), current.deletedAt == nil,
              current.audioVersion == recording.audioVersion,
              let document = store.document(for: recording.id) else { throw MeetingStorageError.audioVersionMismatch }
        // Reject invalid targets before durable publication. Missing older targets
        // may still remain in the log after re-transcription, without changing raw text.
        switch kind {
        case .speakerName, .speakerOwner:
            guard document.transcript.speakers.contains(where: { $0.id == targetID }) else { throw MeetingStorageError.invalidEditPage }
        case .turnSpeaker:
            guard document.transcript.turns.contains(where: { $0.id == targetID }),
                  value.isEmpty || document.transcript.speakers.contains(where: { $0.id == value }) else { throw MeetingStorageError.invalidEditPage }
        case .actionStatus:
            guard document.insights?.actions.contains(where: { $0.id == targetID }) == true else { throw MeetingStorageError.invalidEditPage }
        case .projectName: break
        }
        try edits.append(recordingID: current.id, audioVersion: current.audioVersion,
            kind: kind, targetID: targetID, value: value)
    }

    func recordingDidFinish(_ recording: Recording) {
        guard !isTerminating else { return }
        if configuration.autoGenerate && configuration.isConfigured && profile.profile.automaticallyAnalyze {
            pendingNotes.insert(recording.id)
            analysis.analyze(recording)
        } else { notes.recordingDidFinish(recording) }
    }

    func recordingUnavailable(_ id: UUID) {
        pendingNotes.remove(id)
        analysis.cancel(id)
    }

    func credentialsDidChange() {
        pendingNotes.removeAll()
        analysis.credentialsDidChange()
    }

    func prepareVoiceModels() async {
        guard !recordingIsBusy(), !enrollmentIsBusy else { return }
        await voice.prepareModels()
        refreshVoiceObservation()
    }

    func refreshVoiceObservation(preserveEnrollmentFeedback: Bool = false) {
        guard !isTerminating, !enrollmentIsBusy else { return }
        voice.stopListening()
        if profile.localVoice != nil {
            attachLiveAudio(voice.audioHandler)
            if preserveEnrollmentFeedback { voice.resumeListeningAfterEnrollment() }
            else { voice.startListening() }
        } else { attachLiveAudio(nil) }
    }

    func beginEnrollment() async {
        guard !Task.isCancelled, !isTerminating, !recordingIsBusy(), !enrollmentIsBusy else { return }
        enrollmentIsBusy = true
        errorMessage = nil
        let generation = UUID()
        enrollmentGeneration = generation
        voice.stopListening()
        attachLiveAudio(nil)
        await stopPlayback()
        guard enrollmentGeneration == generation else { return }
        guard !Task.isCancelled, !recordingIsBusy() else { cancelEnrollment(); return }
        await voice.beginEnrollment()
        guard voice.presentation.isEnrolling else {
            enrollmentIsBusy = false
            refreshVoiceObservation()
            return
        }
        do {
            try await enrollmentCapture.start(handler: voice.audioHandler)
            guard enrollmentGeneration == generation else { return }
        } catch {
            guard enrollmentGeneration == generation else { return }
            cancelEnrollment()
            if !(error is CancellationError) {
                voice.reportCaptureError(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    func finishEnrollment() async {
        guard !Task.isCancelled, enrollmentIsBusy, voice.presentation.isEnrolling else { return }
        let generation = enrollmentGeneration
        enrollmentCapture.stop()
        await voice.finishEnrollment()
        guard generation == enrollmentGeneration else { return }
        enrollmentIsBusy = false
        refreshVoiceObservation(preserveEnrollmentFeedback: true)
    }

    func cancelEnrollment() {
        // Do not disrupt a normal recorder/player when a profile view disappears.
        guard enrollmentIsBusy else { return }
        enrollmentGeneration = UUID()
        enrollmentCapture.stop()
        voice.cancelEnrollment()
        enrollmentIsBusy = false
        refreshVoiceObservation()
    }

    func deleteEnrollment() {
        cancelEnrollment()
        do { try voice.deleteEnrollment(); refreshVoiceObservation() }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareForTermination() {
        isTerminating = true
        pendingNotes.removeAll()
        analysis.cancelAll()
        cancelEnrollment()
        voice.stopListening()
        attachLiveAudio(nil)
    }
}

nonisolated private struct UnavailableTimedTranscription: DetailedTranscriptionServing {
    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String,
                           language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        throw AIError(message: "현재 전사 서비스가 발화 시간 정보를 지원하지 않아요.")
    }
}

nonisolated struct MeetingEvidenceRequest: Equatable, Sendable {
    let id: UUID
    let recordingID: UUID
    let turnIDs: [String]
}
