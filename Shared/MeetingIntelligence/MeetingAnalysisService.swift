import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class MeetingAnalysisService {
    private enum AnalysisProgress: Equatable {
        case idle
        case queued
        case preparing
        case transcribing(completed: Int, total: Int)
        case diarizing
        case analyzing
        case completed
        case cancelled
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .queued, .preparing, .transcribing, .diarizing, .analyzing:
                true
            default:
                false
            }
        }

        var displayStatus: String {
            switch self {
            case .idle:
                return String(localized: "Meeting analysis has not started.")
            case .queued:
                return String(localized: "Queued for meeting analysis.")
            case .preparing:
                return String(localized: "Preparing meeting analysis.")
            case let .transcribing(completed, total):
                return String(localized: "Transcribing meeting audio \(completed)/\(total).")
            case .diarizing:
                return String(localized: "Separating speakers.")
            case .analyzing:
                return String(localized: "Analyzing commitments, questions, and decisions.")
            case .completed:
                return String(localized: "Meeting analysis is complete.")
            case .cancelled:
                return String(localized: "Meeting analysis was cancelled.")
            case let .failed(message):
                return String(localized: "Meeting analysis failed: \(message)")
            }
        }
    }

    private struct Job {
        let token: UUID
        let recording: Recording
        let key: String
        let analysisModelID: String
        let transcriptionModelID: String
        let language: String
        let inputBudget: Int
        let outputBudget: Int
        let forceTranscription: Bool
    }

    private let library: LibraryStore
    private let configuration: AIConfiguration
    private let profile: MeetingProfileStore
    private let store: MeetingIntelligenceStore
    private let edits: MeetingEditLog
    private let speakerBackend: any SpeakerAnalysisServing
    private let client: any OpenRouterServing
    private let detailedClient: any DetailedTranscriptionServing
    private static let maximumSafeTimestamp: Int64 = 9_007_199_254_740_991

    private let chunker: any MeetingAudioChunking
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var transcriptPreparationID: UUID?
    @ObservationIgnored private var tokens: [UUID: UUID] = [:]
    @ObservationIgnored var onTranscriptReady: ((Recording) -> Void)?
    @ObservationIgnored var onFinished: ((Recording, Bool) -> Void)?
    private var states: [UUID: AnalysisProgress] = [:]

    init(
        library: LibraryStore,
        configuration: AIConfiguration,
        profile: MeetingProfileStore,
        store: MeetingIntelligenceStore,
        edits: MeetingEditLog,
        speakerBackend: any SpeakerAnalysisServing,
        client: any OpenRouterServing,
        detailedClient: any DetailedTranscriptionServing,
        chunker: any MeetingAudioChunking = MeetingAudioChunker()
    ) {
        self.library = library
        self.configuration = configuration
        self.profile = profile
        self.store = store
        self.edits = edits
        self.speakerBackend = speakerBackend
        self.client = client
        self.detailedClient = detailedClient
        self.chunker = chunker
    }

    func analyze(_ recording: Recording, forceTranscription: Bool = false) {
        guard !isRunning(for: recording.id),
              let current = library.recording(id: recording.id),
              current.deletedAt == nil,
              current.audioVersion == recording.audioVersion else { return }
        guard configuration.isConfigured else {
            states[recording.id] = .failed("설정에서 OpenRouter API 키와 AI 모델을 선택해 주세요.")
            return
        }
        do {
            let key = try configuration.apiKey()
            let model = configuration.models.first { $0.id == configuration.modelID }
            let budget = MeetingCompletionBudget(model: model, modelID: configuration.modelID, fallbackContext: 32_000)
            let job = Job(token: UUID(), recording: current, key: key,
                analysisModelID: configuration.modelID,
                transcriptionModelID: configuration.transcriptionModelID,
                language: configuration.outputLanguage,
                inputBudget: budget.inputBytes,
                outputBudget: budget.outputTokens,
                forceTranscription: forceTranscription)
            tokens[recording.id] = job.token
            states[recording.id] = .queued
            queue.append(job)
            startNext()
        } catch {
            states[recording.id] = .failed("저장된 API 키를 읽지 못했습니다. 설정에서 키를 다시 저장해 주세요.")
        }
    }

    func cancel(_ id: UUID) {
        tokens[id] = UUID()
        let cancelledQueued = queue.filter { $0.recording.id == id }
        queue.removeAll { $0.recording.id == id }
        if activeID == id { activeTask?.cancel() }
        if isRunning(for: id) {
            states[id] = .cancelled
        }
        for job in cancelledQueued {
            onFinished?(job.recording, false)
        }
    }

    func cancelAll() {
        for id in Set(queue.map { $0.recording.id } + Array(states.keys)) {
            cancel(id)
        }
    }

    func credentialsDidChange() {
        cancelAll()
    }

    func status(for id: UUID) -> String {
        (states[id] ?? .idle).displayStatus
    }

    func isRunning(for id: UUID) -> Bool {
        (states[id] ?? .idle).isRunning
    }

    func wasCancelled(for id: UUID) -> Bool {
        states[id] == .cancelled
    }

    func prepareNumberedTranscript(_ recording: Recording, transcriptionModelID: String? = nil) async throws -> MeetingTranscript {
        try Task.checkCancellation()
        let requestedModelID = transcriptionModelID ?? configuration.transcriptionModelID
        guard let current = library.recording(id: recording.id),
              current.deletedAt == nil,
              current.audioVersion == recording.audioVersion else {
            throw CancellationError()
        }
        if let transcript = try await reusableResolvedTranscript(for: current, modelID: requestedModelID) {
            return transcript
        }
        guard activeTask == nil, transcriptPreparationID == nil, queue.isEmpty else {
            throw AIError(message: String(localized: "Meeting analysis is already running."))
        }
        guard configuration.isConfigured else {
            throw AIError(message: String(localized: "설정에서 OpenRouter API 키와 AI 모델을 선택해 주세요."))
        }

        let key: String
        do {
            key = try configuration.apiKey()
        } catch {
            throw AIError(message: String(localized: "저장된 API 키를 읽지 못했습니다. 설정에서 키를 다시 저장해 주세요."))
        }

        let token = UUID()
        let model = configuration.models.first { $0.id == configuration.modelID }
        let budget = MeetingCompletionBudget(model: model, modelID: configuration.modelID, fallbackContext: 32_000)
        let job = Job(token: token, recording: current, key: key,
            analysisModelID: configuration.modelID,
            transcriptionModelID: requestedModelID,
            language: configuration.outputLanguage,
            inputBudget: budget.inputBytes,
            outputBudget: budget.outputTokens,
            forceTranscription: false)
        tokens[current.id] = token
        transcriptPreparationID = current.id
        states[current.id] = .preparing
        defer {
            if tokens[current.id] == token { tokens[current.id] = nil }
            if transcriptPreparationID == current.id { transcriptPreparationID = nil }
            startNext()
        }

        do {
            try check(job)
            let transcript = try await transcript(for: job)
            try check(job)
            try await saveTranscriptOnlyDocumentIfNeeded(transcript, job: job)
            try check(job)
            states[current.id] = .completed
            return try correctedTranscriptForAnalysis(base: transcript, job: job)
        } catch {
            if error is CancellationError || Task.isCancelled {
                states[current.id] = .cancelled
            } else {
                states[current.id] = .failed(sanitizedMessage(error, redacting: key))
            }
            throw error
        }
    }

    private func startNext() {
        guard activeTask == nil, transcriptPreparationID == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        activeID = job.recording.id
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.run(job)
            self.activeTask = nil
            self.activeID = nil
            self.startNext()
        }
    }

    private func run(_ job: Job) async {
        var saved = false
        defer {
            onFinished?(job.recording, saved)
        }
        do {
            try check(job)
            states[job.recording.id] = .preparing
            let transcript = try await transcript(for: job)
            try check(job)
            onTranscriptReady?(job.recording)
            let analysisTranscript = try correctedTranscriptForAnalysis(base: transcript, job: job)
            states[job.recording.id] = .analyzing
            let insights = try await analyzeTranscript(analysisTranscript, job: job)
            try check(job)
            let previousDocument = await store.load(job.recording) ?? store.document(for: job.recording.id)
            let previousProjectName = previousDocument?.projectName ?? ""
            let mutationID = UUID()
            let document = MeetingIntelligenceDocument(recordingID: job.recording.id,
                audioVersion: job.recording.audioVersion,
                modifiedAt: publishTimestamp(after: previousDocument?.modifiedAt),
                mutationID: mutationID,
                projectName: previousProjectName,
                transcript: transcript,
                insights: insights,
                actionStates: preservedActionStates(previous: previousDocument, insights: insights),
                analysisModelID: job.analysisModelID)
            try check(job)
            try await store.save(document)
            guard store.document(for: job.recording.id)?.mutationID == mutationID else {
                throw AIError(message: "새 회의 분석이 기존 동기화 문서보다 최신으로 저장되지 않았습니다. 잠시 후 다시 분석해 주세요.")
            }
            try check(job)
            saved = true
            states[job.recording.id] = .completed
        } catch {
            if error is CancellationError || Task.isCancelled {
                states[job.recording.id] = .cancelled
            } else {
                states[job.recording.id] = .failed(sanitizedMessage(error, redacting: job.key))
            }
        }
    }

    private func reusableResolvedTranscript(for recording: Recording, modelID: String) async throws -> MeetingTranscript? {
        let loaded = await store.load(recording)
        try Task.checkCancellation()
        guard let current = library.recording(id: recording.id), current.deletedAt == nil,
              current.audioVersion == recording.audioVersion else { throw CancellationError() }
        guard let document = loaded ?? store.document(for: recording.id),
              document.transcript.transcriptionModelID == modelID else {
            return nil
        }
        return try document.resolved(edits: edits.edits(for: recording.id,
            audioVersion: recording.audioVersion)).transcript
    }

    private func saveTranscriptOnlyDocumentIfNeeded(_ transcript: MeetingTranscript, job: Job) async throws {
        let loaded = await store.load(job.recording)
        let previousDocument = loaded ?? store.document(for: job.recording.id)
        guard previousDocument?.insights == nil else { return }
        let mutationID = UUID()
        let document = MeetingIntelligenceDocument(recordingID: job.recording.id,
            audioVersion: job.recording.audioVersion,
            modifiedAt: publishTimestamp(after: previousDocument?.modifiedAt),
            mutationID: mutationID,
            projectName: previousDocument?.projectName ?? "",
            transcript: transcript,
            insights: nil,
            analysisModelID: job.analysisModelID)
        try check(job)
        try await store.save(document)
    }

    private func transcript(for job: Job) async throws -> MeetingTranscript {
        let audioURL = library.audioURL(for: job.recording)
        let chunkCount = try await chunker.chunkCount(for: audioURL)
        guard chunkCount > 0 else { throw AIError(message: "녹음 파일에 처리할 오디오가 없습니다.") }
        guard chunkCount <= 180, job.recording.duration <= 6 * 60 * 60 else {
            throw AIError(message: "AI 회의 분석은 한 번에 최대 6시간까지 처리합니다. 녹음을 나누어 처리해 주세요.")
        }
        try check(job)
        try await speakerBackend.prepare()
        try check(job)
        let chunks: [TimedTranscriptChunk]
        if !job.forceTranscription,
           let cached = loadTimedTranscriptCache(recording: job.recording,
               modelID: job.transcriptionModelID,
               language: "auto",
               chunkCount: chunkCount) {
            chunks = cached.timedChunks
        } else {
            var transcribedChunks: [TimedTranscriptChunk] = []
            var totalTranscriptBytes = 0
            for index in 0..<chunkCount {
                try check(job)
                states[job.recording.id] = .transcribing(completed: index, total: chunkCount)
                let audioChunk = try await chunker.chunk(for: audioURL, index: index)
                let result = try await detailedClient.transcribeDetailed(audio: audioChunk.data,
                    format: audioChunk.format, model: job.transcriptionModelID, apiKey: job.key,
                    language: nil, prompt: profile.profile.promptContext)
                totalTranscriptBytes += result.text.utf8.count
                guard totalTranscriptBytes <= 1_000_000 else {
                    throw AIError(message: "전사문이 처리 한도를 초과했습니다. 녹음을 나누어 처리해 주세요.")
                }
                transcribedChunks.append(TimedTranscriptChunk(startTime: audioChunk.startTime, result: result))
                try checkpointPlainTranscriptCache(chunks: transcribedChunks, chunkCount: chunkCount, job: job)
            }
            try saveTimedTranscriptCache(DetailedTimedTranscriptCache(recordingID: job.recording.id,
                audioVersion: job.recording.audioVersion,
                modelID: job.transcriptionModelID,
                language: "auto",
                chunkCount: chunkCount,
                chunks: transcribedChunks), recording: job.recording)
            chunks = transcribedChunks
        }

        try check(job)
        states[job.recording.id] = .diarizing
        let diarization = try await speakerBackend.diarize(audioURL: audioURL)
        let transcript = try TranscriptAssembler.assemble(recordingID: job.recording.id,
            audioVersion: job.recording.audioVersion,
            transcriptionModelID: job.transcriptionModelID,
            chunks: chunks,
            diarization: diarization,
            ownerVoice: profile.localVoice,
            embeddingModelID: speakerBackend.embeddingModelID,
            duration: job.recording.duration,
            ownerName: profile.profile.displayName)
        guard !transcript.turns.isEmpty else {
            throw AIError(message: "인식된 대화가 없습니다. 음성이 포함된 녹음인지 확인해 주세요.")
        }
        return transcript
    }

    private func correctedTranscriptForAnalysis(base: MeetingTranscript, job: Job) throws -> MeetingTranscript {
        let temporary = MeetingIntelligenceDocument(recordingID: job.recording.id,
            audioVersion: job.recording.audioVersion,
            modifiedAt: millisecondsSince1970(),
            mutationID: UUID(),
            projectName: "",
            transcript: base,
            insights: nil,
            analysisModelID: job.analysisModelID)
        return try temporary.resolved(edits: edits.edits(for: job.recording.id,
            audioVersion: job.recording.audioVersion)).transcript
    }

    private func analyzeTranscript(_ transcript: MeetingTranscript, job: Job) async throws -> MeetingInsights {
        var calls = 0
        var merged = MeetingInsights()
        for chunk in transcriptChunks(transcript, maximumBytes: job.inputBudget) {
            try check(job)
            guard calls < 80 else {
                throw AIError(message: "회의 분석 요청 한도에 도달했습니다. 녹음을 더 짧게 나누어 처리해 주세요.")
            }
            calls += 1
            let userPrompt = MeetingAnalysisPrompt.userPrompt(transcript: chunk, profileContext: profile.profile.promptContext)
            let finalPrompt = "\(languageInstruction(job.language))\n\n\(userPrompt)"
            guard finalPrompt.utf8.count <= job.inputBudget else {
                throw AIError(message: "회의 분석 프롬프트가 모델의 처리 범위를 초과합니다. 더 큰 문맥을 지원하는 모델을 선택해 주세요.")
            }
            let response = try await client.complete(system: MeetingAnalysisPrompt.systemPrompt,
                user: finalPrompt,
                model: job.analysisModelID, apiKey: job.key, maxTokens: job.outputBudget)
            let partial = try MeetingAnalysisPrompt.decode(response.text, transcript: chunk)
            merged = merge(merged, canonicalized(partial))
        }
        try merged.validate(transcript: transcript)
        return merged
    }

    private func transcriptChunks(_ transcript: MeetingTranscript, maximumBytes: Int) -> [MeetingTranscript] {
        let fullPrompt = MeetingAnalysisPrompt.userPrompt(transcript: transcript, profileContext: profile.profile.promptContext)
        guard fullPrompt.utf8.count > maximumBytes else { return [transcript] }
        var chunks: [MeetingTranscript] = []
        var current: [TranscriptTurn] = []
        var currentBytes = MeetingAnalysisPrompt.userPrompt(transcript: copy(transcript, turns: []),
            profileContext: profile.profile.promptContext).utf8.count
        let promptOverhead = currentBytes
        let overlapCount = 3
        for turn in transcript.turns {
            let turnBytes = turn.text.utf8.count + turn.id.utf8.count + 80
            if !current.isEmpty, currentBytes + turnBytes > maximumBytes {
                chunks.append(copy(transcript, turns: current))
                current = Array(current.suffix(overlapCount))
                currentBytes = promptOverhead + current.reduce(0) { $0 + $1.text.utf8.count + $1.id.utf8.count + 80 }
            }
            current.append(turn)
            currentBytes += turnBytes
        }
        if !current.isEmpty {
            chunks.append(copy(transcript, turns: current))
        }
        return chunks
    }

    private func copy(_ transcript: MeetingTranscript, turns: [TranscriptTurn]) -> MeetingTranscript {
        let used = Set(turns.compactMap(\.speakerID))
        return MeetingTranscript(schemaVersion: transcript.schemaVersion,
            recordingID: transcript.recordingID,
            audioVersion: transcript.audioVersion,
            transcriptionModelID: transcript.transcriptionModelID,
            speakers: transcript.speakers.filter { used.contains($0.id) },
            turns: turns)
    }

    private func merge(_ lhs: MeetingInsights, _ rhs: MeetingInsights) -> MeetingInsights {
        MeetingInsights(actions: unique(lhs.actions + rhs.actions, by: \.id),
            questions: unique(lhs.questions + rhs.questions, by: \.id),
            decisions: unique(lhs.decisions + rhs.decisions, by: \.id))
    }

    private func canonicalized(_ insights: MeetingInsights) -> MeetingInsights {
        MeetingInsights(actions: insights.actions.map { action in
            MeetingAction(id: stableID(prefix: "action",
                parts: [action.kind.rawValue, action.actorSpeakerID ?? "", action.targetSpeakerID ?? "", action.dueText ?? ""] + action.evidenceTurnIDs),
                kind: action.kind, text: action.text, actorSpeakerID: action.actorSpeakerID,
                targetSpeakerID: action.targetSpeakerID, dueText: action.dueText,
                evidenceTurnIDs: Array(dictOrderedUnique: action.evidenceTurnIDs))
        }, questions: insights.questions.map { question in
            MeetingQuestion(id: stableID(prefix: "question",
                parts: question.questionTurnIDs + question.answerTurnIDs + [question.status.rawValue]),
                question: question.question, questionTurnIDs: Array(dictOrderedUnique: question.questionTurnIDs),
                answer: question.answer, answerTurnIDs: Array(dictOrderedUnique: question.answerTurnIDs),
                status: question.status)
        }, decisions: insights.decisions.map { decision in
            MeetingDecision(id: stableID(prefix: "decision",
                parts: [decision.status.rawValue] + decision.steps.map(\.kind.rawValue) + decision.steps.flatMap(\.evidenceTurnIDs)),
                topic: decision.topic, status: decision.status, steps: decision.steps.map { step in
                    MeetingDecisionStep(kind: step.kind, text: step.text, speakerID: step.speakerID,
                        evidenceTurnIDs: Array(dictOrderedUnique: step.evidenceTurnIDs))
                })
        })
    }

    private func unique<Element>(_ values: [Element], by id: KeyPath<Element, String>) -> [Element] {
        var seen = Set<String>()
        return values.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private func check(_ job: Job) throws {
        try Task.checkCancellation()
        guard tokens[job.recording.id] == job.token,
              let current = library.recording(id: job.recording.id),
              current.deletedAt == nil,
              current.audioVersion == job.recording.audioVersion else {
            throw CancellationError()
        }
    }

    private func loadTimedTranscriptCache(
        recording: Recording,
        modelID: String,
        language: String,
        chunkCount: Int
    ) -> DetailedTimedTranscriptCache? {
        guard let cache = try? loadBounded(DetailedTimedTranscriptCache.self,
              from: cacheURL(for: recording.id),
              maximumBytes: Self.maximumTimedCacheBytes),
              cache.schemaVersion == 1,
              cache.recordingID == recording.id,
              cache.audioVersion == recording.audioVersion,
              cache.modelID == modelID,
              cache.language == language,
              cache.chunkCount == chunkCount,
              cache.chunks.count <= chunkCount,
              cache.totalTextByteCount <= 1_000_000 else { return nil }
        return cache
    }

    private func saveTimedTranscriptCache(_ cache: DetailedTimedTranscriptCache, recording: Recording) throws {
        guard let current = library.recording(id: recording.id),
              current.deletedAt == nil,
              current.audioVersion == recording.audioVersion,
              FileManager.default.fileExists(atPath: library.audioURL(for: recording).path) else {
            throw CancellationError()
        }
        try writeCache(cache, to: cacheURL(for: recording.id), maximumBytes: Self.maximumTimedCacheBytes)
    }

    private func checkpointPlainTranscriptCache(
        chunks: [TimedTranscriptChunk],
        chunkCount: Int,
        job: Job
    ) throws {
        try check(job)
        let existing = try? loadBounded(AITranscriptCache.self,
            from: plainCacheURL(for: job.recording.id),
            maximumBytes: Self.maximumPlainTranscriptCacheBytes)
        if let existing {
            guard existing.schemaVersion == 1,
                  existing.recordingID == job.recording.id,
                  existing.audioVersion <= job.recording.audioVersion else {
                return
            }
            if existing.audioVersion == job.recording.audioVersion,
               existing.modelID == job.transcriptionModelID,
               existing.language == "auto",
               existing.chunkCount == chunkCount,
               existing.segments.count > chunks.count {
                return
            }
        }
        let segments = chunks.map { chunk in
            AITranscriptSegment(start: chunk.startTime,
                text: chunk.result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let cache = AITranscriptCache(recordingID: job.recording.id,
            audioVersion: job.recording.audioVersion,
            modelID: job.transcriptionModelID,
            language: "auto",
            chunkCount: chunkCount,
            segments: segments)
        guard FileManager.default.fileExists(atPath: library.audioURL(for: job.recording).path) else {
            throw CancellationError()
        }
        try writeCache(cache, to: plainCacheURL(for: job.recording.id),
            maximumBytes: Self.maximumPlainTranscriptCacheBytes)
    }

    private func cacheURL(for id: UUID) -> URL {
        library.paths.directory(for: id).appending(path: "meeting-transcript-cache.json")
    }

    private func plainCacheURL(for id: UUID) -> URL {
        library.paths.directory(for: id).appending(path: "ai-transcript.json")
    }

    private func preservedActionStates(previous: MeetingIntelligenceDocument?, insights: MeetingInsights) -> [String: String] {
        guard let previous else { return [:] }
        let newActionIDs = Set(insights.actions.map(\.id))
        return previous.actionStates.filter { newActionIDs.contains($0.key) }
    }

    private func loadBounded<Value: Decodable>(_ type: Value.Type, from url: URL, maximumBytes: Int) throws -> Value {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MeetingIntelligenceValidationError(message: "Cached meeting analysis data is too large.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func writeCache<Value: Encodable>(_ value: Value, to url: URL, maximumBytes: Int) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw MeetingIntelligenceValidationError(message: "Cached meeting analysis data is too large.")
        }
        try data.write(to: url, options: .atomic)
    }

    private func stableID(prefix: String, parts: [String]) -> String {
        let source = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(source.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(digest)"
    }

    private func publishTimestamp(after previous: Int64?) -> Int64 {
        let now = millisecondsSince1970()
        guard let previous else { return now }
        guard previous < Self.maximumSafeTimestamp else { return Self.maximumSafeTimestamp }
        return min(Self.maximumSafeTimestamp, max(now, previous + 1))
    }

    private func millisecondsSince1970(date: Date = Date()) -> Int64 {
        min(Int64(date.timeIntervalSince1970 * 1_000), Self.maximumSafeTimestamp)
    }

    private func sanitizedMessage(_ error: any Error, redacting key: String) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return raw.replacingOccurrences(of: key, with: "[redacted]")
    }

    private func languageInstruction(_ language: String) -> String {
        switch language {
        case "en":
            return "Write all generated action, question, answer, decision, and topic text in English."
        case "source":
            return "Write generated text in the same language used by the cited transcript evidence."
        default:
            return "Write all generated action, question, answer, decision, and topic text in Korean."
        }
    }

    private static let maximumTimedCacheBytes = 4 * 1_024 * 1_024
    private static let maximumPlainTranscriptCacheBytes = 1 * 1_024 * 1_024
}

nonisolated struct DetailedTimedTranscriptCache: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let recordingID: UUID
    let audioVersion: Int
    let modelID: String
    let language: String
    let chunkCount: Int
    let chunks: [CachedTimedTranscriptChunk]

    init(recordingID: UUID, audioVersion: Int, modelID: String, language: String,
         chunkCount: Int, chunks: [TimedTranscriptChunk]) {
        self.recordingID = recordingID
        self.audioVersion = audioVersion
        self.modelID = modelID
        self.language = language
        self.chunkCount = chunkCount
        self.chunks = chunks.map(CachedTimedTranscriptChunk.init)
    }

    var timedChunks: [TimedTranscriptChunk] {
        chunks.map(\.timedChunk)
    }

    var totalTextByteCount: Int {
        chunks.reduce(0) { $0 + $1.result.text.utf8.count }
    }
}

nonisolated struct CachedTimedTranscriptChunk: Codable, Equatable, Sendable {
    let startTime: Double
    let result: CachedDetailedTranscriptionResult

    init(_ chunk: TimedTranscriptChunk) {
        startTime = chunk.startTime
        result = CachedDetailedTranscriptionResult(chunk.result)
    }

    var timedChunk: TimedTranscriptChunk {
        TimedTranscriptChunk(startTime: startTime, result: result.detailedResult)
    }
}

nonisolated struct CachedDetailedTranscriptionResult: Codable, Equatable, Sendable {
    let text: String
    let words: [CachedTimedTranscriptionWord]
    let segments: [CachedTimedTranscriptionSegment]

    init(_ result: DetailedTranscriptionResult) {
        text = result.text
        words = result.words.map(CachedTimedTranscriptionWord.init)
        segments = result.segments.map(CachedTimedTranscriptionSegment.init)
    }

    var detailedResult: DetailedTranscriptionResult {
        DetailedTranscriptionResult(text: text, words: words.map(\.timedWord),
            segments: segments.map(\.timedSegment))
    }
}

nonisolated struct CachedTimedTranscriptionWord: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?

    init(_ word: TimedTranscriptionWord) {
        text = word.text
        start = word.start
        end = word.end
        speakerID = word.speakerID
    }

    var timedWord: TimedTranscriptionWord {
        TimedTranscriptionWord(text: text, start: start, end: end, speakerID: speakerID)
    }
}

nonisolated struct CachedTimedTranscriptionSegment: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?

    init(_ segment: TimedTranscriptionSegment) {
        text = segment.text
        start = segment.start
        end = segment.end
        speakerID = segment.speakerID
    }

    var timedSegment: TimedTranscriptionSegment {
        TimedTranscriptionSegment(text: text, start: start, end: end, speakerID: speakerID)
    }
}

private extension Array where Element: Hashable {
    init(dictOrderedUnique values: [Element]) {
        var seen = Set<Element>()
        self = values.filter { seen.insert($0).inserted }
    }
}
