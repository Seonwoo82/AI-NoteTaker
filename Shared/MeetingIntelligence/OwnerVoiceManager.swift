import AVFoundation
#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Foundation
import Observation

nonisolated struct AcousticSpeaker: Equatable, Sendable {
    let id: String
    let embedding: [Float]
}

nonisolated struct AcousticSpeakerSpan: Equatable, Sendable {
    let start: Double
    let end: Double
    let speakerID: String?
    let isOverlap: Bool

    init(start: Double, end: Double, speakerID: String?, isOverlap: Bool = false) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.isOverlap = isOverlap
    }
}

nonisolated struct AcousticDiarization: Equatable, Sendable {
    let speakers: [AcousticSpeaker]
    let spans: [AcousticSpeakerSpan]
}

protocol SpeakerAnalysisServing: Sendable {
    nonisolated var embeddingModelID: String { get }

    func prepare() async throws
    func prepareCachedIfAvailable() async throws -> Bool
    func diarize(audioURL: URL) async throws -> AcousticDiarization
    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float]
}

extension SpeakerAnalysisServing {
    func prepareCachedIfAvailable() async throws -> Bool { false }
}

nonisolated enum OwnerSpeechState: Equatable, Sendable {
    case unavailable
    case listening
    case silence
    case owner
    case other
    case uncertain
}

