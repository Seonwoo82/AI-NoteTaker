import Testing
@testable import NoteTaker

@MainActor
@Test("fake recorder has deterministic transitions without microphone access")
func uiTestingRecorderTransitionsWithoutTCC() async throws {
    let recorder = FakeRecorderEngine()

    #expect(recorder.state == .idle)

    try await recorder.start()
    #expect(recorder.state == .recording)

    try await recorder.pause()
    #expect(recorder.state == .paused)

    try await recorder.resume()
    #expect(recorder.state == .recording)

    try await recorder.stop()
    #expect(recorder.state == .stopped)
}
