import FluidAudio
import Foundation
import XCTest
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
final class OfflineSpeakerBackendTests: XCTestCase {
    func testTimelineOrdersSpeakersByFirstSpeechAndDropsInvalidSpans() {
        let timeline = OfflineSpeakerTimeline(segments: [
            segment("S1", 8, 10), segment("S2", 1, 4), segment("unused", 5, 5),
            segment("", 11, 12), segment("invalid", .nan, 15), segment("S1", 12, 14),
        ])
        XCTAssertEqual(timeline.speakerIDs, ["1", "2"])
        XCTAssertEqual(timeline.spans.map(\.speakerID), ["1", "2", "2"])
        XCTAssertEqual(timeline.spans.map(\.start), [1, 8, 12])
    }

    func testRepresentativeClipsExcludeOverlapAndStayIndependentAndBounded() {
        let timeline = OfflineSpeakerTimeline(segments: [
            segment("a", 0, 32), segment("b", 8, 12), segment("c", 40, 42),
        ])
        let clips = timeline.representativeClips()
        let first = clips.filter { $0.speakerID == "1" }
        XCTAssertEqual(first.map(\.start), [12, 22, 0])
        XCTAssertEqual(first.map(\.end), [22, 32, 8])
        XCTAssertFalse(clips.contains { $0.speakerID == "2" || $0.speakerID == "3" },
            "An overlapping-only or sub-three-second voice must not supply owner evidence.")
        let overlap = timeline.spans.filter(\.isOverlap)
        XCTAssertEqual(overlap, [AcousticSpeakerSpan(start: 8, end: 12, speakerID: nil, isOverlap: true)])
        XCTAssertEqual(timeline.speakerIDs, ["1", "2", "3"],
            "Insufficient owner evidence must not erase real speaker segments.")
    }

    func testDuplicateSameSpeakerSpansCannotDuplicateRepresentativeEvidence() {
        let timeline = OfflineSpeakerTimeline(segments: [segment("a", 0, 8), segment("a", 4, 12)])
        let clips = timeline.representativeClips()
        XCTAssertEqual(clips, [OfflineSpeakerClip(speakerID: "1", start: 0, end: 10)])
        XCTAssertFalse(timeline.spans.contains(where: \.isOverlap))
    }

    func testClipCollectionAcrossPCMWindowsDoesNotRepeatOrLoseSamples() {
        let clip = OfflineSpeakerClip(speakerID: "1", start: 1.5, end: 3.5)
        let first = LocalSpeakerPCMWindow(samples: [0, 1, 2, 3], sampleRate: 2, startTime: 0)
        let second = LocalSpeakerPCMWindow(samples: [4, 5, 6, 7], sampleRate: 2, startTime: 2)
        let later = LocalSpeakerPCMWindow(samples: [8, 9, 10, 11], sampleRate: 2, startTime: 4)
        XCTAssertEqual(Array(clip.samples(in: first)) + Array(clip.samples(in: second)), [3, 4, 5, 6])
        XCTAssertTrue(clip.samples(in: later).isEmpty)
    }

    func testRepresentativeAverageNormalizesEachClipAndRejectsInvalidEvidence() {
        let embedding = OfflineSpeakerTimeline.averageEmbeddings([
            [3, 0], [0, 4], [.nan, 1], [0, 0], [1],
        ], dimension: 2)
        XCTAssertEqual(embedding.count, 2)
        XCTAssertEqual(embedding[0], 0.70710677, accuracy: 0.000001)
        XCTAssertEqual(embedding[1], 0.70710677, accuracy: 0.000001)
        XCTAssertTrue(OfflineSpeakerTimeline.averageEmbeddings([[0, 0], [.infinity, 0]], dimension: 2).isEmpty)
    }

