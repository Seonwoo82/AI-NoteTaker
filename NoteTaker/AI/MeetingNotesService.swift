import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MeetingNotesService {
    private struct Job {
        let token: UUID
        let recording: Recording
        let key: String
        let modelID: String
        let transcriptionModelID: String
        let language: String
        let inputBudget: Int
        let outputBudget: Int
    }

    private let configuration: AIConfiguration
    private let client: any OpenRouterServing
    private let chunker: any MeetingAudioChunking
    private let library: LibraryStore
    private let artifacts: AIArtifactStore
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var tokens: [UUID: UUID] = [:]
    private var isShuttingDown = false
    private var documents: [UUID: MeetingNotesDocument] = [:]
    private var states: [UUID: MeetingNotesProgress] = [:]

    init(configuration: AIConfiguration, client: any OpenRouterServing,
         chunker: any MeetingAudioChunking, library: LibraryStore) {
        self.configuration = configuration
        self.client = client
        self.chunker = chunker
        self.library = library
        self.artifacts = AIArtifactStore(paths: library.paths)
    }

    func document(for id: UUID) -> MeetingNotesDocument? {
        guard let recording = library.recording(id: id),
              let document = documents[id], document.audioVersion == recording.audioVersion else { return nil }
        return document
    }

    func progress(for id: UUID) -> MeetingNotesProgress { states[id] ?? .idle }

    func load(_ recording: Recording) async {
        guard document(for: recording.id) == nil else { return }
        if let loaded = await artifacts.loadDocument(recording), document(for: recording.id) == nil,
           library.recording(id: recording.id)?.audioVersion == loaded.audioVersion {
            documents[recording.id] = loaded
            if !progress(for: recording.id).isRunning { states[recording.id] = .completed }
        }
    }

    func recordingDidFinish(_ recording: Recording) {
        guard configuration.autoGenerate, configuration.isConfigured, !isShuttingDown else { return }
        generate(recording)
    }

    func generate(_ recording: Recording, regenerate: Bool = false) {
        guard !isShuttingDown, !progress(for: recording.id).isRunning,
              let current = library.recording(id: recording.id), current.deletedAt == nil,
              current.audioVersion == recording.audioVersion else { return }
        if document(for: recording.id) != nil && !regenerate { return }
        guard configuration.isConfigured else {
            states[recording.id] = .failed("설정에서 OpenRouter API 키와 AI 모델을 선택해 주세요.")
            return
        }
        do {
            let key = try configuration.apiKey()
            let model = configuration.models.first { $0.id == configuration.modelID }
            let context = model?.contextLength ?? 8_192
            let outputBudget = min(8_192, max(2_048, context / 4))
            let job = Job(token: UUID(), recording: current, key: key, modelID: configuration.modelID,
                          transcriptionModelID: configuration.transcriptionModelID,
                          language: configuration.outputLanguage,
                          inputBudget: max(1_024, min(24_000, context - outputBudget - 2_048)), outputBudget: outputBudget)
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
        queue.removeAll { $0.recording.id == id }
        if activeID == id { activeTask?.cancel() }
        if progress(for: id).isRunning { states[id] = .cancelled }
    }

    func prepareForTermination() {
        isShuttingDown = true
        credentialsDidChange()
    }

    func credentialsDidChange() {
        for id in Array(states.keys) where progress(for: id).isRunning { cancel(id) }
    }

    @discardableResult
    func copyMarkdown(for id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        guard let markdown = document(for: id)?.markdown, !markdown.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }

    private func startNext() {
        guard activeTask == nil, !queue.isEmpty, !isShuttingDown else { return }
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

    private func check(_ job: Job) throws {
        try Task.checkCancellation()
        guard tokens[job.recording.id] == job.token,
              let current = library.recording(id: job.recording.id), current.deletedAt == nil,
              current.audioVersion == job.recording.audioVersion else { throw CancellationError() }
    }

    private func run(_ job: Job) async {
        var cost: Double = 0
        var hasReportedCost = false
        var modelCalls = 0
        func reserveModelCall() throws {
            guard modelCalls < 240 else { throw AIError(message: "한 녹음의 AI 처리 요청 한도에 도달했습니다. 녹음을 더 짧게 나누어 처리해 주세요.") }
            modelCalls += 1
        }
        func account(_ result: AITextResponse) {
            if let amount = result.costUSD, amount.isFinite, amount >= 0 {
                cost += amount
                hasReportedCost = true
            }
        }
        do {
            try check(job)
            await load(job.recording)
            let audioURL = library.paths.audioURL(for: job.recording.id)
            let count = try await chunker.chunkCount(for: audioURL)
            guard count > 0 else { throw AIError(message: "녹음 파일에 처리할 오디오가 없습니다.") }
            guard count <= 180, job.recording.duration <= 6 * 60 * 60 else {
                throw AIError(message: "AI 회의록은 한 번에 최대 6시간까지 처리합니다. 녹음을 나누어 처리해 주세요.")
            }
            try check(job)
            var cache = await artifacts.loadTranscript(job.recording, modelID: job.transcriptionModelID,
                language: "auto", chunkCount: count) ?? AITranscriptCache(
                    recordingID: job.recording.id, audioVersion: job.recording.audioVersion,
                    modelID: job.transcriptionModelID, language: "auto", chunkCount: count, segments: [])
            for index in cache.segments.count..<count {
                try check(job)
                states[job.recording.id] = .transcribing(completed: index, total: count)
                let chunk = try await chunker.chunk(for: audioURL, index: index)
                try check(job)
                try reserveModelCall()
                let response = try await client.transcribe(audio: chunk.data, format: chunk.format,
                    model: job.transcriptionModelID, apiKey: job.key,
                    language: nil)
                try check(job)
                account(response)
                cache.segments.append(AITranscriptSegment(start: chunk.startTime,
                    text: response.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                guard cache.segments.reduce(0, { $0 + $1.text.utf8.count }) <= 1_000_000 else {
                    throw AIError(message: "전사문이 처리 한도를 초과했습니다. 녹음을 나누어 처리해 주세요.")
                }
                try artifacts.saveTranscript(cache, recording: job.recording)
            }
            try check(job)
            let transcript = cache.segments.filter { !$0.text.isEmpty }
                .map { "[\(DurationFormat.list($0.start))]\n\($0.text)" }.joined(separator: "\n\n")
            guard !transcript.isEmpty else { throw AIError(message: "인식된 대화가 없습니다. 음성이 포함된 녹음인지 확인해 주세요.") }
            var source = transcript
            var round = 0
            while source.utf8.count > job.inputBudget {
                guard round < 6 else { throw AIError(message: "회의 내용이 모델의 처리 범위를 초과합니다. 더 큰 문맥을 지원하는 모델을 선택해 주세요.") }
                round += 1
                let parts = MeetingNotesPrompts.split(source, maximumBytes: job.inputBudget)
                guard parts.count <= 32 else {
                    throw AIError(message: "현재 모델로 처리할 요약 구간이 너무 많습니다. 더 큰 문맥의 모델을 선택하거나 녹음을 나누어 주세요.")
                }
                var condensed: [String] = []
                for (index, part) in parts.enumerated() {
                    try check(job)
                    states[job.recording.id] = .summarizing(completed: index, total: parts.count + 1)
                    try reserveModelCall()
                    let response = try await client.complete(system: MeetingNotesPrompts.system(language: job.language, partial: true),
                        user: "Meeting excerpt \(index + 1)/\(parts.count):\n<transcript>\n\(part)\n</transcript>",
                        model: job.modelID, apiKey: job.key, maxTokens: 512)
                    try check(job)
                    account(response)
                    condensed.append(response.text)
                }
                let next = condensed.joined(separator: "\n\n---\n\n")
                guard next.utf8.count < source.utf8.count else {
                    throw AIError(message: "모델이 긴 대화를 충분히 압축하지 못했습니다. 다른 모델로 다시 생성해 주세요.")
                }
                source = next
            }
            states[job.recording.id] = .summarizing(completed: 0, total: 1)
            try reserveModelCall()
            let response = try await client.complete(system: MeetingNotesPrompts.system(language: job.language, partial: false),
                user: "<transcript>\n\(source)\n</transcript>", model: job.modelID, apiKey: job.key, maxTokens: job.outputBudget)
            try check(job)
            account(response)
            let markdown = MeetingNotesPrompts.normalize(response.text)
            guard !markdown.isEmpty else { throw AIError(message: "모델이 빈 회의록을 반환했습니다. 다시 시도해 주세요.") }
            let doc = MeetingNotesDocument(recordingID: job.recording.id, audioVersion: job.recording.audioVersion,
                generatedAt: .now, modelID: job.modelID, transcriptionModelID: job.transcriptionModelID,
                markdown: markdown, transcript: transcript, costUSD: hasReportedCost ? cost : nil)
            // No await here: job validity, atomic publication, and observable
            // completion form one MainActor transaction.
            try artifacts.saveDocument(doc, recording: job.recording)
            documents[job.recording.id] = doc
            states[job.recording.id] = .completed
        } catch {
            guard tokens[job.recording.id] == job.token else { return }
            if error is CancellationError || Task.isCancelled {
                states[job.recording.id] = .cancelled
            } else {
                let message = (error as? AIError)?.message ?? "회의록 처리 또는 저장에 실패했습니다. 연결과 저장 공간을 확인하고 다시 시도해 주세요."
                states[job.recording.id] = .failed(message.replacingOccurrences(of: job.key, with: "[redacted]"))
            }
        }
    }
}
