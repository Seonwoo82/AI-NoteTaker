import Foundation
import Testing
#if canImport(AudioPipeline)
import AudioPipeline
#endif
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Automatic sync")
struct AutomaticSyncTests {
    @Test("automatic polling receives changes without reopening the app or pressing Sync")
    func receivesRemoteChanges() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.scheduler.stop(); fixture.cleanup() }
        fixture.scheduler.start()
        await settle { fixture.library.recording(id: fixture.recording.id) != nil }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Original")
        await settle { fixture.clock.isWaiting }
        fixture.server.recording.title = "Changed on another device"
        fixture.server.recording.modifiedAt += 1
        fixture.clock.advance()
        await settle { fixture.library.recording(id: fixture.recording.id)?.title == "Changed on another device" }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Changed on another device")
    }

    @Test("repeated starts do not create duplicate polling loops and stopping prevents refresh")
    func hasOneLoopAndStops() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.scheduler.stop(); fixture.cleanup() }
        fixture.scheduler.start()
        fixture.scheduler.start()
        fixture.scheduler.start()
        await settle { fixture.clock.isWaiting }
        #expect(fixture.server.listCount == 1)
        fixture.scheduler.stop()
        await settle { !fixture.clock.isWaiting }
        fixture.server.recording.title = "Should stay remote"
        fixture.server.recording.modifiedAt += 1
        fixture.clock.advance()
        fixture.scheduler.requestSync()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Original")
    }

    @Test("failed refresh backs off, retries automatically, and returns to normal after recovery")
    func retriesAndRecovers() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.scheduler.stop(); fixture.cleanup() }
        fixture.server.isOffline = true
        fixture.scheduler.start()
        await settle { fixture.clock.isWaiting }
        #expect(fixture.coordinator.errorMessage != nil)
        #expect(fixture.clock.delays == [.seconds(30)])
        fixture.clock.advance()
        await settle { fixture.clock.delays.count == 2 && fixture.clock.isWaiting }
        #expect(fixture.clock.delays == [.seconds(30), .seconds(60)])
        fixture.server.isOffline = false
        fixture.clock.advance()
        await settle { fixture.library.recording(id: fixture.recording.id) != nil && fixture.clock.isWaiting }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Original")
        #expect(fixture.coordinator.errorMessage == nil)
        #expect(fixture.clock.delays.last == .seconds(30))
    }

    @Test("an activation or saved setting interrupts the wait and refreshes immediately")
    func refreshesOnRequest() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.scheduler.stop(); fixture.cleanup() }
        fixture.scheduler.start()
        await settle { fixture.clock.isWaiting }
        fixture.server.recording.title = "Updated while inactive"
        fixture.server.recording.modifiedAt += 1
        fixture.scheduler.requestSync()
        await settle { fixture.library.recording(id: fixture.recording.id)?.title == "Updated while inactive" }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Updated while inactive")
    }

    @Test("leaving the foreground stops polling and returning refreshes the remote library")
    func coordinatorFollowsLifecycle() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.coordinator.setAutomaticSyncActive(false); fixture.cleanup() }
        let clock = fixture.clock
        fixture.coordinator.configureAutomaticSync(library: fixture.library,
            sleep: { try await clock.sleep(for: $0) })
        fixture.coordinator.setAutomaticSyncActive(true)
        await settle { fixture.clock.isWaiting }
        fixture.coordinator.setAutomaticSyncActive(false)
        await settle { !fixture.clock.isWaiting }
        fixture.server.recording.title = "Changed in background"
        fixture.server.recording.modifiedAt += 1
        fixture.clock.advance()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Original")
        fixture.coordinator.setAutomaticSyncActive(true)
        await settle { fixture.library.recording(id: fixture.recording.id)?.title == "Changed in background" }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Changed in background")
    }

    @Test("disabling sync cancels an in-flight refresh and re-enabling resumes automatically")
    func settingsCancelAndResume() async throws {
        let fixture = await AutoSyncFixture.make()
        defer { fixture.coordinator.setAutomaticSyncActive(false); fixture.cleanup() }
        var started = false
        fixture.server.beforeList = {
            started = true
            try await Task.sleep(for: .seconds(60))
        }
        let clock = fixture.clock
        fixture.coordinator.configureAutomaticSync(library: fixture.library,
            sleep: { try await clock.sleep(for: $0) })
        fixture.coordinator.setAutomaticSyncActive(true)
        await settle { started }
        fixture.settings.isEnabled = false
        try fixture.settings.save()
        fixture.coordinator.settingsDidChange()
        await settle { !fixture.coordinator.isSyncing }
        #expect(fixture.library.recording(id: fixture.recording.id) == nil)
        #expect(fixture.coordinator.errorMessage == nil)
        fixture.server.beforeList = nil
        fixture.settings.isEnabled = true
        try fixture.settings.save()
        fixture.coordinator.settingsDidChange()
        await settle { fixture.library.recording(id: fixture.recording.id) != nil }
        #expect(fixture.library.recording(id: fixture.recording.id)?.title == "Original")
    }


    @Test("a token unavailable during launch is read again before automatic sync")
    func retriesLockedStartupCredentialRead() throws {
        let store = AutoSyncTokenStore()
        let settings = SyncSettings(defaults: UserDefaults(suiteName: "AutoSync.Unlock.\(UUID())")!, tokenStore: store)
        settings.endpoint = "https://sync.example.test"
        settings.isEnabled = true
        #expect(settings.token.isEmpty)
        store.token = "credential-available-after-unlock"
        _ = try settings.configuration()
        #expect(settings.token == "credential-available-after-unlock")
    }

}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private struct AutoSyncFixture {
    let root: URL
    let recording: Recording
    let library: LibraryStore
    let server: AutoSyncTransport
    let coordinator: SyncCoordinator
    let settings: SyncSettings
    let scheduler: AutomaticSyncScheduler
    let clock: AutoSyncClock

    static func make() async -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: root))
        let recording = Recording(title: "Original", duration: 1, mode: .micOnly, modifiedAt: 1_000)
        let server = AutoSyncTransport(recording: recording)
        let settings = SyncSettings(defaults: UserDefaults(suiteName: "AutoSync.\(UUID())")!, tokenStore: AutoSyncTokenStore())
        settings.endpoint = "https://sync.example.test"
        settings.token = "synthetic-sync-token"
        settings.isEnabled = true
        let coordinator = SyncCoordinator(settings: settings, transportFactory: { _ in server })
        let clock = AutoSyncClock()
        let scheduler = AutomaticSyncScheduler(synchronize: {
            await coordinator.sync(library: library)
            return coordinator.errorMessage == nil
        }, sleep: { duration in try await clock.sleep(for: duration) })
        return Self(root: root, recording: recording, library: library, server: server,
                    coordinator: coordinator, settings: settings, scheduler: scheduler, clock: clock)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class AutoSyncClock {
    var delays: [Duration] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var isWaiting: Bool { !waiters.isEmpty }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        delays.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
    func advance() {
        let current = waiters
        waiters.removeAll()
        for waiter in current.values { waiter.resume() }
    }
}

@MainActor
private final class AutoSyncTransport: SyncTransport {
    var recording: Recording
    var isOffline = false
    var listCount = 0
    var beforeList: (() async throws -> Void)?
    init(recording: Recording) { self.recording = recording }
    func health() async throws -> SyncHealth { SyncHealth(ok: true, schemaVersion: 1) }
    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        listCount += 1
        try await beforeList?()
        try Task.checkCancellation()
        if isOffline { throw URLError(.notConnectedToInternet) }
        return SyncRecordingPage(recordings: [recording], nextCursor: nil)
    }
    func putRecording(_ candidate: Recording) async throws -> Recording {
        if candidate.wins(over: recording) { recording = candidate }
        return recording
    }
    func uploadAudio(for recording: Recording, from url: URL) async throws {}
    func downloadAudio(for recording: Recording, to url: URL) async throws {
        try Data("Synthetic audio".utf8).write(to: url)
    }
}

@MainActor
private final class AutoSyncTokenStore: SyncTokenStore {
    var token: String?
    func loadToken() throws -> String? { token }
    func saveToken(_ token: String) throws { self.token = token }
}
