import AudioPipeline
import Foundation
import Testing
@testable import NoteTaker

@Test("legacy recording metadata decodes additive defaults")
func legacyRecordingMetadataDecodesAdditiveDefaults() throws {
    let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let json = """
    {
      "schemaVersion": 1,
      "id": "\(id.uuidString)",
      "title": "Legacy Capture",
      "createdAt": "2026-09-02T01:02:03Z",
      "duration": 42.5,
      "mode": "micAndSystem"
    }
    """.data(using: .utf8)
    let data = try #require(json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recording = try decoder.decode(Recording.self, from: data)

    #expect(recording.schemaVersion == 1)
    #expect(recording.id == id)
    #expect(recording.title == "Legacy Capture")
    #expect(recording.duration == 42.5)
    #expect(recording.mode == .micAndSystem)
    #expect(recording.isFavorite == false)
    #expect(recording.deletedAt == nil)
    #expect(recording.audioVersion == 1)
    #expect(recording.hasTranscript == false)
    #expect(recording.transcriptionError == nil)
    #expect(recording.playbackRate == 1.0)
    #expect(recording.skipsSilence == false)
    #expect(recording.enhances == false)
    #expect(recording.warnings == [])
}

@Test("recording capture mode round trips through codable metadata")
func recordingCaptureModeRoundTripsThroughCodableMetadata() throws {
    let recording = Recording(
        id: try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        title: "System Audio",
        createdAt: Date(timeIntervalSince1970: 1_788_310_923),
        duration: 12.25,
        mode: CaptureMode.systemOnly
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(recording)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Recording.self, from: data)

    #expect(decoded == recording)
    #expect(decoded.mode == .systemOnly)
}
