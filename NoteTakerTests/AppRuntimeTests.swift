import Foundation
import Testing
@testable import NoteTaker

@MainActor
@Suite
struct AppRuntimeTests {
    @Test("Concurrent window and menu initialization share a single recording session")
    func concurrentLoadsShareContainer() async throws {
        let runtime = AppRuntime(
            services: .uiTesting(),
            paths: LibraryPaths(libraryRoot: FileManager.default.temporaryDirectory
                .appending(path: "NoteTakerRuntimeTests-\(UUID())"), arguments: [])
        )
        let first = Task { await runtime.load() }
        let second = Task { await runtime.load() }
        let window = await first.value
        let menu = await second.value
        #expect(window.session === menu.session)
        #expect(window.library === menu.library)
        #expect(runtime.container?.session === window.session)

        await menu.libraryController.startNewRecording()
        #expect(window.session.phase == .recording)
        let reopened = await runtime.load()
        #expect(reopened.session === window.session)
        #expect(reopened.session.phase == .recording)
        await reopened.session.finish()
        #expect(menu.session.phase == .idle)
        #expect(menu.library.recordings.count == 1)
    }
}
