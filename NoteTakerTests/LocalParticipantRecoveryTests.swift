import CryptoKit
import Foundation
import XCTest
@testable import NoteTaker

/// Explicit local diagnostic. Input paths and recovered documents are ignored build artifacts.
/// No keychain access, HTTP requests, recording writes, or model downloads are permitted.
@MainActor
final class LocalParticipantRecoveryTests: XCTestCase {
    func testCompletedTimedCachesWithCachedLocalSpeakerModels() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let diagnostics = repo.appending(path: "build/participant-recovery")
        guard FileManager.default.fileExists(atPath: diagnostics.appending(path: "enable-local-recovery").path) else {
            throw XCTSkip("Local recovery requires an explicit ignored input manifest.")
        }
        let inputs = try JSONDecoder().decode([String].self, from: Data(contentsOf: diagnostics.appending(path: "inputs.json")))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backend = CachedRecoverySpeakerBackend(backend: LocalSpeakerBackend())
        var reports: [[String: Any]] = []
        for sourcePath in inputs {
            let source = URL(filePath: sourcePath)
            let metadata = try Data(contentsOf: source.appending(path: "meta.json"))
            let recording = try decoder.decode(Recording.self, from: metadata)
            let cacheData = try Data(contentsOf: source.appending(path: "meeting-transcript-cache.json"))
            let cache = try decoder.decode(DetailedTimedTranscriptCache.self, from: cacheData)
            XCTAssertEqual(cache.chunks.count, cache.chunkCount)
            XCTAssertEqual(cache.recordingID, recording.id)
            let sourceNotes = try Data(contentsOf: source.appending(path: "meeting-notes.json"))
            let original = try decoder.decode(MeetingNotesDocument.self, from: sourceNotes)
            let root = FileManager.default.temporaryDirectory.appending(path: "participant-recovery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = LibraryPaths(libraryRoot: root, arguments: [])
            let library = await LibraryStore.open(paths: paths)
            try library.add(recording)
            try FileManager.default.createSymbolicLink(at: paths.audioURL(for: recording.id), withDestinationURL: source.appending(path: "audio.m4a"))
            try cacheData.write(to: paths.directory(for: recording.id).appending(path: "meeting-transcript-cache.json"))
            let client = OfflineRecoveryClient()
            let suite = "LocalParticipantRecovery.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let config = AIConfiguration(client: client, keyStore: InMemoryAPIKeyStore(), defaults: defaults)
            config.modelID = original.modelID
            config.transcriptionModelID = cache.modelID
            try config.saveKey("offline-diagnostic-key")
            let store = MeetingIntelligenceStore(library: library)
            let service = MeetingAnalysisService(library: library, configuration: config,
                profile: MeetingProfileStore(root: root), store: store, edits: MeetingEditLog(root: root),
                speakerBackend: backend, client: client, detailedClient: client, chunker: MeetingAudioChunker())
            let started = Date()
            let transcript = try await service.prepareNumberedTranscript(recording, transcriptionModelID: cache.modelID)
            let networkCalls = await client.calls
            XCTAssertEqual(networkCalls, 0)
            XCTAssertFalse(transcript.turns.isEmpty)
            XCTAssertTrue(transcript.turns.allSatisfy { $0.start < $0.end && $0.end <= recording.duration })
            let assigned = transcript.turns.filter { $0.speakerID != nil }
            XCTAssertFalse(assigned.isEmpty)
            let updated = MeetingNotesDocument(recordingID: original.recordingID, audioVersion: original.audioVersion,
                generatedAt: Date(timeIntervalSince1970: max(Date().timeIntervalSince1970.rounded(.down), original.generatedAt.timeIntervalSince1970.rounded(.down) + 1)),
                modelID: original.modelID, transcriptionModelID: original.transcriptionModelID,
                markdown: original.markdown, transcript: original.transcript, costUSD: original.costUSD,
                speakerTranscript: transcript, enhancement: original.enhancement)
            let artifacts = AIArtifactStore(paths: paths)
            try artifacts.saveDocument(updated, recording: recording)
            let reloaded = await artifacts.loadDocument(recording)
            XCTAssertNotNil(reloaded?.speakerTranscript)
            XCTAssertTrue(reloaded?.markdown == original.markdown)
            XCTAssertTrue(reloaded?.transcript == original.transcript)
            let output = diagnostics.appending(path: recording.id.uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for filename in ["meeting-notes.json", "meeting-intelligence.json"] {
                let data = try Data(contentsOf: paths.directory(for: recording.id).appending(path: filename))
                try data.write(to: output.appending(path: filename), options: .atomic)
            }
            reports.append(["recordingID": recording.id.uuidString, "audioVersion": recording.audioVersion,
                "duration": recording.duration, "networkCalls": networkCalls,
                "analysisSeconds": Date().timeIntervalSince(started), "turns": transcript.turns.count,
                "assignedTurns": assigned.count, "participantsWithSpeech": Set(assigned.compactMap(\.speakerID)).count,
                "sourceNotesSHA256": digest(sourceNotes), "sourceMetadataSHA256": digest(metadata),
                "sourceTimedCacheSHA256": digest(cacheData), "originalMinutesAndTextPreserved": true])
            let reportData = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            try reportData.write(to: diagnostics.appending(path: "report.json"), options: .atomic)
        }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private actor CachedRecoverySpeakerBackend: SpeakerAnalysisServing {
    nonisolated let embeddingModelID = localSpeakerBackendEmbeddingModelID
    private let backend: LocalSpeakerBackend
    init(backend: LocalSpeakerBackend) { self.backend = backend }
    func prepare() async throws {
        guard try await backend.prepareCachedIfAvailable() else {
            throw AIError(message: "Local diagnostic requires already cached speaker models.")
        }
    }
    func diarize(audioURL: URL) async throws -> AcousticDiarization { try await backend.diarize(audioURL: audioURL) }
    func embedding(samples: [Float], sampleRate: Double) async throws -> [Float] {
        try await backend.embedding(samples: samples, sampleRate: sampleRate)
    }
}

private actor OfflineRecoveryClient: OpenRouterServing, DetailedTranscriptionServing {
    private(set) var calls = 0
    func models() async throws -> [OpenRouterModel] { [] }
    func validateKey(_ apiKey: String) async throws { }
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        calls += 1; throw AIError(message: "Network calls are forbidden in local recovery.")
    }
    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String, language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1; throw AIError(message: "Network calls are forbidden in local recovery.")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        calls += 1; throw AIError(message: "Network calls are forbidden in local recovery.")
    }
}
