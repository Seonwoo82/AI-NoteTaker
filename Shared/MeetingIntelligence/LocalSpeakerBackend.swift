import Foundation
import FluidAudio

nonisolated let localSpeakerBackendEmbeddingModelID = "fluidaudio-0.15.6-wespeaker-v2-256d"

enum SpeakerBackendFactory {
    static func make() -> any SpeakerAnalysisServing {
        return LocalSpeakerBackend(modelDirectory: LocalSpeakerBackend.defaultModelDirectory)
    }
}

actor LocalSpeakerBackend: SpeakerAnalysisServing {
    nonisolated let embeddingModelID = localSpeakerBackendEmbeddingModelID
    nonisolated static let diarizerRepoFolderName = Repo.diarizer.folderName
    nonisolated static let segmentationModelFileName = "pyannote_segmentation.mlmodelc"
    nonisolated static let embeddingModelFileName = "wespeaker_v2.mlmodelc"
    nonisolated static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI-NoteTaker", isDirectory: true)
            .appendingPathComponent("VoiceModels", isDirectory: true)
            .appendingPathComponent(diarizerRepoFolderName, isDirectory: true)
    }
    nonisolated static var defaultOfflineModelDirectory: URL {
        defaultModelDirectory.deletingLastPathComponent().appending(path: "offline-diarizer")
    }

    private let modelDirectory: URL?
    private let localSegmentationModel: URL?
    private let localEmbeddingModel: URL?
    private let offlineModelDirectory: URL
    private var cachedModels: DiarizerModels?
    private var cachedOfflineModels: OfflineDiarizerModels?
    private var prepareTask: Task<DiarizerModels, Error>?
    private var offlinePrepareTask: Task<OfflineDiarizerModels, Error>?

    init(
        modelDirectory: URL? = nil,
        localSegmentationModel: URL? = nil,
        localEmbeddingModel: URL? = nil,
        offlineModelDirectory: URL? = nil
    ) {
        let modelDirectory = modelDirectory ?? Self.defaultModelDirectory
        self.modelDirectory = modelDirectory
        self.localSegmentationModel = localSegmentationModel ?? modelDirectory.appendingPathComponent(Self.segmentationModelFileName, isDirectory: true)
        self.localEmbeddingModel = localEmbeddingModel ?? modelDirectory.appendingPathComponent(Self.embeddingModelFileName, isDirectory: true)
        self.offlineModelDirectory = offlineModelDirectory
            ?? modelDirectory.deletingLastPathComponent().appending(path: "offline-diarizer")
    }

    func prepare() async throws {
        _ = try await loadModels()
        _ = try await loadOfflineModels()
    }

    func prepareCachedIfAvailable() async throws -> Bool {
        if cachedModels == nil {
            if let prepareTask {
                cachedModels = try await prepareTask.value
            } else {
                guard cachedModelFilesExist(), let localSegmentationModel, let localEmbeddingModel else { return false }
                cachedModels = try DiarizerModels.load(localSegmentationModel: localSegmentationModel,
                    localEmbeddingModel: localEmbeddingModel)
            }
        }
        // Live recognition and enrollment only require the existing WeSpeaker
        // stack. Offline cache failures must not disable those features on upgrade.
        if cachedOfflineModels == nil, offlinePrepareTask == nil {
            cachedOfflineModels = try? OfflineSpeakerModelCache(directory: offlineModelDirectory).loadCached()
        }
        return true
    }

    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] {
        guard let models = cachedModels else { throw notPreparedError() }
        let mono16k = try LocalSpeakerAudioConverter.convertMonoSamplesTo16k(samples, sampleRate: sampleRate)
        guard !mono16k.isEmpty else {
            throw AIError(message: String(localized: "화자 임베딩을 만들 오디오가 비어 있어요."))
        }
        let manager = makeManager(models: models)
        let embedding = try manager.extractSpeakerEmbedding(from: mono16k)
        guard embedding.count == SpeakerManager.embeddingSize else {
            throw AIError(message: String(localized: "화자 임베딩 차원이 올바르지 않아요. 256차원 모델이 필요합니다."))
        }
        return embedding
    }

    func enrollmentEmbedding(samples: [Float], sampleRate: Double) async throws -> [Float] {
        guard let models = cachedModels else { throw notPreparedError() }
        let converted = try LocalSpeakerAudioConverter.convertMonoSamplesTo16k(samples, sampleRate: sampleRate)
        let prepared = try VoiceEnrollmentSignal.prepared16kSamples(converted)
        let manager = makeManager(models: models)
        guard let segmentation = manager.segmentationModel, let extractor = manager.embeddingExtractor else {
            throw notPreparedError()
        }
        // WeSpeaker uses a ten-second waveform. Score overlapping windows so
        // leading silence or speech near the end cannot be discarded by slot zero.
        var bestAudio: ArraySlice<Float> = []
        var bestMask: [Float] = []
        var bestSpeechDuration: Double = 0
        for start in stride(from: 0, to: prepared.count, by: 80_000) {
            try Task.checkCancellation()
            let window = prepared[start..<min(prepared.count, start + 160_000)]
            let (batches, _) = try manager.segmentationProcessor.getSegments(
                audioChunk: window, segmentationModel: segmentation)
            guard let frames = batches.first, !frames.isEmpty else { continue }
            // Pinned pyannote model: 270-sample hop at 16 kHz (FluidAudio 0.15.6).
            let frameDuration = 270.0 / 16_000
            let validDuration = Double(window.count) / 16_000
            for speaker in 0..<3 {
                let mask = frames.enumerated().map { index, frame -> Float in
                    guard Double(index) * frameDuration < validDuration,
                          frame.indices.contains(speaker), frame.reduce(0, +) < 2 else { return 0 }
                    return frame[speaker]
                }
                let speechDuration = Double(mask.reduce(0, +)) * frameDuration
                if speechDuration > bestSpeechDuration {
                    bestSpeechDuration = speechDuration
                    bestAudio = window
                    bestMask = mask
                }
            }
        }
        guard bestSpeechDuration >= 3 else {
            throw AIError(message: String(localized: "Speech could not be identified clearly. Read the guide in a quiet place without other voices."))
        }
        try Task.checkCancellation()
        let embeddings = try extractor.getEmbeddings(audio: bestAudio, masks: [bestMask])
        guard let embedding = embeddings.first, embedding.count == SpeakerManager.embeddingSize,
              OwnerVoicePolicy().isValidEmbedding(embedding) else {
            throw AIError(message: String(localized: "A voice profile could not be created from this recording. Please record again."))
        }
        return embedding
    }

    func diarize(audioURL: URL) async throws -> AcousticDiarization {
        guard cachedModels != nil, let offlineModels = cachedOfflineModels else { throw notPreparedError() }
        var config = OfflineDiarizerConfig.default
        config.postProcessing.exclusiveSegments = false
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: offlineModels)
        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL)
        } catch OfflineDiarizationError.noSpeechDetected {
            return AcousticDiarization(speakers: [], spans: [])
        }
        try Task.checkCancellation()
        let timeline = OfflineSpeakerTimeline(segments: result.segments)
        let embeddings = try await representativeEmbeddings(audioURL: audioURL, timeline: timeline)
        return AcousticDiarization(speakers: timeline.speakerIDs.map {
            AcousticSpeaker(id: $0, embedding: embeddings[$0] ?? [])
        }, spans: timeline.spans)
    }

    private func representativeEmbeddings(audioURL: URL, timeline: OfflineSpeakerTimeline) async throws -> [String: [Float]] {
        let clips = timeline.representativeClips()
        guard !clips.isEmpty else { return [:] }
        var audio = [[Float]](repeating: [], count: clips.count)
        try LocalSpeakerAudioFileWindows.readMonoWindows(from: audioURL, targetSampleRate: 16_000) { window in
            for index in clips.indices { audio[index].append(contentsOf: clips[index].samples(in: window)) }
        }
        var embeddings: [String: [[Float]]] = [:]
        for index in clips.indices {
            try Task.checkCancellation()
            do {
                // Match enrollment's signal preparation and clean-speech mask with
                // the original WeSpeaker model, preserving stored profile compatibility.
                let embedding = try await enrollmentEmbedding(samples: audio[index], sampleRate: 16_000)
                embeddings[clips[index].speakerID, default: []].append(embedding)
            } catch is AIError {
                // A short or unclear clip supplies no owner evidence. Keep its
                // offline speaker spans even when all representative clips fail.
                continue
            }
        }
        return embeddings.mapValues { OfflineSpeakerTimeline.averageEmbeddings($0) }
    }

    private func loadModels() async throws -> DiarizerModels {
        if let cachedModels { return cachedModels }
        if let prepareTask {
            let models = try await prepareTask.value
            cachedModels = models
            self.prepareTask = nil
            return models
        }

        let modelDirectory = self.modelDirectory
        // The SDK validates complete model bundles and repairs corrupt downloads.
        // Do not bypass its recovery path merely because two directories exist.
        let task = Task.detached(priority: .userInitiated) {
            try await DiarizerModels.downloadIfNeeded(to: modelDirectory)
        }
        prepareTask = task
        do {
            let models = try await task.value
            cachedModels = models
            prepareTask = nil
            return models
        } catch {
            prepareTask = nil
            throw error
        }
    }

    private func makeManager(models: DiarizerModels) -> DiarizerManager {
        let manager = DiarizerManager()
        let modelCopy = models
        manager.initialize(models: modelCopy)
        return manager
    }

    private func loadOfflineModels() async throws -> OfflineDiarizerModels {
        if let cachedOfflineModels { return cachedOfflineModels }
        if let offlinePrepareTask {
            let models = try await offlinePrepareTask.value
            cachedOfflineModels = models
            self.offlinePrepareTask = nil
            return models
        }
        let directory = offlineModelDirectory
        let task = Task.detached(priority: .userInitiated) {
            try await OfflineDiarizerModels.load(from: directory)
        }
        offlinePrepareTask = task
        do {
            let models = try await task.value
            cachedOfflineModels = models
            offlinePrepareTask = nil
            return models
        } catch {
            offlinePrepareTask = nil
            throw error
        }
    }

    private func cachedModelFilesExist() -> Bool {
        guard let localSegmentationModel, let localEmbeddingModel else { return false }
        return FileManager.default.fileExists(atPath: localSegmentationModel.path)
            && FileManager.default.fileExists(atPath: localEmbeddingModel.path)
    }

    private func notPreparedError() -> AIError {
        AIError(message: String(localized: "화자 인식 모델이 아직 준비되지 않았어요. 프로필 설정에서 먼저 목소리 모델을 준비해 주세요."))
    }

}