    func testMissingOfflineCacheNeverCreatesFilesOrFallsBackToStreamingBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-speaker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OfflineSpeakerModelCache(directory: root.appending(path: "offline-diarizer"))
        XCTAssertNil(try cache.loadCached())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let streaming = root.appending(path: "speaker-diarization")
        try FileManager.default.createDirectory(at: streaming.appending(path: "wespeaker_v2.mlmodelc"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: streaming.appending(path: "pyannote_segmentation.mlmodelc"),
            withIntermediateDirectories: true)
        XCTAssertNil(try cache.loadCached())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: streaming.path))
    }

    func testMissingStreamingCacheReportsNotReadyWithoutCreatingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "missing-voice-cache-\(UUID())")
        let backend = LocalSpeakerBackend(modelDirectory: root.appending(path: "speaker-diarization"),
            offlineModelDirectory: root.appending(path: "offline-diarizer"))
        let ready = try await backend.prepareCachedIfAvailable()
        XCTAssertFalse(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testStreamingOnlyCacheKeepsLiveRecognitionReady() async throws {
        let streaming = try cachedStreamingFixture()
        let offline = FileManager.default.temporaryDirectory.appending(path: "absent-offline-cache-\(UUID())")
        let backend = LocalSpeakerBackend(modelDirectory: streaming, offlineModelDirectory: offline)
        let ready = try await backend.prepareCachedIfAvailable()
        XCTAssertTrue(ready, "Existing voice profiles must remain usable before offline models are downloaded.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: offline.path))
        do {
            _ = try await backend.diarize(audioURL: offline.appending(path: "not-read.m4a"))
            XCTFail("Diarization still requires its separate offline models.")
        } catch is AIError { }
    }

    func testBrokenOfflineCacheCannotBlockStreamingCacheReadiness() async throws {
        let streaming = try cachedStreamingFixture()
        let offline = FileManager.default.temporaryDirectory.appending(path: "broken-offline-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: offline) }
        let repo = offline.appending(path: Repo.diarizer.folderName)
        for name in ModelNames.OfflineDiarizer.requiredModels where name.hasSuffix(".mlmodelc") {
            try FileManager.default.createDirectory(at: repo.appending(path: name), withIntermediateDirectories: true)
        }
        let parameters = repo.appending(path: ModelNames.OfflineDiarizer.pldaParameters)
        try Data("{}".utf8).write(to: parameters)
        let backend = LocalSpeakerBackend(modelDirectory: streaming, offlineModelDirectory: offline)
        let ready = try await backend.prepareCachedIfAvailable()
        XCTAssertTrue(ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parameters.path),
            "A best-effort restore must not purge or repair the broken cache.")
    }

    func testCachedPLDARejectsMalformedOrNonfiniteParameters() throws {
        let values: [Float] = [1, 2]
        let encoded = values.withUnsafeBytes { Data($0).base64EncodedString() }
        let valid = try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": encoded]]])
        XCTAssertEqual(try OfflineSpeakerModelCache.decodePLDAPsi(valid), [1, 2])
        XCTAssertThrowsError(try OfflineSpeakerModelCache.decodePLDAPsi(Data("{}".utf8)))
        let malformed = try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": "AQ=="]]])
        XCTAssertThrowsError(try OfflineSpeakerModelCache.decodePLDAPsi(malformed))
        let invalid: [Float] = [.nan]
        let invalidEncoded = invalid.withUnsafeBytes { Data($0).base64EncodedString() }
        let nonfinite = try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": invalidEncoded]]])
        XCTAssertThrowsError(try OfflineSpeakerModelCache.decodePLDAPsi(nonfinite))
    }

    private func segment(_ speakerID: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: speakerID, embedding: [], startTimeSeconds: start,
            endTimeSeconds: end, qualityScore: 1)
    }

    private func cachedStreamingFixture() throws -> URL {
        let directory = LocalSpeakerBackend.defaultModelDirectory
        guard [LocalSpeakerBackend.segmentationModelFileName, LocalSpeakerBackend.embeddingModelFileName]
            .allSatisfy({ FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }) else {
            throw XCTSkip("Local model-cache regression needs the already-installed public streaming models; it never downloads.")
        }
        return directory
    }
}
