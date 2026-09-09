import Foundation

nonisolated struct AITranscriptSegment: Codable, Sendable {
    let start: TimeInterval
    let text: String
}

nonisolated struct AITranscriptCache: Codable, Sendable {
    var schemaVersion = 1
    let recordingID: UUID
    let audioVersion: Int
    let modelID: String
    let language: String
    let chunkCount: Int
    var segments: [AITranscriptSegment]
}

actor AIArtifactStore {
    private let paths: LibraryPaths
    init(paths: LibraryPaths) { self.paths = paths }

    func loadDocument(_ recording: Recording) -> MeetingNotesDocument? {
        guard let doc = try? JSONFile.load(MeetingNotesDocument.self, from: documentURL(recording.id)),
              doc.schemaVersion == 1, doc.recordingID == recording.id,
              doc.audioVersion == recording.audioVersion else { return nil }
        if let transcript = doc.speakerTranscript {
            guard transcript.recordingID == doc.recordingID, transcript.audioVersion == doc.audioVersion,
                  ParticipantTranscriptionPolicy.accepts(actual: transcript.transcriptionModelID, requested: doc.transcriptionModelID),
                  (try? transcript.validate(duration: recording.duration)) != nil else { return nil }
        }
        if let enhancement = doc.enhancement {
            guard !enhancement.modelID.isEmpty, enhancement.modelID.utf8.count <= 512,
                  !enhancement.instructions.isEmpty, enhancement.instructions.utf8.count <= 8_000 else { return nil }
        }
        return doc
    }

    func loadTranscript(_ recording: Recording, modelID: String, language: String, chunkCount: Int) -> AITranscriptCache? {
        guard let cache = try? JSONFile.load(AITranscriptCache.self, from: transcriptURL(recording.id)),
              cache.schemaVersion == 1, cache.recordingID == recording.id,
              cache.audioVersion == recording.audioVersion, cache.modelID == modelID,
              cache.language == language, cache.chunkCount == chunkCount,
              cache.segments.count <= chunkCount else { return nil }
        return cache
    }

    @MainActor func saveDocument(_ document: MeetingNotesDocument, recording: Recording) throws {
        try save(document, to: documentURL(recording.id), recording: recording)
    }

    @MainActor func saveTranscript(_ cache: AITranscriptCache, recording: Recording) throws {
        try save(cache, to: transcriptURL(recording.id), recording: recording)
    }

    @MainActor private func save<Value: Encodable>(_ value: Value, to url: URL, recording: Recording) throws {
        try Task.checkCancellation()
        let current = try JSONFile.load(Recording.self, from: paths.metadataURL(for: recording.id))
        guard current.id == recording.id, current.audioVersion == recording.audioVersion, current.deletedAt == nil else {
            throw CancellationError()
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw AIError(message: "회의 문서가 동기화 가능한 크기를 초과했습니다. 내용을 나누어 처리해 주세요.")
        }
        try Task.checkCancellation()
        // Commit on the service's MainActor with no suspension between job
        // validation, file publication and visible state updates. Cancellation
        // and library deletion cannot interleave with this small atomic write.
        // Never create a directory here: a concurrent deletion must stay deleted.
        try data.write(to: url, options: .atomic)
    }

    nonisolated private func documentURL(_ id: UUID) -> URL { paths.directory(for: id).appending(path: "meeting-notes.json") }
    nonisolated private func transcriptURL(_ id: UUID) -> URL { paths.directory(for: id).appending(path: "ai-transcript.json") }
}
