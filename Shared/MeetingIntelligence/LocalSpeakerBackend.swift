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

    private let modelDirectory: URL?
    private let localSegmentationModel: URL?
    private let localEmbeddingModel: URL?
    private var cachedModels: DiarizerModels?
    private var prepareTask: Task<DiarizerModels, Error>?

    init(
        modelDirectory: URL? = nil,
        localSegmentationModel: URL? = nil,
        localEmbeddingModel: URL? = nil
    ) {
        let modelDirectory = modelDirectory ?? Self.defaultModelDirectory
        self.modelDirectory = modelDirectory
        self.localSegmentationModel = localSegmentationModel ?? modelDirectory.appendingPathComponent(Self.segmentationModelFileName, isDirectory: true)
        self.localEmbeddingModel = localEmbeddingModel ?? modelDirectory.appendingPathComponent(Self.embeddingModelFileName, isDirectory: true)
    }

    func prepare() async throws {
        _ = try await loadModels()
    }

    func prepareCachedIfAvailable() async throws -> Bool {
        guard cachedModels == nil else { return true }
        if let prepareTask {
            cachedModels = try await prepareTask.value
            return true
        }
        guard cachedModelFilesExist(), let localSegmentationModel, let localEmbeddingModel else { return false }
        // No suspension or network: an explicit prepare cannot inherit a failing
        // restore-only task, and a broken cache remains repairable by prepare().
        cachedModels = try DiarizerModels.load(localSegmentationModel: localSegmentationModel,
            localEmbeddingModel: localEmbeddingModel)
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
        guard let models = cachedModels else { throw notPreparedError() }
        let manager = makeManager(models: models)
        var segments: [TimedSpeakerSegment] = []

        try LocalSpeakerAudioFileWindows.readMonoWindows(from: audioURL, targetSampleRate: 16_000) { window in
            let result = try manager.performCompleteDiarization(
                window.samples,
                sampleRate: Int(window.sampleRate),
                atTime: window.startTime
            )
            segments.append(contentsOf: result.segments)
        }

        return Self.acousticDiarization(from: segments, speakers: manager.speakerManager.getAllSpeakers())
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
        var config = DiarizerConfig.default
        config.chunkDuration = 10
        config.chunkOverlap = 0
        config.debugMode = false
        let manager = DiarizerManager(config: config)
        // Use the SDK's documented streaming thresholds (0.65/0.45 distance).
        // DiarizerConfig's derived 0.84 assignment distance merges distinct voices
        // across our independently processed ten-second windows.
        manager.speakerManager = SpeakerManager()
        let modelCopy = models
        manager.initialize(models: modelCopy)
        return manager
    }

    private func cachedModelFilesExist() -> Bool {
        guard let localSegmentationModel, let localEmbeddingModel else { return false }
        return FileManager.default.fileExists(atPath: localSegmentationModel.path)
            && FileManager.default.fileExists(atPath: localEmbeddingModel.path)
    }

    private func notPreparedError() -> AIError {
        AIError(message: String(localized: "화자 인식 모델이 아직 준비되지 않았어요. 프로필 설정에서 먼저 목소리 모델을 준비해 주세요."))
    }

    nonisolated private static func acousticDiarization(from segments: [TimedSpeakerSegment], speakers: [String: Speaker]) -> AcousticDiarization {
        var speakerEmbeddings = speakers.map { id, speaker in
            AcousticSpeaker(id: id, embedding: speaker.currentEmbedding)
        }
        let knownIDs = Set(speakerEmbeddings.map(\.id))
        let missingSpeakers = Dictionary(grouping: segments.filter { !$0.speakerId.isEmpty && !knownIDs.contains($0.speakerId) }, by: \.speakerId)
            .compactMap { id, grouped -> AcousticSpeaker? in
                guard let embedding = grouped.first?.embedding, embedding.count == SpeakerManager.embeddingSize else { return nil }
                return AcousticSpeaker(id: id, embedding: embedding)
            }
        speakerEmbeddings.append(contentsOf: missingSpeakers)
        speakerEmbeddings.sort { $0.id < $1.id }

        return AcousticDiarization(speakers: speakerEmbeddings, spans: overlapAwareSpans(from: segments))
    }

    nonisolated private static func overlapAwareSpans(from segments: [TimedSpeakerSegment]) -> [AcousticSpeakerSpan] {
        nonisolated struct Event {
            let time: Double
            let speakerID: String
            let delta: Int
        }

        let events = segments.flatMap { segment in
            let speakerID = segment.speakerId
            return [
                Event(time: Double(segment.startTimeSeconds), speakerID: speakerID, delta: 1),
                Event(time: Double(segment.endTimeSeconds), speakerID: speakerID, delta: -1),
            ]
        }.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.delta < rhs.delta
        }

        var activeSpeakerCounts: [String: Int] = [:]
        var overlappingIntervals: [(start: Double, end: Double)] = []
        var index = events.startIndex
        var previousTime: Double?

        while index < events.endIndex {
            let time = events[index].time
            if let previousTime, previousTime < time, activeSpeakerCounts.keys.count > 1 {
                overlappingIntervals.append((previousTime, time))
            }
            while index < events.endIndex, events[index].time == time {
                let event = events[index]
                if !event.speakerID.isEmpty {
                    let nextCount = (activeSpeakerCounts[event.speakerID] ?? 0) + event.delta
                    if nextCount > 0 {
                        activeSpeakerCounts[event.speakerID] = nextCount
                    } else {
                        activeSpeakerCounts.removeValue(forKey: event.speakerID)
                    }
                }
                index = events.index(after: index)
            }
            previousTime = time
        }

        let baseSpans = segments.map { segment in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            return AcousticSpeakerSpan(
                start: start,
                end: end,
                speakerID: segment.speakerId.isEmpty ? nil : segment.speakerId,
                isOverlap: false
            )
        }
        let overlapSpans = overlappingIntervals.map {
            AcousticSpeakerSpan(start: $0.start, end: $0.end, speakerID: nil, isOverlap: true)
        }
        return (baseSpans + overlapSpans).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return !$0.isOverlap && $1.isOverlap
        }
    }
}
