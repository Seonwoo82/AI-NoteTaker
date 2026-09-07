@preconcurrency import AVFAudio
import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Test("LibraryStore recovers UUID segment directories once and preserves invalid earlier runs")
func libraryStoreRecoversUUIDSegmentDirectoriesOnceAndPreservesInvalidEarlierRuns() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueRecoveryLibraryRoot(), arguments: [])
    let existing = Recording(
        id: try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        title: "Existing",
        createdAt: Date(timeIntervalSince1970: 100),
        duration: 2,
        mode: .micOnly
    )
    try JSONFile.save(existing, to: paths.metadataURL(for: existing.id))

    let twoRunID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    try writeRecoverySegment(paths.segmentURL(for: twoRunID, index: 0), frameCount: 4_800)
    try writeRecoverySegment(paths.segmentURL(for: twoRunID, index: 1), frameCount: 2_400)
    try setModificationDate(Date(timeIntervalSince1970: 200), for: paths.segmentURL(for: twoRunID, index: 0))
    try setModificationDate(Date(timeIntervalSince1970: 200), for: paths.segmentURL(for: twoRunID, index: 1))
    try Data("stale preview".utf8).write(to: paths.previewURL(for: twoRunID))

    let finalCorruptID = try #require(UUID(uuidString: "22222222-3333-4444-5555-666666666666"))
    try writeRecoverySegment(paths.segmentURL(for: finalCorruptID, index: 0), frameCount: 4_800)
    try setModificationDate(Date(timeIntervalSince1970: 300), for: paths.segmentURL(for: finalCorruptID, index: 0))
    try Data("not audio".utf8).write(to: paths.segmentURL(for: finalCorruptID, index: 1))

    let onlyCorruptID = try #require(UUID(uuidString: "33333333-4444-5555-6666-777777777777"))
    try FileManager.default.createDirectory(at: paths.segmentsDirectory(for: onlyCorruptID), withIntermediateDirectories: true)
    try Data("not audio".utf8).write(to: paths.segmentURL(for: onlyCorruptID, index: 0))

    let earlierCorruptID = try #require(UUID(uuidString: "44444444-5555-6666-7777-888888888888"))
    try FileManager.default.createDirectory(at: paths.segmentsDirectory(for: earlierCorruptID), withIntermediateDirectories: true)
    try Data("not audio".utf8).write(to: paths.segmentURL(for: earlierCorruptID, index: 0))
    try writeRecoverySegment(paths.segmentURL(for: earlierCorruptID, index: 1), frameCount: 4_800)

    let nonUUID = paths.recordingsRoot.appending(path: "scratch", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: nonUUID.appending(path: "segments", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try writeRecoverySegment(nonUUID.appending(path: "segments/000.m4a"), frameCount: 4_800)

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recordings.map(\.id) == [finalCorruptID, twoRunID, existing.id])
    for id in [twoRunID, finalCorruptID] {
        let recovered = try #require(store.recording(id: id))
        #expect(recovered.title == String(localized: "Recovered Recording"))
        #expect(recovered.mode == .micAndSystem)
        #expect(recovered.duration > 0)
        _ = try AVAudioFile(forReading: paths.audioURL(for: id))
        _ = try JSONFile.load(Recording.self, from: paths.metadataURL(for: id))
    }
    #expect(!FileManager.default.fileExists(atPath: paths.segmentURL(for: finalCorruptID, index: 1).path))
    #expect(!FileManager.default.fileExists(atPath: paths.segmentsDirectory(for: twoRunID).path))
    #expect(!FileManager.default.fileExists(atPath: paths.segmentsDirectory(for: finalCorruptID).path))
    #expect(!FileManager.default.fileExists(atPath: paths.metadataURL(for: onlyCorruptID).path))
    #expect(!FileManager.default.fileExists(atPath: paths.metadataURL(for: earlierCorruptID).path))
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: earlierCorruptID, index: 0).path))
    #expect(FileManager.default.fileExists(atPath: nonUUID.path))

    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.recordings.map(\.id) == [finalCorruptID, twoRunID, existing.id])
}

@MainActor
@Test("LibraryStore recovers metadata missing directories from existing final audio")
func libraryStoreRecoversMetadataMissingDirectoriesFromExistingFinalAudio() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueRecoveryLibraryRoot(), arguments: [])
    let finalOnlyID = try #require(UUID(uuidString: "55555555-6666-7777-8888-999999999999"))
    try writeRecoverySegment(paths.audioURL(for: finalOnlyID), frameCount: 4_800)
    try setModificationDate(Date(timeIntervalSince1970: 500), for: paths.audioURL(for: finalOnlyID))

    let finalWithSegmentsID = try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))
    try writeRecoverySegment(paths.audioURL(for: finalWithSegmentsID), frameCount: 2_400)
    try setModificationDate(Date(timeIntervalSince1970: 400), for: paths.audioURL(for: finalWithSegmentsID))
    try writeRecoverySegment(paths.segmentURL(for: finalWithSegmentsID, index: 0), frameCount: 9_600)
    try setModificationDate(Date(timeIntervalSince1970: 400), for: paths.segmentURL(for: finalWithSegmentsID, index: 0))

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recordings.map(\.id) == [finalOnlyID, finalWithSegmentsID])
    let finalOnly = try #require(store.recording(id: finalOnlyID))
    #expect(finalOnly.duration > 0)
    _ = try JSONFile.load(Recording.self, from: paths.metadataURL(for: finalOnlyID))
    _ = try AVAudioFile(forReading: paths.audioURL(for: finalOnlyID))

    let finalWithSegments = try #require(store.recording(id: finalWithSegmentsID))
    #expect(finalWithSegments.duration > 0.18)
    #expect(!FileManager.default.fileExists(atPath: paths.segmentsDirectory(for: finalWithSegmentsID).path))

    let reopened = await LibraryStore.open(paths: paths)
    #expect(reopened.recordings.map(\.id) == [finalOnlyID, finalWithSegmentsID])
}

