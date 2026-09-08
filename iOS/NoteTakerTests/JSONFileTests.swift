#if canImport(AudioPipeline)
import AudioPipeline
#endif
import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Test("JSONFile round trips recording metadata with ISO dates")
func jsonFileRoundTripsRecordingMetadataWithISODates() throws {
    let root = uniqueTemporaryDirectory()
    let url = root.appending(path: "nested/meta.json")
    let recording = Recording(
        id: try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")),
        title: "Fixed",
        createdAt: Date(timeIntervalSince1970: 0),
        duration: 90,
        mode: .micOnly
    )

    try JSONFile.save(recording, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"createdAt\":\"1970-01-01T00:00:00Z\""))

    let loaded = try JSONFile.load(Recording.self, from: url)
    #expect(loaded == recording)
}

@Test("JSONFile writes sorted keys exactly")
func jsonFileWritesSortedKeysExactly() throws {
    struct Fixture: Encodable {
        let z: Int
        let a: Int
    }

    let url = uniqueTemporaryDirectory().appending(path: "fixture.json")
    try JSONFile.save(Fixture(z: 2, a: 1), to: url)

    let data = try Data(contentsOf: url)
    #expect(String(data: data, encoding: .utf8) == #"{"a":1,"z":2}"#)
}

@Test("JSONFile load throws for malformed JSON")
func jsonFileLoadThrowsForMalformedJSON() throws {
    let root = uniqueTemporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "broken.json")
    try Data(#"{"a":"#.utf8).write(to: url)

    #expect(throws: (any Error).self) {
        _ = try JSONFile.load([String: Int].self, from: url)
    }
}

@Test("JSONFile save creates parent directories")
func jsonFileSaveCreatesParentDirectories() throws {
    struct Fixture: Encodable {
        let a: Int
    }

    let url = uniqueTemporaryDirectory().appending(path: "one/two/fixture.json")
    try JSONFile.save(Fixture(a: 1), to: url)

    #expect(FileManager.default.fileExists(atPath: url.path))
}

private func uniqueTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}