nonisolated struct OwnerVoicePolicy: Equatable, Sendable {
    var ownerThreshold: Float
    var otherThreshold: Float
    var minimumEnrollmentDuration: Double
    var maximumEnrollmentDuration: Double
    var listeningWindowDuration: Double
    var staleAfter: Double
    var maxContinuousAudioGap: Double
    var minimumSpeechRMS: Float

    init(
        ownerThreshold: Float = 0.82,
        otherThreshold: Float = 0.55,
        minimumEnrollmentDuration: Double = 10.0,
        maximumEnrollmentDuration: Double = 30.0,
        listeningWindowDuration: Double = 3.0,
        staleAfter: Double = 1.2,
        maxContinuousAudioGap: Double = 0.8,
        minimumSpeechRMS: Float = 0.01
    ) {
        self.ownerThreshold = ownerThreshold
        self.otherThreshold = otherThreshold
        self.minimumEnrollmentDuration = minimumEnrollmentDuration
        self.maximumEnrollmentDuration = maximumEnrollmentDuration
        self.listeningWindowDuration = listeningWindowDuration
        self.staleAfter = staleAfter
        self.maxContinuousAudioGap = maxContinuousAudioGap
        self.minimumSpeechRMS = minimumSpeechRMS
    }

    func classify(embedding: [Float], profile: LocalVoiceProfile, modelID: String) -> OwnerSpeechState {
        guard profile.modelID == modelID,
              profile.embedding.count == embedding.count,
              isValidEmbedding(embedding),
              isValidEmbedding(profile.embedding) else {
            return .uncertain
        }

        let score = cosine(embedding, profile.embedding)
        if score >= ownerThreshold {
            return .owner
        }
        if score < otherThreshold {
            return .other
        }
        return .uncertain
    }

    func isValidEmbedding(_ embedding: [Float]) -> Bool {
        !embedding.isEmpty && embedding.count <= 4_096 && embedding.allSatisfy(\.isFinite)
            && embedding.contains { abs($0) > 1e-10 }
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}

@MainActor
@Observable
final class OwnerVoiceManager {
    private struct BufferedSamples {
        var samples: [Float] = []
        var sampleRate: Double?
        var duration: Double = 0

        mutating func append(_ chunk: LiveAudioSamples, maximumDuration: Double) {
            sampleRate = chunk.sampleRate
            samples.append(contentsOf: chunk.samples)
            duration += chunk.duration

            guard let sampleRate, maximumDuration.isFinite, maximumDuration > 0 else { return }
            let maximumFrames = max(1, Int(sampleRate * maximumDuration))
            if samples.count > maximumFrames {
                samples.removeFirst(samples.count - maximumFrames)
                duration = min(duration, maximumDuration)
            }
        }

        mutating func removeAll(keepingCapacity: Bool = true) {
            samples.removeAll(keepingCapacity: keepingCapacity)
            sampleRate = nil
            duration = 0
        }
    }

    private enum Mode {
        case idle
        case enrolling
        case listening
    }

    private let profile: MeetingProfileStore
    private let backend: any SpeakerAnalysisServing
    private let policy: OwnerVoicePolicy
    private nonisolated let inputQueue: BoundedLiveAudioInput
    private var mode: Mode = .idle
    private var enrollment = BufferedSamples()
    private var listeningWindow = BufferedSamples()
    private var lastAudioEnd: Double?
    private var enrollmentAudioEnd: Double?
    private var lastChunkToken = UUID()
    private var lifecycleID = UUID()
    private var listeningAnalysisID = UUID()
    private var modelsReady = false

    private(set) var presentation = VoiceProfilePresentation(status: String(localized: "Voice model is not prepared."))
    private(set) var state: OwnerSpeechState = .unavailable
    var onCaptureFailure: ((any Error) -> Void)?
    var onAvailabilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    init(
        profile: MeetingProfileStore,
        backend: any SpeakerAnalysisServing,
        policy: OwnerVoicePolicy = OwnerVoicePolicy()
    ) {
        self.profile = profile
        self.backend = backend
        self.policy = policy
        self.inputQueue = BoundedLiveAudioInput(maxChunks: 8)
    }

    nonisolated var audioHandler: LiveAudioSampleHandler {
        { [weak self] samples in
            guard let self else { return }
            self.inputQueue.enqueue(samples) {
                Task { @MainActor [weak self] in
                    await self?.drainAudioInput()
                }
            }
        }
    }

    func prepareModels() async {
        guard !presentation.isPreparing else { return }
        presentation.isPreparing = true
        presentation.error = nil
        presentation.status = String(localized: "Preparing voice model...")
        do {
            try await backend.prepare()
            modelsReady = true
            presentation.modelsReady = true
            presentation.isPreparing = false
            presentation.status = String(localized: "Voice model is ready.")
            state = profile.localVoice == nil ? .unavailable : .silence
        } catch {
            modelsReady = false
            presentation.modelsReady = false
            presentation.isPreparing = false
            presentation.error = Self.message(for: error)
            presentation.status = String(localized: "Voice model is unavailable.")
            state = .unavailable
        }
    }

    func prepareCachedModelsIfAvailable() async {
        guard !modelsReady, !presentation.isPreparing else { return }
        do {
            guard try await backend.prepareCachedIfAvailable() else { return }
            modelsReady = true
            presentation.modelsReady = true
            presentation.error = nil
            presentation.status = String(localized: "Voice model is ready.")
            state = profile.localVoice == nil ? .unavailable : .silence
        } catch {
            modelsReady = false
            presentation.modelsReady = false
            presentation.error = Self.message(for: error)
            presentation.status = String(localized: "Voice model is unavailable.")
            state = .unavailable
        }
    }

    func beginEnrollment() async {
        guard modelsReady else {
            presentation.error = String(localized: "Prepare the voice model before recording your voice.")
            return
        }
        guard mode == .idle else {
            presentation.error = String(localized: "Voice enrollment cannot start while listening or already recording.")
            return
        }
        inputQueue.reset()
        enrollment.removeAll()
        listeningWindow.removeAll()
        lastAudioEnd = nil
        enrollmentAudioEnd = nil
        lifecycleID = UUID()
        mode = .enrolling
        state = .listening
        presentation.isEnrolling = true
        presentation.isProcessing = false
        presentation.elapsed = 0
        presentation.error = nil
        presentation.status = String(localized: "Recording your voice...")
    }

    func finishEnrollment() async {
        guard mode == .enrolling else { return }
        await drainAudioInput()
        guard mode == .enrolling else { return }
        let finishedEnrollmentLifecycleID = UUID()
        lifecycleID = finishedEnrollmentLifecycleID
        mode = .idle
        presentation.isEnrolling = false
        presentation.isProcessing = true
        presentation.status = String(localized: "Creating local voice profile...")
        let samples = enrollment.samples
        let sampleRate = enrollment.sampleRate
        let duration = enrollment.duration

        guard let sampleRate,
              duration >= policy.minimumEnrollmentDuration,
              rms(samples) >= policy.minimumSpeechRMS else {
            presentation.error = String(localized: "Record a little more clear speech before saving your voice profile.")
            presentation.status = String(localized: "Voice profile was not saved.")
            presentation.isProcessing = false
            state = .unavailable
            enrollment.removeAll()
            return
        }

        do {
            let embedding = try await backend.embedding(samples: samples, sampleRate: sampleRate)
            guard lifecycleID == finishedEnrollmentLifecycleID else { return }
            try validateEmbedding(embedding)
            let voice = LocalVoiceProfile(
                modelID: backend.embeddingModelID,
                embedding: embedding,
                enrolledAt: Date(),
                sampleDuration: duration
            )
            try profile.saveVoiceProfile(voice, allowedDimensions: embedding.count...embedding.count)
            presentation.modelsReady = true
            presentation.status = String(localized: "Local voice profile is ready.")
            presentation.error = nil
            presentation.isProcessing = false
            state = .silence
            onAvailabilityChanged?(true)
        } catch {
            guard lifecycleID == finishedEnrollmentLifecycleID else { return }
            presentation.error = Self.message(for: error)
            presentation.status = String(localized: "Voice profile was not saved.")
            presentation.isProcessing = false
            state = .unavailable
        }
        enrollment.removeAll()
    }

    func cancelEnrollment() {
        guard mode == .enrolling || presentation.isProcessing else { return }
        mode = .idle
        lifecycleID = UUID()
        enrollment.removeAll()
        enrollmentAudioEnd = nil
        inputQueue.reset()
        presentation.isEnrolling = false
        presentation.isProcessing = false
        presentation.elapsed = 0
        presentation.status = profile.localVoice == nil
            ? String(localized: "No local voice profile is registered.")
            : String(localized: "Local voice profile is ready.")
        state = profile.localVoice == nil ? .unavailable : .silence
    }

    func reportCaptureError(_ error: any Error) {
        mode = .idle
        lifecycleID = UUID()
        listeningAnalysisID = UUID()
        inputQueue.reset()
        enrollment.removeAll()
        listeningWindow.removeAll()
        lastAudioEnd = nil
        enrollmentAudioEnd = nil
        lastChunkToken = UUID()
        presentation.isEnrolling = false
        presentation.isProcessing = false
        presentation.elapsed = 0
        presentation.error = Self.message(for: error)
        presentation.status = String(localized: "Voice capture failed.")
        state = profile.localVoice == nil ? .unavailable : .silence
        onCaptureFailure?(error)
    }

    func deleteEnrollment() throws {
        let hadVoice = profile.localVoice != nil
        try profile.deleteVoiceProfile()
        stopListening()
        lifecycleID = UUID()
        enrollment.removeAll()
        enrollmentAudioEnd = nil
        presentation.status = String(localized: "Local voice profile was deleted.")
        presentation.error = nil
        state = .unavailable
        if hadVoice {
            onAvailabilityChanged?(false)
        }
    }

    func resumeListeningAfterEnrollment() {
        let enrollmentError = presentation.error
        let enrollmentStatus = presentation.status
        startListening()
        if let enrollmentError {
            presentation.error = enrollmentError
            presentation.status = enrollmentStatus
        }
    }

    func startListening() {
        guard modelsReady else {
            state = .unavailable
            presentation.status = String(localized: "Voice model is not prepared.")
            presentation.error = String(localized: "Prepare the voice model before owner detection.")
            return
        }
        guard profile.localVoice != nil else {
            state = .unavailable
            presentation.status = String(localized: "Record your voice before owner detection.")
            return
        }
        guard mode == .idle else {
            presentation.error = String(localized: "Owner detection cannot start while recording your voice.")
            return
        }
        inputQueue.reset()
        listeningWindow.removeAll()
        lastAudioEnd = nil
        mode = .listening
        lifecycleID = UUID()
        listeningAnalysisID = UUID()
        state = .silence
        presentation.error = nil
        presentation.status = String(localized: "Listening for your voice...")
    }

    func stopListening() {
        guard mode == .listening else { return }
        mode = .idle
        lifecycleID = UUID()
        listeningAnalysisID = UUID()
        inputQueue.reset()
        listeningWindow.removeAll()
        lastAudioEnd = nil
        lastChunkToken = UUID()
        state = profile.localVoice == nil ? .unavailable : .silence
        presentation.status = profile.localVoice == nil
            ? String(localized: "No local voice profile is registered.")
            : String(localized: "Owner detection paused.")
    }

    private func drainAudioInput() async {
        let chunks = inputQueue.drain()
        switch mode {
        case .enrolling:
            for chunk in chunks where chunk.isUsable {
                ingestEnrollment(chunk)
            }
        case .listening:
            await ingestLatestListeningWindow(from: chunks.filter(\.isUsable))
        case .idle:
            break
        }

        if inputQueue.finishDrain() {
            Task { @MainActor [weak self] in
                await self?.drainAudioInput()
            }
        }
    }

    private func ingestEnrollment(_ chunk: LiveAudioSamples) {
        guard mode == .enrolling else { return }
        // Cumulative frame timestamps can differ from start + duration by a few
        // floating-point bits. A one-frame tolerance still rejects real overlaps.
        let shouldReject = enrollment.sampleRate.map { $0 != chunk.sampleRate } ?? false
            || enrollmentAudioEnd.map { chunk.startTime < $0 - 1 / chunk.sampleRate || chunk.startTime - $0 > policy.maxContinuousAudioGap } ?? false
        guard !shouldReject else {
            reportCaptureError(AIError(message: String(localized: "목소리 등록 오디오가 중간에 끊겼어요. 다시 녹음해 주세요.")))
            return
        }
        enrollmentAudioEnd = chunk.endTime
        enrollment.append(chunk, maximumDuration: policy.maximumEnrollmentDuration)
        presentation.elapsed = enrollment.duration
    }

    private func ingestLatestListeningWindow(from chunks: [LiveAudioSamples]) async {
        guard !chunks.isEmpty else { return }
        guard let voice = profile.localVoice else {
            state = .unavailable
            return
        }

        for chunk in chunks {
            let shouldReset = listeningWindow.sampleRate.map { $0 != chunk.sampleRate } ?? false
                || lastAudioEnd.map { chunk.startTime < $0 - 1 / chunk.sampleRate || chunk.startTime - $0 > policy.maxContinuousAudioGap } ?? false
            if shouldReset {
                listeningWindow.removeAll()
                state = .silence
            }
            lastAudioEnd = chunk.endTime

            guard rms(chunk.samples) >= policy.minimumSpeechRMS else {
                listeningWindow.removeAll()
                state = .silence
                scheduleStaleSilence()
                continue
            }

            listeningWindow.append(chunk, maximumDuration: policy.listeningWindowDuration)
        }

        guard let sampleRate = listeningWindow.sampleRate,
              listeningWindow.duration >= policy.listeningWindowDuration else {
            state = listeningWindow.samples.isEmpty ? .silence : .listening
            scheduleStaleSilence()
            return
        }

        let analysisID = UUID()
        let activeLifecycleID = lifecycleID
        let profileSnapshot = voice
        let samples = listeningWindow.samples
        listeningAnalysisID = analysisID
        do {
            let embedding = try await backend.embedding(samples: samples, sampleRate: sampleRate)
            guard canPublishAnalysis(
                lifecycleID: activeLifecycleID,
                analysisID: analysisID,
                profile: profileSnapshot
            ) else { return }
            state = policy.classify(
                embedding: embedding,
                profile: profileSnapshot,
                modelID: backend.embeddingModelID
            )
            presentation.status = status(for: state)
        } catch {
            guard canPublishAnalysis(
                lifecycleID: activeLifecycleID,
                analysisID: analysisID,
                profile: profileSnapshot
            ) else { return }
            state = .uncertain
            presentation.error = Self.message(for: error)
        }
        scheduleStaleSilence()
    }

    private func canPublishAnalysis(
        lifecycleID: UUID,
        analysisID: UUID,
        profile: LocalVoiceProfile
    ) -> Bool {
        self.lifecycleID == lifecycleID
            && self.listeningAnalysisID == analysisID
            && mode == .listening
            && self.profile.localVoice == profile
            && !inputQueue.hasPendingChunks()
    }

    private func scheduleStaleSilence() {
        let token = UUID()
        lastChunkToken = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(policy.staleAfter))
            guard self.lastChunkToken == token, self.mode == .listening else { return }
            self.listeningWindow.removeAll()
            self.state = .silence
            self.presentation.status = self.status(for: .silence)
        }
    }

    private func validateEmbedding(_ embedding: [Float]) throws {
        guard policy.isValidEmbedding(embedding) else {
            throw MeetingProfileValidationError.invalidEmbedding
        }
    }

    private func status(for state: OwnerSpeechState) -> String {
        switch state {
        case .unavailable:
            return String(localized: "Owner detection is unavailable.")
        case .listening:
            return String(localized: "Listening for your voice...")
        case .silence:
            return String(localized: "No speech detected.")
        case .owner:
            return String(localized: "Your voice is active.")
        case .other:
            return String(localized: "Another speaker is active.")
        case .uncertain:
            return String(localized: "Speaker match is uncertain.")
        }
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

nonisolated private final class BoundedLiveAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private let maxChunks: Int
    private var chunks: [LiveAudioSamples] = []
    private var drainScheduled = false

    init(maxChunks: Int) {
        self.maxChunks = max(1, maxChunks)
    }

    func enqueue(_ chunk: LiveAudioSamples, scheduleDrain: () -> Void) {
        var shouldSchedule = false
        lock.lock()
        chunks.append(chunk)
        if chunks.count > maxChunks {
            chunks.removeFirst(chunks.count - maxChunks)
        }
        if !drainScheduled {
            drainScheduled = true
            shouldSchedule = true
        }
        lock.unlock()
        if shouldSchedule {
            scheduleDrain()
        }
    }

    func drain() -> [LiveAudioSamples] {
        lock.lock()
        defer { lock.unlock() }
        let drained = chunks
        chunks.removeAll(keepingCapacity: true)
        return drained
    }

    func finishDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = !chunks.isEmpty
        return drainScheduled
    }

    func hasPendingChunks() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !chunks.isEmpty
    }

    func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
    }
}

nonisolated private extension LiveAudioSamples {
    var duration: Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    var endTime: Double {
        startTime + duration
    }

    var isUsable: Bool {
        sampleRate.isFinite && sampleRate > 0 && startTime.isFinite && samples.allSatisfy(\.isFinite)
    }
}

nonisolated private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples {
        sum += sample * sample
    }
    return sqrt(sum / Float(samples.count))
}