@MainActor
@Test("LibraryStore replaces unreadable final audio only when readable segments exist")
func libraryStoreReplacesUnreadableFinalAudioOnlyWhenReadableSegmentsExist() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueRecoveryLibraryRoot(), arguments: [])
    let replaceableID = try #require(UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB"))
    try FileManager.default.createDirectory(at: paths.directory(for: replaceableID), withIntermediateDirectories: true)
    try Data("incomplete final".utf8).write(to: paths.audioURL(for: replaceableID))
    try writeRecoverySegment(paths.segmentURL(for: replaceableID, index: 0), frameCount: 4_800)

    let untouchedID = try #require(UUID(uuidString: "88888888-9999-AAAA-BBBB-CCCCCCCCCCCC"))
    try FileManager.default.createDirectory(at: paths.directory(for: untouchedID), withIntermediateDirectories: true)
    let unreadableBytes = Data("not recoverable".utf8)
    try unreadableBytes.write(to: paths.audioURL(for: untouchedID))

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recordings.map(\.id) == [replaceableID])
    _ = try AVAudioFile(forReading: paths.audioURL(for: replaceableID))
    _ = try JSONFile.load(Recording.self, from: paths.metadataURL(for: replaceableID))
    #expect(!FileManager.default.fileExists(atPath: paths.segmentsDirectory(for: replaceableID).path))
    #expect(!FileManager.default.fileExists(atPath: paths.metadataURL(for: untouchedID).path))
    #expect(try Data(contentsOf: paths.audioURL(for: untouchedID)) == unreadableBytes)
}

@MainActor
@Test("LibraryStore preserves incomplete segment sets when publishing readable final audio")
func libraryStorePreservesIncompleteSegmentSetsWhenPublishingReadableFinalAudio() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueRecoveryLibraryRoot(), arguments: [])
    let gapID = try #require(UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD"))
    try writeRecoverySegment(paths.audioURL(for: gapID), frameCount: 2_400)
    try writeRecoverySegment(paths.segmentURL(for: gapID, index: 0), frameCount: 2_400)
    try writeRecoverySegment(paths.segmentURL(for: gapID, index: 2), frameCount: 9_600)

    let middleCorruptID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999999"))
    try writeRecoverySegment(paths.audioURL(for: middleCorruptID), frameCount: 2_400)
    try writeRecoverySegment(paths.segmentURL(for: middleCorruptID, index: 0), frameCount: 2_400)
    try Data("not audio".utf8).write(to: paths.segmentURL(for: middleCorruptID, index: 1))
    try writeRecoverySegment(paths.segmentURL(for: middleCorruptID, index: 2), frameCount: 9_600)

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recording(id: gapID) != nil)
    #expect(store.recording(id: middleCorruptID) != nil)
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: gapID, index: 0).path))
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: gapID, index: 2).path))
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: middleCorruptID, index: 0).path))
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: middleCorruptID, index: 1).path))
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: middleCorruptID, index: 2).path))
}

@MainActor
@Test("LibraryStore preserves existing audio and segments when replacement cannot start")
func libraryStorePreservesExistingAudioAndSegmentsWhenReplacementCannotStart() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueRecoveryLibraryRoot(), arguments: [])
    let blockedID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-999999999999"))
    let directory = paths.directory(for: blockedID)
    try writeRecoverySegment(paths.audioURL(for: blockedID), frameCount: 2_400)
    let originalAudio = try Data(contentsOf: paths.audioURL(for: blockedID))
    try writeRecoverySegment(paths.segmentURL(for: blockedID, index: 0), frameCount: 9_600)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    let store = await LibraryStore.open(paths: paths)

    #expect(store.recording(id: blockedID) == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.metadataURL(for: blockedID).path))
    #expect(try Data(contentsOf: paths.audioURL(for: blockedID)) == originalAudio)
    #expect(FileManager.default.fileExists(atPath: paths.segmentURL(for: blockedID, index: 0).path))
}

private func uniqueRecoveryLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerRecordingRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeRecoverySegment(_ url: URL, frameCount: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
    else {
        throw RecoveryFixtureError()
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
    ).write(from: buffer)
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private struct RecoveryFixtureError: Error {}
