import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
        let partialOutputBudget: Int
        var enhancementBase: MeetingNotesDocument? = nil
        var instructions: String? = nil
        var participantsBase: MeetingNotesDocument? = nil
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
    @ObservationIgnored var onDocumentSaved: ((UUID) -> Void)?
    @ObservationIgnored var speakerTranscriptProvider: (@MainActor (Recording, String) async throws -> MeetingTranscript)?
    private var enhancementPreviews: [UUID: MeetingNotesEnhancementPreview] = [:]
    private var transcriptNotices: [UUID: String] = [:]

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

    func reload(_ recording: Recording) async {
        let snapshotToken = tokens[recording.id]
        let snapshotDocument = documents[recording.id]
        guard !progress(for: recording.id).isRunning else { return }
        guard let current = library.recording(id: recording.id),
              current.audioVersion == recording.audioVersion else {
            guard reloadSnapshotIsStillCurrent(
                id: recording.id,
                token: snapshotToken,
                document: snapshotDocument
            ) else { return }
            documents[recording.id] = nil
            if progress(for: recording.id) == .completed { states[recording.id] = .idle }
            return
        }
        let audioVersion = current.audioVersion
        let loaded = await artifacts.loadDocument(current)
        guard reloadSnapshotIsStillCurrent(
            id: recording.id,
            token: snapshotToken,
            document: snapshotDocument,
            audioVersion: audioVersion
        ) else { return }
        guard let loaded else {
            documents[recording.id] = nil
            if progress(for: recording.id) == .completed { states[recording.id] = .idle }
            return
        }
        if let existing = documents[recording.id],
           existing.audioVersion == loaded.audioVersion,
           existing.generatedAt > loaded.generatedAt {
            return
        }
        documents[recording.id] = loaded
        if !progress(for: recording.id).isRunning { states[recording.id] = .completed }
    }

    private func reloadSnapshotIsStillCurrent(
        id: UUID,
        token: UUID?,
        document: MeetingNotesDocument?,
        audioVersion: Int? = nil
    ) -> Bool {
        guard tokens[id] == token,
              documents[id] == document,
              !progress(for: id).isRunning else { return false }
        guard let audioVersion else { return true }
        return library.recording(id: id)?.audioVersion == audioVersion
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
            let budget = MeetingCompletionBudget(model: model, modelID: configuration.modelID)
            let job = Job(token: UUID(), recording: current, key: key, modelID: configuration.modelID,
                          transcriptionModelID: configuration.transcriptionModelID,
                          language: configuration.outputLanguage,
                          inputBudget: budget.inputBytes,
                          outputBudget: budget.outputTokens,
                          partialOutputBudget: budget.partialOutputTokens)
            enhancementPreviews[recording.id] = nil
            tokens[recording.id] = job.token
            states[recording.id] = .queued
            queue.append(job)
            startNext()
        } catch {
            states[recording.id] = .failed("저장된 API 키를 읽지 못했습니다. 설정에서 키를 다시 저장해 주세요.")
        }
    }

    func enhancementPreview(for id: UUID) -> MeetingNotesEnhancementPreview? { enhancementPreviews[id] }
    func transcriptNotice(for id: UUID) -> String? { transcriptNotices[id] }

    func enhance(_ recording: Recording, instructions: String) {
        let feedback = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShuttingDown, !progress(for: recording.id).isRunning else { return }
        guard !feedback.isEmpty, feedback.utf8.count <= 8_000 else {
            states[recording.id] = .failed("수정할 이름이나 보완할 맥락을 8,000바이트 이내로 입력해 주세요.")
            return
        }
        guard configuration.isEnhancementConfigured, let base = document(for: recording.id) else {
            states[recording.id] = .failed("기존 회의록과 AI 보완 모델 설정을 확인해 주세요.")
            return
        }
        enqueueRevision(recording, base: base, instructions: feedback)
    }

    func identifyParticipants(_ recording: Recording) {
        guard !isShuttingDown, !progress(for: recording.id).isRunning,
              let base = document(for: recording.id), speakerTranscriptProvider != nil else { return }
        guard configuration.isConfigured else {
            transcriptNotices[recording.id] = "참여자를 구분하려면 AI 설정에서 전사 모델과 API 키를 확인해 주세요. 기존 회의록은 유지됩니다."
            states[recording.id] = .completed
            return
        }
        enqueueRevision(recording, base: base, instructions: nil)
    }

    private func enqueueRevision(_ recording: Recording, base: MeetingNotesDocument, instructions: String?) {
        guard let current = library.recording(id: recording.id), current.deletedAt == nil,
              current.audioVersion == recording.audioVersion else { return }
        do {
            let modelID = instructions == nil ? configuration.modelID : configuration.effectiveEnhancementModelID
            let model = configuration.models.first { $0.id == modelID }
            let budget = MeetingCompletionBudget(model: model, modelID: modelID)
            let job = Job(token: UUID(), recording: current, key: try configuration.apiKey(), modelID: modelID,
                transcriptionModelID: base.transcriptionModelID, language: configuration.outputLanguage,
                inputBudget: budget.inputBytes, outputBudget: budget.outputTokens,
                partialOutputBudget: budget.partialOutputTokens,
                enhancementBase: instructions == nil ? nil : base, instructions: instructions,
                participantsBase: instructions == nil ? base : nil)
            try requireCurrentBase(base, recording: current)
            enhancementPreviews[recording.id] = nil
            tokens[recording.id] = job.token
            states[recording.id] = .queued
            queue.append(job)
            startNext()
        } catch {
            let message = (error as? AIError)?.message ?? "작업을 시작하지 못했습니다. 설정과 저장 공간을 확인해 주세요."
            if instructions == nil {
                transcriptNotices[recording.id] = "참여자 구분을 시작하지 못했습니다. 기존 회의록은 유지됩니다.\n\(message)"
                states[recording.id] = .completed
            } else { states[recording.id] = .failed(message) }
        }
    }

    func discardEnhancement(_ id: UUID) {
        enhancementPreviews[id] = nil
    }

    func applyEnhancement(_ recording: Recording) throws {
        guard !isShuttingDown, !progress(for: recording.id).isRunning,
              let preview = enhancementPreviews[recording.id] else {
            throw AIError(message: "적용할 AI 보완안이 없습니다. 다시 보완해 주세요.")
        }
        try requireCurrentBase(preview.original, recording: recording)
        let original = preview.original
        let updated = MeetingNotesDocument(recordingID: original.recordingID, audioVersion: original.audioVersion,
            generatedAt: nextRevisionDate(after: original.generatedAt), modelID: original.modelID,
            transcriptionModelID: original.transcriptionModelID, markdown: preview.markdown,
            transcript: original.transcript, costUSD: combinedCost(original.costUSD, preview.costUSD),
            speakerTranscript: original.speakerTranscript,
            enhancement: MeetingNotesEnhancement(modelID: preview.modelID, instructions: preview.instructions))
        try artifacts.saveDocument(updated, recording: recording)
        documents[recording.id] = updated
        enhancementPreviews[recording.id] = nil
        states[recording.id] = .completed
        onDocumentSaved?(recording.id)
    }

    private func requireCurrentBase(_ base: MeetingNotesDocument, recording: Recording) throws {
        guard let current = library.recording(id: recording.id), current.deletedAt == nil,
              current.audioVersion == base.audioVersion, recording.audioVersion == base.audioVersion,
              let visible = document(for: recording.id) else { throw staleRevisionError() }
        let disk = try? JSONFile.load(MeetingNotesDocument.self,
            from: library.paths.directory(for: recording.id).appending(path: "meeting-notes.json"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let disk,
              try encoder.encode(base) == encoder.encode(visible),
              try encoder.encode(base) == encoder.encode(disk) else { throw staleRevisionError() }
    }

    private func staleRevisionError() -> AIError {
        AIError(message: "회의록이 다른 작업이나 기기에서 변경되었습니다. 최신 회의록을 다시 열고 보완해 주세요.")
    }

    private func nextRevisionDate(after date: Date) -> Date {
        Date(timeIntervalSince1970: max(floor(Date().timeIntervalSince1970), floor(date.timeIntervalSince1970) + 1))
    }

    private func combinedCost(_ original: Double?, _ additional: Double?) -> Double? {
        let values = [original, additional].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    func cancel(_ id: UUID) {
        enhancementPreviews[id] = nil
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
        enhancementPreviews.removeAll()
        for id in Array(states.keys) where progress(for: id).isRunning { cancel(id) }
    }

#if os(macOS)
    @discardableResult
    func copyMarkdown(for id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        guard let markdown = document(for: id)?.markdown, !markdown.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }
#elseif canImport(UIKit)
    @discardableResult
    func copyMarkdown(for id: UUID, pasteboard: UIPasteboard = .general) -> Bool {
        guard let markdown = document(for: id)?.markdown, !markdown.isEmpty else { return false }
        pasteboard.string = markdown
        return pasteboard.string == markdown
    }
#else
    @discardableResult
    func copyMarkdown(for id: UUID) -> Bool { false }
#endif

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
            try check(job)
            if let base = job.enhancementBase, let instructions = job.instructions {
                try await runEnhancement(job, base: base, instructions: instructions)
                return
            }
            if let base = job.participantsBase {
                try await runParticipantIdentification(job, base: base)
                return
            }
            var speakerTranscript = document(for: job.recording.id)?.speakerTranscript
            if let existing = speakerTranscript,
               !ParticipantTranscriptionPolicy.accepts(actual: existing.transcriptionModelID, requested: job.transcriptionModelID) {
                speakerTranscript = nil
            }
            let timingModel = ParticipantTranscriptionPolicy.modelID(for: job.transcriptionModelID)
            if timingModel != job.transcriptionModelID, speakerTranscript == nil {
                transcriptNotices[job.recording.id] = "기본 전사문은 선택한 모델로 작성했습니다. 참여자 구분을 누르면 시간 정보를 지원하는 Whisper로 참여자 전사를 추가합니다."
            }
            if timingModel == job.transcriptionModelID, let speakerTranscriptProvider {
                do {
                    let prepared = try await speakerTranscriptProvider(job.recording, ParticipantTranscriptionPolicy.modelID(for: job.transcriptionModelID))
                    try check(job)
                    try prepared.validate(duration: job.recording.duration)
                    guard prepared.recordingID == job.recording.id, prepared.audioVersion == job.recording.audioVersion,
                          ParticipantTranscriptionPolicy.accepts(actual: prepared.transcriptionModelID, requested: job.transcriptionModelID) else {
                        throw AIError(message: "참여자 전사문이 현재 녹음과 일치하지 않습니다.")
                    }
                    speakerTranscript = prepared
                    transcriptNotices[job.recording.id] = nil
                } catch {
                    try check(job)
                    if error is CancellationError { throw error }
                    transcriptNotices[job.recording.id] = "참여자 구분을 완료하지 못해 기본 전사문을 표시합니다. 참여자 구분 버튼으로 다시 시도할 수 있어요."
                }
            }
            let transcript: String
            if let speakerTranscript, speakerTranscript.transcriptionModelID == job.transcriptionModelID {
                transcript = NumberedTranscript.text(speakerTranscript)
            } else if let existingTranscript = reusableCompletedTranscript(for: job) {
                transcript = existingTranscript
            } else {
                let audioURL = library.audioURL(for: job.recording)
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
                transcript = cache.segments.filter { !$0.text.isEmpty }
                    .map { "[\(DurationFormat.list($0.start))]\n\($0.text)" }.joined(separator: "\n\n")
            }
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
                        model: job.modelID, apiKey: job.key, maxTokens: job.partialOutputBudget)
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
                generatedAt: .now, modelID: job.modelID,
                transcriptionModelID: job.transcriptionModelID,
                markdown: markdown, transcript: transcript, costUSD: hasReportedCost ? cost : nil,
                speakerTranscript: speakerTranscript)
            // No await here: job validity, atomic publication, and observable
            // completion form one MainActor transaction.
            try artifacts.saveDocument(doc, recording: job.recording)
            documents[job.recording.id] = doc
            states[job.recording.id] = .completed
            onDocumentSaved?(job.recording.id)
        } catch {
            guard tokens[job.recording.id] == job.token else { return }
            if error is CancellationError || Task.isCancelled {
                states[job.recording.id] = .cancelled
            } else {
                let message = (error as? AIError)?.message ?? "회의록 처리 또는 저장에 실패했습니다. 연결과 저장 공간을 확인하고 다시 시도해 주세요."
                let safeMessage = message.replacingOccurrences(of: job.key, with: "[redacted]")
                if job.participantsBase != nil {
                    transcriptNotices[job.recording.id] = "참여자 구분에 실패했습니다. 기존 회의록과 전사문은 유지됩니다.\n\(safeMessage)"
                    states[job.recording.id] = .completed
                } else {
                    states[job.recording.id] = .failed(safeMessage)
                }
            }
        }
    }

    private func runEnhancement(_ job: Job, base: MeetingNotesDocument, instructions: String) async throws {
        try requireCurrentBase(base, recording: job.recording)
        let parts = try MeetingEnhancementPrompts.parts(markdown: base.markdown, transcript: base.transcript,
            instructions: instructions, maximumBytes: job.inputBudget)
        var revised: [String] = []
        var cost: Double?
        for (index, part) in parts.enumerated() {
            try check(job)
            states[job.recording.id] = .summarizing(completed: index, total: parts.count)
            let response = try await client.complete(
                system: MeetingEnhancementPrompts.system(language: job.language, partial: parts.count > 1),
                user: part, model: job.modelID, apiKey: job.key, maxTokens: job.outputBudget)
            try check(job)
            let markdown = MeetingNotesPrompts.normalize(response.text)
            guard !markdown.isEmpty else { throw AIError(message: "모델이 빈 보완안을 반환했습니다. 기존 회의록은 유지됩니다.") }
            revised.append(markdown)
            cost = combinedCost(cost, response.costUSD)
        }
        try requireCurrentBase(base, recording: job.recording)
        let markdown = revised.joined(separator: "\n\n")
        guard markdown.utf8.count <= 1_000_000 else { throw AIError(message: "보완안이 너무 큽니다. 수정 지시를 나누어 다시 시도해 주세요.") }
        enhancementPreviews[job.recording.id] = MeetingNotesEnhancementPreview(id: UUID(), original: base,
            markdown: markdown, modelID: job.modelID, instructions: instructions, costUSD: cost)
        states[job.recording.id] = .completed
    }

    private func runParticipantIdentification(_ job: Job, base: MeetingNotesDocument) async throws {
        guard let speakerTranscriptProvider else { throw AIError(message: "참여자 구분을 사용할 수 없습니다.") }
        try requireCurrentBase(base, recording: job.recording)
        states[job.recording.id] = .transcribing(completed: 0, total: 1)
        let transcript = try await speakerTranscriptProvider(job.recording, ParticipantTranscriptionPolicy.modelID(for: job.transcriptionModelID))
        try check(job)
        try transcript.validate(duration: job.recording.duration)
        guard transcript.recordingID == job.recording.id, transcript.audioVersion == job.recording.audioVersion,
              ParticipantTranscriptionPolicy.accepts(actual: transcript.transcriptionModelID, requested: job.transcriptionModelID) else {
            throw AIError(message: "참여자 전사문이 현재 녹음과 일치하지 않습니다.")
        }
        try requireCurrentBase(base, recording: job.recording)
        let updated = MeetingNotesDocument(recordingID: base.recordingID, audioVersion: base.audioVersion,
            generatedAt: nextRevisionDate(after: base.generatedAt), modelID: base.modelID,
            transcriptionModelID: base.transcriptionModelID, markdown: base.markdown, transcript: base.transcript,
            costUSD: base.costUSD, speakerTranscript: transcript, enhancement: base.enhancement)
        try artifacts.saveDocument(updated, recording: job.recording)
        documents[job.recording.id] = updated
        transcriptNotices[job.recording.id] = nil
        states[job.recording.id] = .completed
        onDocumentSaved?(job.recording.id)
    }

    private func reusableCompletedTranscript(for job: Job) -> String? {
        guard let document = document(for: job.recording.id),
              document.recordingID == job.recording.id,
              document.audioVersion == job.recording.audioVersion,
              document.transcriptionModelID == job.transcriptionModelID else { return nil }
        let transcript = document.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }
}
