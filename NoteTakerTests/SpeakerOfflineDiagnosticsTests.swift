import FluidAudio
import Foundation
import XCTest
@testable import NoteTaker

/// Opt-in local experiment; public models download into an isolated ignored cache.
/// No production data is rewritten and no owner decision uses the offline embeddings.
@MainActor
final class SpeakerOfflineDiagnosticsTests: XCTestCase {
    func testOfflineDiarizationOnSelectedRecording() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/speaker-repair")
        let input = root.appending(path: "input")
        let audioURL = input.appending(path: "recording/audio.m4a")
        guard FileManager.default.fileExists(atPath: root.appending(path: "offline-enabled").path),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            throw XCTSkip("Requires an explicit local snapshot and build/speaker-repair/offline-enabled.")
        }
        for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"] {
            guard ProcessInfo.processInfo.environment[name] == nil else {
                throw XCTSkip("Run this public-model diagnostic without HuggingFace token environment variables.")
            }
        }
        let recording = try JSONFile.load(Recording.self, from: input.appending(path: "recording/meta.json"))
        let profile = try JSONFile.load(LocalVoiceProfile.self, from: input.appending(path: "local-voice-profile.json"))
        let modelCache = root.appending(path: "offline-models")
        try FileManager.default.createDirectory(at: modelCache, withIntermediateDirectories: true)
        let start = Date()
        try write(["stage": "loading-public-models", "modelCache": modelCache.path],
            to: root.appending(path: "offline-progress.json"))
        print("SPEAKER_OFFLINE: loading public models into isolated cache")
        // Do not call prepareModels(), whose fallback purges its repository directory.
        let models = try await OfflineDiarizerModels.load(from: modelCache)
        let modelLoadSeconds = Date().timeIntervalSince(start)

        var samples: [Float] = []
        try LocalSpeakerAudioFileWindows.readMonoWindows(from: audioURL, targetSampleRate: 16_000) { window in
            samples.append(contentsOf: window.samples)
        }
        let decodedDuration = Double(samples.count) / 16_000
        XCTAssertEqual(decodedDuration, recording.duration, accuracy: 0.1)
        var config = OfflineDiarizerConfig.default
        config.postProcessing.exclusiveSegments = false
        config.exposeChunkEmbeddings = true
        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        try write(["stage": "extracting", "modelLoadSeconds": modelLoadSeconds,
            "decodedDuration": decodedDuration], to: root.appending(path: "offline-progress.json"))
        let inferenceStart = Date()
        let prepared = try await manager.prepare(audio: samples) { completed, total in
            if completed == 1 || completed % 20 == 0 || completed == total {
                print("SPEAKER_OFFLINE: segmentation \(completed)/\(total)")
            }
        }
        let preparationSeconds = Date().timeIntervalSince(inferenceStart)
        XCTAssertGreaterThan(prepared.embeddingCount, 0)
        let result = try manager.cluster(prepared)
        try save(result: result, name: "offline-default", root: root, recordingID: recording.id,
            duration: decodedDuration, profile: profile, modelLoadSeconds: modelLoadSeconds,
            preparationSeconds: preparationSeconds, prepared: prepared)

        // Reuse identical segmentation/embedding inference. This one bounded variant
        // checks the SDK's documented arbitrary assignment of zero-vote short speech.
        config.zeroVoteReembed.enabled = true
        let reembedManager = OfflineDiarizerManager(config: config)
        reembedManager.initialize(models: models)
        let reembedded = try reembedManager.cluster(prepared)
        try save(result: reembedded, name: "offline-zero-vote", root: root, recordingID: recording.id,
            duration: decodedDuration, profile: profile, modelLoadSeconds: modelLoadSeconds,
            preparationSeconds: preparationSeconds, prepared: prepared)
        try write(["stage": "complete", "elapsedSeconds": Date().timeIntervalSince(start),
            "defaultSpeakerCount": Set(result.segments.map(\.speakerId)).count,
            "zeroVoteSpeakerCount": Set(reembedded.segments.map(\.speakerId)).count],
            to: root.appending(path: "offline-progress.json"))
    }

    private func save(result: DiarizationResult, name: String, root: URL, recordingID: UUID,
        duration: Double, profile: LocalVoiceProfile, modelLoadSeconds: Double,
        preparationSeconds: Double, prepared: PreparedDiarization) throws {
        XCTAssertFalse(result.segments.isEmpty)
        let chunks = try XCTUnwrap(result.chunkEmbeddings)
        let database = try XCTUnwrap(result.speakerDatabase)
        let bySpeaker = Dictionary(grouping: result.segments, by: \.speakerId)
        let speakers: [[String: Any]] = database.keys.sorted().map { id in
            let embedding = database[id] ?? []
            let segments = bySpeaker[id] ?? []
            let assigned = chunks.filter { $0.speakerId == id }
            return ["id": id, "segmentCount": segments.count,
                "spanSeconds": segments.reduce(0.0) { $0 + Double($1.durationSeconds) },
                "embedding": embedding.map { finite(Double($0)) },
                "ownerCosineDiagnosticOnly": cosine(embedding, profile.embedding),
                "chunkCount": assigned.count,
                "chunkOwnerCosinesDiagnosticOnly": assigned.map { cosine($0.embedding256, profile.embedding) }]
        }
        var pairs: [[String: Any]] = []
        let ids = database.keys.sorted()
        for (index, left) in ids.enumerated() {
            for right in ids.dropFirst(index + 1) {
                pairs.append(["a": left, "b": right,
                    "cosine": cosine(database[left] ?? [], database[right] ?? [])])
            }
        }
        let invalidSegmentCount = result.segments.filter {
            !$0.startTimeSeconds.isFinite || !$0.endTimeSeconds.isFinite || $0.durationSeconds <= 0
                || $0.startTimeSeconds < -0.1 || Double($0.endTimeSeconds) > duration + 0.1
        }.count
        let invalidEmbeddingCount = chunks.filter {
            $0.embedding256.count != 256 || !$0.embedding256.allSatisfy(\.isFinite)
        }.count
        var report: [String: Any] = ["recordingID": recordingID.uuidString, "duration": duration,
            "pipeline": "FluidAudio 0.15.6 offline community-1", "speakerCountConstrained": false,
            "exclusiveSegments": false, "zeroVoteReembedEnabled": name == "offline-zero-vote",
            "ownerProfileModelID": profile.modelID, "ownerEmbeddingCompatibility": "unverified-diagnostic-only",
            "modelLoadSeconds": modelLoadSeconds, "preparationSeconds": preparationSeconds,
            "preparedEmbeddingCount": prepared.embeddingCount,
            "segmentationChunkCount": prepared.segmentationChunkCount,
            "speakerCount": bySpeaker.count, "speakers": speakers, "pairs": pairs,
            "invalidSegmentCount": invalidSegmentCount, "invalidEmbeddingCount": invalidEmbeddingCount,
            "speechUnionSeconds": unionSeconds(result.segments),
            "segments": result.segments.map { ["speakerID": $0.speakerId,
                "start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds),
                "quality": finite(Double($0.qualityScore))] }]
        let baselineURL = root.appending(path: "baseline-transcript.json")
        if FileManager.default.fileExists(atPath: baselineURL.path),
           let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as? [String: Any],
           let turns = baseline["turns"] as? [[String: Any]] {
            report["baselineTurnAssignments"] = turns.compactMap { turn -> [String: Any]? in
                guard let start = turn["start"] as? Double, let end = turn["end"] as? Double else { return nil }
                let overlaps = overlapSeconds(start: start, end: end, segments: result.segments)
                return ["start": start, "end": end,
                    "baselineSpeakerID": turn["speakerID"] ?? "unknown",
                    "offlineSpeakerSeconds": overlaps,
                    "dominantOfflineSpeakerID": overlaps.max(by: { $0.value < $1.value })?.key ?? "unknown"]
            }
        }
        try write(report, to: root.appending(path: "\(name).json"))
        let chunkReport: [[String: Any]] = chunks.map { chunk in
            ["speakerID": chunk.speakerId, "chunkIndex": chunk.chunkIndex,
                "speakerIndex": chunk.speakerIndex, "start": chunk.startTimeSeconds,
                "end": chunk.endTimeSeconds, "embedding256": chunk.embedding256.map { finite(Double($0)) },
                "rho128": chunk.rho128.map(finite),
                "ownerCosineDiagnosticOnly": cosine(chunk.embedding256, profile.embedding)]
        }
        try write(chunkReport, to: root.appending(path: "\(name)-embeddings.json"))
        XCTAssertEqual(invalidSegmentCount, 0)
        XCTAssertEqual(invalidEmbeddingCount, 0)
        print("SPEAKER_OFFLINE: \(name) detected \(bySpeaker.count) speakers, \(result.segments.count) segments, \(chunks.count) embeddings")
    }

    private func overlapSeconds(start: Double, end: Double, segments: [TimedSpeakerSegment]) -> [String: Double] {
        var output: [String: Double] = [:]
        for segment in segments {
            let overlap = max(0, min(end, Double(segment.endTimeSeconds)) - max(start, Double(segment.startTimeSeconds)))
            if overlap > 0 { output[segment.speakerId, default: 0] += overlap }
        }
        return output
    }

    private func unionSeconds(_ segments: [TimedSpeakerSegment]) -> Double {
        var end = 0.0
        var seconds = 0.0
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let start = Double(segment.startTimeSeconds)
            let nextEnd = Double(segment.endTimeSeconds)
            seconds += max(0, nextEnd - max(start, end))
            end = max(end, nextEnd)
        }
        return seconds
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let aa = lhs.reduce(0.0) { $0 + Double($1) * Double($1) }
        let bb = rhs.reduce(0.0) { $0 + Double($1) * Double($1) }
        let score = aa > 0 && bb > 0 ? dot / sqrt(aa * bb) : 0
        return score.isFinite ? score : 0
    }

    private func finite(_ value: Double) -> Any { value.isFinite ? value : NSNull() }

    private func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}
