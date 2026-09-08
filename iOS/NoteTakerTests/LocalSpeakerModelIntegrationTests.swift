import Foundation
import XCTest
#if canImport(AudioPipeline)
import AudioPipeline
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

/// Opt-in test: public LibriSpeech audio only. Normal offline unit runs skip it.
@MainActor
final class LocalSpeakerModelIntegrationTests: XCTestCase {
    func testRealSpeakerModelsWithPublicHeldOutSpeech() async throws {
        let root = repositoryRoot.appending(path: "build/fluidaudio-validation")
        guard FileManager.default.fileExists(atPath: root.appending(path: "enable-model-validation").path) else {
            throw XCTSkip("Enable explicitly after downloading the attributed public fixture.")
        }
        #if os(iOS)
        let cacheData = try Data(contentsOf: root.appending(path: "mac-model-cache.json"))
        let cache = try JSONDecoder().decode([String: String].self, from: cacheData)
        let modelDirectory = URL(filePath: try XCTUnwrap(cache["path"]))
        let platform = "ios"
        #else
        let modelDirectory = LocalSpeakerBackend.defaultModelDirectory
        let platform = "mac"
        #endif
        let backend = LocalSpeakerBackend(modelDirectory: modelDirectory)
        let began = Date()
        try await backend.prepare()
        let prepareSeconds = Date().timeIntervalSince(began)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appending(path: LocalSpeakerBackend.segmentationModelFileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appending(path: LocalSpeakerBackend.embeddingModelFileName).path))
        let cachedBackend = LocalSpeakerBackend(modelDirectory: modelDirectory)
        let cached = try await cachedBackend.prepareCachedIfAvailable()
        XCTAssertTrue(cached, "Downloaded models must be discoverable without another network request.")
        #if os(macOS)
        try JSONEncoder().encode(["path": modelDirectory.path]).write(to: root.appending(path: "mac-model-cache.json"), options: .atomic)
        #endif

