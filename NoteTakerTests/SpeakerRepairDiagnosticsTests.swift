import Foundation
import XCTest
import AVFAudio
import AudioPipeline
@testable import NoteTaker

/// Explicit local-data diagnostic. Inputs and outputs stay in ignored build/.
@MainActor
final class SpeakerRepairDiagnosticsTests: XCTestCase {
    func testRepairSavedMeetingWithoutCloudOrLostEdits() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/speaker-repair")
        let input = root.appending(path: "input")
        guard FileManager.default.fileExists(atPath: input.appending(path: "recording/meeting-intelligence.json").path) else {
            throw XCTSkip("Requires the explicit original meeting snapshot.")
        }
        let original = try JSONFile.load(MeetingIntelligenceDocument.self, from: input.appending(path: "recording/meeting-intelligence.json"))
        let destination = root.appending(path: "repaired-library-\(UUID())")
        let recordings = destination.appending(path: "Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: input.appending(path: "recording"),
            to: recordings.appending(path: original.recordingID.uuidString))
        for name in ["local-voice-profile.json", "meeting-profile.json", "meeting-edits.json"] {
            try FileManager.default.copyItem(at: input.appending(path: name), to: destination.appending(path: name))
        }
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: destination, arguments: []))
        let recording = try XCTUnwrap(library.recording(id: original.recordingID))
        let profile = MeetingProfileStore(root: destination)
        let store = MeetingIntelligenceStore(library: library)
        let edits = MeetingEditLog(root: destination)
        let client = RepairCloudGuard()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpeakerRepair.\(UUID())"))
        let configuration = AIConfiguration(client: client, keyStore: InMemoryAPIKeyStore(), defaults: defaults)
        XCTAssertFalse(configuration.hasAPIKey)
        let backend = LocalSpeakerBackend(offlineModelDirectory: root.appending(path: "offline-models"))
        let service = MeetingAnalysisService(library: library, configuration: configuration,
            profile: profile, store: store, edits: edits, speakerBackend: backend,
            client: client, detailedClient: client)
        await service.refreshOwnerAttribution(recording: recording)
        let loaded = await store.load(recording)
        let repaired = try XCTUnwrap(loaded)
        let resolved = try repaired.resolved(edits: edits.edits(for: recording.id, audioVersion: recording.audioVersion))
        XCTAssertEqual(repaired.transcript.speakers.count, 2)
        XCTAssertEqual(Set(repaired.transcript.speakers.map(\.id)), ["speaker-1", "speaker-2"])
        XCTAssertEqual(repaired.transcript.speakers.first { $0.id == "speaker-1" }?.isOwner, true)
        XCTAssertEqual(repaired.transcript.speakers.first { $0.id == "speaker-2" }?.isOwner, false)
        XCTAssertEqual(resolved.speakerIdentities.count, 2)
        XCTAssertEqual(resolved.unresolvedEditCount, 0)
        XCTAssertEqual(repaired.transcript.turns.map(\.id), original.transcript.turns.map(\.id))
        XCTAssertEqual(repaired.transcript.turns.map(\.text), original.transcript.turns.map(\.text))
        XCTAssertEqual(repaired.transcript.turns.map(\.start), original.transcript.turns.map(\.start))
        XCTAssertEqual(repaired.transcript.turns.map(\.end), original.transcript.turns.map(\.end))
        XCTAssertEqual(repaired.insights, original.insights)
        XCTAssertEqual(repaired.actionStates, original.actionStates)
        let cloudCalls = await client.calls
        XCTAssertEqual(cloudCalls, 0)
        let resolvedOwnerIDs = Set(resolved.transcript.speakers.filter(\.isOwner).map(\.id))
        let confirmedTurn = try XCTUnwrap(resolved.transcript.turns.first { $0.id == "turn-bf61d72fb7328b56" })
        XCTAssertTrue(confirmedTurn.speakerID.map(resolvedOwnerIDs.contains) ?? false)
        for name in ["audio.m4a", "meeting-notes.json", "meeting-transcript-cache.json"] {
            XCTAssertEqual(try Data(contentsOf: input.appending(path: "recording/\(name)")),
                try Data(contentsOf: recordings.appending(path: "\(recording.id.uuidString)/\(name)")))
        }
        let report: [String: Any] = ["libraryPath": destination.path,
            "recordingID": recording.id.uuidString, "speakerCount": repaired.transcript.speakers.count,
            "displayIdentityCount": resolved.speakerIdentities.count, "unresolvedEdits": resolved.unresolvedEditCount,
            "turnCounts": Dictionary(grouping: resolved.transcript.turns, by: { $0.speakerID ?? "unknown" }).mapValues(\.count),
            "ownerIDs": Array(resolvedOwnerIDs), "cloudCalls": cloudCalls,
            "textAndTimingPreserved": true, "notesAndAudioPreserved": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "repair-result.json"), options: .atomic)
        print("SAVED_MEETING_REPAIR: \(repaired.transcript.speakers.count) speakers, \(resolved.speakerIdentities.count) identities, \(resolved.unresolvedEditCount) unresolved edits")
    }

    func testRealTimeOwnerRecognitionWithStoredVoice() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/speaker-repair")
        let audioURL = root.appending(path: "input/recording/mono.wav")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw XCTSkip("Requires the explicit private recording snapshot.")
        }
        let voice = try JSONFile.load(LocalVoiceProfile.self, from: root.appending(path: "input/local-voice-profile.json"))
        let store = MeetingProfileStore(root: root.appending(path: "live-probe-\(UUID())"))
        try store.saveVoiceProfile(voice)
        let backend = LocalSpeakerBackend(offlineModelDirectory: root.appending(path: "offline-models"))
        let manager = OwnerVoiceManager(profile: store, backend: backend)
        await manager.prepareCachedModelsIfAvailable()
        XCTAssertTrue(manager.presentation.modelsReady)
        let file = try AVAudioFile(forReading: audioURL)
        var report: [String: [String: Int]] = [:]
        // Separate held-out stretches in the two acoustic groups; the source
        // owner was independently identified by the user's original manual edit.
        for (label, start) in [("confirmedOwner", 104.55), ("otherParticipant", 23.18)] {
            manager.stopListening()
            manager.startListening()
            var states: [String: Int] = [:]
            for index in 0..<20 {
                file.framePosition = AVAudioFramePosition((start + Double(index) * 0.5) * 16_000)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
                try file.read(into: buffer, frameCount: 8_000)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                manager.audioHandler(LiveAudioSamples(samples: samples, sampleRate: 16_000, startTime: Double(index) * 0.5))
                try await Task.sleep(for: .milliseconds(500))
                states[String(describing: manager.state), default: 0] += 1
            }
            manager.stopListening()
            report[label] = states
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "live-owner-result.json"), options: .atomic)
        XCTAssertGreaterThan(report["confirmedOwner"]?["owner"] ?? 0, 0)
        XCTAssertEqual(report["otherParticipant"]?["owner"] ?? 0, 0)
        XCTAssertGreaterThan(report["otherParticipant"]?["other"] ?? 0, 0)
        print("LIVE_OWNER_RESULT: \(report)")
    }

    func testHeldOutOwnerEmbeddingWindows() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/speaker-repair")
        guard FileManager.default.fileExists(atPath: root.appending(path: "offline-default.json").path) else {
            throw XCTSkip("Requires completed local offline diagnostic.")
        }
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "offline-default.json"))) as! [String: Any]
        let spans = data["segments"] as! [[String: Any]]
        let profile = try JSONFile.load(LocalVoiceProfile.self, from: root.appending(path: "input/local-voice-profile.json"))
        let backend = LocalSpeakerBackend(offlineModelDirectory: root.appending(path: "offline-models"))
        let available = try await backend.prepareCachedIfAvailable()
        XCTAssertTrue(available)
        guard available else { return }
        let file = try AVAudioFile(forReading: root.appending(path: "input/recording/mono.wav"))
        var report: [[String: Any]] = []
        for id in ["S1", "S2"] {
            let candidates = spans.filter { span in
                guard span["speakerID"] as? String == id, let start = span["start"] as? Double,
                      let end = span["end"] as? Double, end - start >= 3.2 else { return false }
                return !spans.contains { other in
                    other["speakerID"] as? String != id && (other["start"] as! Double) < end && (other["end"] as! Double) > start
                }
            }.sorted { ($0["end"] as! Double) - ($0["start"] as! Double) > ($1["end"] as! Double) - ($1["start"] as! Double) }.prefix(12)
            for span in candidates {
                let start = (span["start"] as! Double) + 0.05
                let end = span["end"] as! Double
                let durations = Set([3.0, min(5, end - start - 0.05), min(6, end - start - 0.05), min(10, end - start - 0.05)]).sorted()
                for duration in durations {
                    let count = AVAudioFrameCount(duration * file.processingFormat.sampleRate)
                    file.framePosition = AVAudioFramePosition(start * file.processingFormat.sampleRate)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                    try file.read(into: buffer, frameCount: count)
                    let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    let raw = try await backend.embedding(samples: values, sampleRate: file.processingFormat.sampleRate)
                    let normalized = try VoiceEnrollmentSignal.prepared16kSamples(values)
                    let normalizedEmbedding = try await backend.embedding(samples: normalized, sampleRate: 16_000)
                    var row: [String: Any] = ["speakerID": id, "start": start, "duration": duration,
                        "rawCosine": cosine(raw, profile.embedding),
                        "normalizedCosine": cosine(normalizedEmbedding, profile.embedding),
                        "rms": VoiceEnrollmentSignal.measure(values, sampleRate: 16_000).rms]
                    if duration >= 4, let masked = try? await backend.enrollmentEmbedding(samples: values, sampleRate: 16_000) {
                        row["maskedCosine"] = cosine(masked, profile.embedding)
                    }
                    report.append(row)
                }
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "owner-windows.json"), options: .atomic)
        print("OWNER_WINDOWS: evaluated \(report.count) labeled held-out intervals")
    }

    func testCurrentDiarizationOnSelectedRecording() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/speaker-repair")
        let input = root.appending(path: "input")
        guard FileManager.default.fileExists(atPath: input.appending(path: "recording/audio.m4a").path) else {
            throw XCTSkip("Requires an explicit local recording snapshot in build/speaker-repair/input.")
        }
        let recording = try JSONFile.load(Recording.self, from: input.appending(path: "recording/meta.json"))
        let profile = try JSONFile.load(LocalVoiceProfile.self, from: input.appending(path: "local-voice-profile.json"))
        let cache = try JSONFile.load(DetailedTimedTranscriptCache.self, from: input.appending(path: "recording/meeting-transcript-cache.json"))
        let backend = LocalSpeakerBackend(offlineModelDirectory: root.appending(path: "offline-models"))
        let cached = try await backend.prepareCachedIfAvailable()
        XCTAssertTrue(cached, "This diagnostic must use existing models without a network request.")
        guard cached else { return }
        let start = Date()
        let result = try await backend.diarize(audioURL: input.appending(path: "recording/audio.m4a"))
        let transcript = try TranscriptAssembler.assemble(recordingID: recording.id,
            audioVersion: recording.audioVersion, transcriptionModelID: cache.modelID,
            chunks: cache.timedChunks, diarization: result, ownerVoice: profile,
            embeddingModelID: backend.embeddingModelID, duration: recording.duration)
        var seconds: [String: Double] = [:]
        for span in result.spans {
            seconds[span.speakerID ?? "unknown", default: 0] += span.end - span.start
        }
        let counts = Dictionary(grouping: transcript.turns, by: { $0.speakerID ?? "unknown" }).mapValues(\.count)
        let speakers: [[String: Any]] = result.speakers.map { speaker in
            ["id": speaker.id, "spanSeconds": seconds[speaker.id] ?? 0,
             "ownerCosine": cosine(speaker.embedding, profile.embedding),
             "embedding": speaker.embedding]
        }
        var pairs: [[String: Any]] = []
        for (index, left) in result.speakers.enumerated() {
            for right in result.speakers.dropFirst(index + 1) {
                pairs.append(["a": left.id, "b": right.id, "cosine": cosine(left.embedding, right.embedding)])
            }
        }
        let report: [String: Any] = ["recordingID": recording.id.uuidString,
            "elapsedSeconds": Date().timeIntervalSince(start), "duration": recording.duration,
            "speakers": speakers, "pairs": pairs, "turnCounts": counts,
            "spans": result.spans.map { ["start": $0.start, "end": $0.end,
                "speakerID": $0.speakerID as Any? ?? NSNull(), "isOverlap": $0.isOverlap] }]
        let outputName = FileManager.default.fileExists(atPath: root.appending(path: "baseline.json").path)
            ? "current-production" : "baseline"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "\(outputName).json"), options: .atomic)
        try JSONFile.save(transcript, to: root.appending(path: "\(outputName)-transcript.json"))
        print("SPEAKER_DIAGNOSTIC: \(result.speakers.count) acoustic groups; assigned turn counts \(counts)")
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let aa = a.reduce(0.0) { $0 + Double($1) * Double($1) }
        let bb = b.reduce(0.0) { $0 + Double($1) * Double($1) }
        return aa > 0 && bb > 0 ? dot / sqrt(aa * bb) : 0
    }
}

private actor RepairCloudGuard: OpenRouterServing, DetailedTranscriptionServing {
    private(set) var calls = 0
    func models() async throws -> [OpenRouterModel] { calls += 1; throw AIError(message: "Unexpected cloud catalog request") }
    func validateKey(_ apiKey: String) async throws { calls += 1; throw AIError(message: "Unexpected cloud key request") }
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        calls += 1; throw AIError(message: "Unexpected cloud transcription")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        calls += 1; throw AIError(message: "Unexpected cloud completion")
    }
    func transcribeDetailed(audio: Data, format: String, model: String, apiKey: String, language: String?, prompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1; throw AIError(message: "Unexpected cloud detailed transcription")
    }
}