        // Register >10 seconds from one utterance and validate on a DIFFERENT utterance.
        let enrollment = try samples(root.appending(path: "decoded/6930-75918-0001.wav"))
        let positive = try samples(root.appending(path: "decoded/6930-75918-0000.wav"))
        let negative = try samples(root.appending(path: "decoded/1320-122617-0022.wav"))
        let inferenceStart = Date()
        let reference = try await backend.embedding(samples: enrollment, sampleRate: 16_000)
        let same = try await backend.embedding(samples: positive, sampleRate: 16_000)
        let other = try await backend.embedding(samples: negative, sampleRate: 16_000)
        XCTAssertEqual(reference.count, 256)
        XCTAssertTrue(reference.allSatisfy(\.isFinite))
        let profile = LocalVoiceProfile(modelID: backend.embeddingModelID, embedding: reference,
            enrolledAt: .now, sampleDuration: Double(enrollment.count) / 16_000)
        let policy = OwnerVoicePolicy()
        let positiveScore = cosine(reference, same)
        let negativeScore = cosine(reference, other)
        let positiveState = policy.classify(embedding: same, profile: profile, modelID: backend.embeddingModelID)
        let negativeState = policy.classify(embedding: other, profile: profile, modelID: backend.embeddingModelID)
        let embeddingSeconds = Date().timeIntervalSince(inferenceStart)
        let diarizeStart = Date()
        let result = try await backend.diarize(audioURL: root.appending(path: "librispeech_two_speaker_validation.wav"))
        let diarizeSeconds = Date().timeIntervalSince(diarizeStart)
        let first = dominant(result, ranges: [(0, 3.505), (4.005, 18.230)])
        let second = dominant(result, ranges: [(18.730, 22.585), (23.085, 30.900)])
        let profileStore = MeetingProfileStore(root: root.appending(path: "profile-\(UUID().uuidString)"))
        try profileStore.saveVoiceProfile(profile)
        let live = OwnerVoiceManager(profile: profileStore, backend: backend)
        await live.prepareModels()
        let livePositive = await liveClassification(live, samples: positive)
        let liveNegative = await liveClassification(live, samples: negative)
        live.stopListening()
        let report: [String: Any] = ["platform": platform, "model": backend.embeddingModelID,
            "prepareSeconds": prepareSeconds, "embeddingSeconds": embeddingSeconds,
            "diarizeSeconds": diarizeSeconds, "audioSeconds": 30.9,
            "positiveCosine": positiveScore, "negativeCosine": negativeScore,
            "livePositiveState": String(describing: livePositive), "liveNegativeState": String(describing: liveNegative),
            "positiveState": String(describing: positiveState), "negativeState": String(describing: negativeState),
            "firstSpeaker": first.id ?? "none", "secondSpeaker": second.id ?? "none",
            "firstCoveredSeconds": first.duration, "secondCoveredSeconds": second.duration,
            "speakerCount": result.speakers.count, "spanCount": result.spans.count]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appending(path: "model-validation-\(platform).json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(positiveScore, negativeScore + 0.2)
        XCTAssertEqual(positiveState, .owner)
        XCTAssertNotEqual(negativeState, .owner)
        XCTAssertEqual(livePositive, .owner)
        XCTAssertTrue(liveNegative == .other || liveNegative == .uncertain)
        XCTAssertNotNil(first.id)
        XCTAssertNotNil(second.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertGreaterThan(first.duration, 8)
        XCTAssertGreaterThan(second.duration, 5)
    }

    #if os(macOS)
    func testExplicitPreparationRepairsAnIncompleteModelCache() async throws {
        let root = repositoryRoot.appending(path: "build/fluidaudio-validation")
        guard FileManager.default.fileExists(atPath: root.appending(path: "enable-model-validation").path) else {
            throw XCTSkip("Public model download verification is explicitly opt-in.")
        }
        let cache = root.appending(path: "repair-\(UUID().uuidString)")
            .appending(path: LocalSpeakerBackend.diarizerRepoFolderName)
        for name in [LocalSpeakerBackend.segmentationModelFileName, LocalSpeakerBackend.embeddingModelFileName] {
            let bundle = cache.appending(path: name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([0, 1, 2]).write(to: bundle.appending(path: "coremldata.bin"))
        }
        let backend = LocalSpeakerBackend(modelDirectory: cache)
        do {
            let ready = try await backend.prepareCachedIfAvailable()
            XCTAssertFalse(ready)
        } catch { /* A corrupt local-only restore must not fetch or claim readiness. */ }
        try await backend.prepare()
        let restored = LocalSpeakerBackend(modelDirectory: cache)
        let ready = try await restored.prepareCachedIfAvailable()
        XCTAssertTrue(ready)
        try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
    }
    #endif

    private func liveClassification(_ manager: OwnerVoiceManager, samples: [Float]) async -> OwnerSpeechState {
        manager.stopListening()
        manager.startListening()
        for index in 0..<(samples.count / 8_000) {
            let start = index * 8_000
            manager.audioHandler(LiveAudioSamples(samples: Array(samples[start..<(start + 8_000)]),
                sampleRate: 16_000, startTime: Double(index) * 0.5))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if manager.state == .owner || manager.state == .other || manager.state == .uncertain { return manager.state }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return manager.state
    }

    private func samples(_ url: URL) throws -> [Float] {
        var output: [Float] = []
        try LocalSpeakerAudioFileWindows.readMonoWindows(from: url, targetSampleRate: 16_000) { window in
            output.append(contentsOf: window.samples)
        }
        return output
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norm = sqrt(lhs.reduce(0) { $0 + $1 * $1 } * rhs.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? dot / norm : 0
    }

    private func dominant(_ result: AcousticDiarization, ranges: [(Double, Double)]) -> (id: String?, duration: Double) {
        var durations: [String: Double] = [:]
        for span in result.spans where !span.isOverlap {
            guard let id = span.speakerID else { continue }
            for (start, end) in ranges { durations[id, default: 0] += max(0, min(end, span.end) - max(start, span.start)) }
        }
        let winner = durations.max { $0.value < $1.value }
        return (winner?.key, winner?.value ?? 0)
    }

    private var repositoryRoot: URL {
        #if os(iOS)
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #endif
    }
}
