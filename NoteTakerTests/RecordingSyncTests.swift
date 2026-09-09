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

@Test("legacy recording sync metadata defaults to createdAt milliseconds and recording UUID")
func legacyRecordingSyncMetadataDefaultsToStableValues() throws {
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

    #expect(recording.modifiedAt == 1_788_310_923_000)
    #expect(recording.mutationID == "11111111-2222-3333-4444-555555555555")
}

@MainActor
@Test("local library updates stamp monotonically while remote applies preserve server metadata")
func libraryUpdatesStampLocallyAndRemoteAppliesPreserveServerMetadata() async throws {
    let paths = LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: [])
    let store = await LibraryStore.open(paths: paths)
    var local = syncRecording(
        id: try #require(UUID(uuidString: "22222222-3333-4444-5555-666666666666")),
        title: "Before",
        modifiedAt: 1_000,
        mutationID: "22222222-3333-4444-5555-666666666666"
    )
    try store.add(local)

    local.title = "After"
    try store.update(local)

    let stamped = try #require(store.recording(id: local.id))
    #expect(stamped.title == "After")
    #expect(stamped.modifiedAt > 1_000)
    #expect(stamped.mutationID != "22222222-3333-4444-5555-666666666666")

    let remote = syncRecording(
        id: local.id,
        title: "Remote",
        modifiedAt: 2_000,
        mutationID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    try store.applyRemote(remote)

    let applied = try #require(store.recording(id: local.id))
    #expect(applied.title == "Remote")
    #expect(applied.modifiedAt == 2_000)
    #expect(applied.mutationID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
}

@MainActor
@Test("sync moves metadata and missing audio between two local stores")
func syncMovesMetadataAndMissingAudioBetweenTwoLocalStores() async throws {
    let server = InMemorySyncTransport()
    let first = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let second = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "33333333-4444-5555-6666-777777777777")),
        title: "Shared",
        modifiedAt: 3_000,
        mutationID: "33333333-4444-5555-6666-777777777777"
    )
    let audioData = Data("audio bytes".utf8)
    try first.add(recording)
    try audioData.write(to: first.audioURL(for: recording))

    let firstSync = SyncEngine(transport: server)
    try await firstSync.sync(library: first)
    let secondSync = SyncEngine(transport: server)
    try await secondSync.sync(library: second)

    #expect(second.recording(id: recording.id) == recording)
    #expect(try Data(contentsOf: second.audioURL(for: recording)) == audioData)
    #expect(server.audioUploadCount(for: recording.id, audioVersion: recording.audioVersion) == 1)

    try await firstSync.sync(library: first)
    #expect(server.audioUploadCount(for: recording.id, audioVersion: recording.audioVersion) == 1)
}

@MainActor
@Test("sync moves recording folders between two local stores")
func syncMovesRecordingFoldersBetweenTwoLocalStores() async throws {
    let server = InMemorySyncTransport()
    let first = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let second = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let folder = try first.folderStore.create(name: "Clients")

    try await SyncEngine(transport: server).sync(library: first)
    try await SyncEngine(transport: server).sync(library: second)

    #expect(second.folderStore.activeFolders == [folder])
}

@MainActor
@Test("folder order converges across two libraries and survives a rename and restart")
func folderOrderConvergesAcrossLibraries() async throws {
    let server = InMemorySyncTransport()
    let first = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let secondPaths = LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: [])
    let second = await LibraryStore.open(paths: secondPaths)
    let a = try first.folderStore.create(name: "A")
    let b = try first.folderStore.create(name: "B")
    let c = try first.folderStore.create(name: "C")
    try first.folderStore.move(id: c.id, before: a.id)
    try await SyncEngine(transport: server).sync(library: first)
    try await SyncEngine(transport: server).sync(library: second)
    #expect(second.folderStore.activeFolders.map(\.id) == [c.id, a.id, b.id])
    try second.folderStore.rename(id: c.id, name: "Z")
    try second.folderStore.move(id: a.id, before: nil)
    try await SyncEngine(transport: server).sync(library: second)
    try await SyncEngine(transport: server).sync(library: first)
    #expect(first.folderStore.activeFolders.map(\.id) == [c.id, b.id, a.id])
    #expect(first.folderStore.folder(id: c.id)?.name == "Z")
    let reopened = RecordingFolderStore(paths: secondPaths)
    #expect(reopened.activeFolders.map(\.id) == [c.id, b.id, a.id])
}

@MainActor
@Test("sync continues recording metadata when folder endpoint fails")
func syncContinuesRecordingMetadataWhenFolderEndpointFails() async throws {
    let transport = InMemorySyncTransport()
    transport.failNextFolderList = true
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "33333333-4444-5555-6666-888888888888")),
        title: "Folder endpoint down",
        modifiedAt: 3_100,
        mutationID: "33333333-4444-5555-6666-888888888888"
    )
    try store.add(recording)
    try Data("audio bytes".utf8).write(to: store.audioURL(for: recording))

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: transport).sync(library: store)
    }

    #expect(transport.recording(id: recording.id) == recording)
    #expect(transport.folderListCount == 1)
}

@MainActor
@Test("sync preserves explicit folder membership through recording metadata")
func syncPreservesExplicitFolderMembershipThroughRecordingMetadata() async throws {
    let server = InMemorySyncTransport()
    let first = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let second = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let folder = try first.folderStore.create(name: "Calls")
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "33333333-4444-5555-6666-999999999999")),
        title: "Assigned",
        modifiedAt: 3_200,
        mutationID: "33333333-4444-5555-6666-999999999999"
    )
    try first.add(recording)
    try Data("audio bytes".utf8).write(to: first.audioURL(for: recording))
    try first.moveRecording(id: recording.id, toFolder: folder.id)

    try await SyncEngine(transport: server).sync(library: first)
    try await SyncEngine(transport: server).sync(library: second)

    #expect(second.recording(id: recording.id)?.folderID == folder.id)
}

@MainActor
@Test("sync skips audio transfer when local metadata and audio already match remote")
func syncSkipsAudioTransferWhenLocalMetadataAndAudioAlreadyMatchRemote() async throws {
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "3AAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        title: "Already local",
        modifiedAt: 3_500,
        mutationID: "3AAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    let transport = InMemorySyncTransport(recordings: [recording])
    try transport.storeAudio(Data("audio".utf8), for: recording)
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.applyRemote(recording)
    try Data("audio".utf8).write(to: store.audioURL(for: recording))

    let engine = SyncEngine(transport: transport)
    try await engine.sync(library: store)

    #expect(transport.audioDownloadCount(for: recording.id, audioVersion: recording.audioVersion) == 0)
    #expect(transport.audioUploadCount(for: recording.id, audioVersion: recording.audioVersion) == 0)
}

@MainActor
@Test("sync downloads server returned newer audio winner before applying it locally")
func syncDownloadsServerReturnedNewerAudioWinnerBeforeApplyingItLocally() async throws {
    let id = try #require(UUID(uuidString: "3BBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
    let local = syncRecording(
        id: id,
        title: "Local stale",
        modifiedAt: 4_000,
        mutationID: "3BBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
    )
    var serverWinner = syncRecording(
        id: id,
        title: "Server winner",
        modifiedAt: 5_000,
        mutationID: "FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBBBBBBB"
    )
    serverWinner.audioVersion = 2
    let transport = InMemorySyncTransport(recordings: [serverWinner])
    try transport.storeAudio(Data("winner audio".utf8), for: serverWinner)
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(local)
    try Data("stale audio".utf8).write(to: store.audioURL(for: local))

    let engine = SyncEngine(transport: transport)
    try await engine.sync(library: store)

    #expect(store.recording(id: id) == serverWinner)
    #expect(try Data(contentsOf: store.audioURL(for: serverWinner)) == Data("winner audio".utf8))
    #expect(transport.audioDownloadCount(for: id, audioVersion: 2) == 1)
}

@MainActor
@Test("failed remote metadata apply keeps old audio version valid")
func failedRemoteMetadataApplyKeepsOldAudioVersionValid() async throws {
    let id = try #require(UUID(uuidString: "3CCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"))
    var local = syncRecording(
        id: id,
        title: "Local v1",
        modifiedAt: 4_100,
        mutationID: "3CCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"
    )
    local.audioVersion = 1
    var remote = syncRecording(
        id: id,
        title: "Remote v2",
        modifiedAt: 4_200,
        mutationID: "FFFFFFFF-EEEE-DDDD-CCCC-AAAAAAAAAAAA"
    )
    remote.audioVersion = 2
    let transport = InMemorySyncTransport(recordings: [remote])
    try transport.storeAudio(Data("remote v2 audio".utf8), for: remote)
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(local)
    try Data("local v1 audio".utf8).write(to: store.audioURL(for: local))
    try FileManager.default.removeItem(at: store.paths.metadataURL(for: id))
    try FileManager.default.createDirectory(at: store.paths.metadataURL(for: id), withIntermediateDirectories: false)

    await #expect(throws: Error.self) {
        try await SyncEngine(transport: transport).sync(library: store)
    }

    #expect(store.recording(id: id) == local)
    #expect(try Data(contentsOf: store.audioURL(for: local)) == Data("local v1 audio".utf8))
    #expect(FileManager.default.fileExists(atPath: store.audioURL(for: remote).path))
}

@MainActor
@Test("sync keeps an in-flight local edit over an older remote response")
func syncKeepsInFlightLocalEditOverOlderRemoteResponse() async throws {
    let recordingID = try #require(UUID(uuidString: "44444444-5555-6666-7777-888888888888"))
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let original = syncRecording(
        id: recordingID,
        title: "Original",
        modifiedAt: 4_000,
        mutationID: "44444444-5555-6666-7777-888888888888"
    )
    try store.add(original)
    try Data("local audio".utf8).write(to: store.audioURL(for: original))

    let remoteSnapshot = syncRecording(
        id: recordingID,
        title: "Remote snapshot",
        modifiedAt: 4_500,
        mutationID: "55555555-6666-7777-8888-999999999999"
    )
    var remoteSnapshotWithNewAudio = remoteSnapshot
    remoteSnapshotWithNewAudio.audioVersion = 2
    let transport = InMemorySyncTransport(recordings: [remoteSnapshotWithNewAudio])
    try transport.storeAudio(Data("remote audio".utf8), for: remoteSnapshotWithNewAudio)
    transport.beforeDownloadAudio = {
        var edited = original
        edited.title = "Edited while syncing"
        try store.update(edited)
    }

    let engine = SyncEngine(transport: transport)
    try await engine.sync(library: store)

    #expect(store.recording(id: recordingID)?.title == "Edited while syncing")
}

@MainActor
@Test("sync retries audio download after partial transfer failure")
func syncRetriesAudioDownloadAfterPartialTransferFailure() async throws {
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "55555555-6666-7777-8888-999999999999")),
        title: "Retry",
        modifiedAt: 5_000,
        mutationID: "55555555-6666-7777-8888-999999999999"
    )
    let transport = InMemorySyncTransport(recordings: [recording])
    try transport.storeAudio(Data("complete audio".utf8), for: recording)
    transport.failNextDownload = true
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    let engine = SyncEngine(transport: transport)

    await #expect(throws: SyncError.self) {
        try await engine.sync(library: store)
    }
    #expect(store.recording(id: recording.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))

    try await engine.sync(library: store)

    #expect(store.recording(id: recording.id) == recording)
    #expect(try Data(contentsOf: store.audioURL(for: recording)) == Data("complete audio".utf8))
}

@MainActor
@Test("sync rejects duplicate remote IDs and invalid pagination cursors")
func syncRejectsDuplicateRemoteIDsAndInvalidPaginationCursors() async throws {
    let id = try #require(UUID(uuidString: "55555555-6666-7777-8888-AAAAAAAAAAAA"))
    let first = syncRecording(
        id: id,
        title: "First",
        modifiedAt: 5_100,
        mutationID: "55555555-6666-7777-8888-AAAAAAAAAAAA"
    )
    let duplicate = syncRecording(
        id: id,
        title: "Duplicate",
        modifiedAt: 5_200,
        mutationID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: ScriptedListTransport(pages: [
            SyncRecordingPage(recordings: [first, duplicate], nextCursor: nil)
        ])).sync(library: store)
    }

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: ScriptedListTransport(pages: [
            SyncRecordingPage(recordings: [first], nextCursor: "again"),
            SyncRecordingPage(recordings: [duplicate], nextCursor: "again")
        ])).sync(library: store)
    }

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: ScriptedListTransport(pages: [
            SyncRecordingPage(recordings: [], nextCursor: "cursor-without-progress")
        ])).sync(library: store)
    }
}

@MainActor
@Test("sync continues other notes after one audio transfer fails")
func syncContinuesOtherNotesAfterOneAudioTransferFails() async throws {
    let remote = syncRecording(
        id: try #require(UUID(uuidString: "55555555-6666-7777-8888-BBBBBBBBBBBB")),
        title: "Broken remote",
        modifiedAt: 5_300,
        mutationID: "55555555-6666-7777-8888-BBBBBBBBBBBB"
    )
    let local = syncRecording(
        id: try #require(UUID(uuidString: "55555555-6666-7777-8888-CCCCCCCCCCCC")),
        title: "Healthy local",
        modifiedAt: 5_400,
        mutationID: "55555555-6666-7777-8888-CCCCCCCCCCCC"
    )
    let transport = InMemorySyncTransport(recordings: [remote])
    transport.failNextDownload = true
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(local)
    try Data("healthy audio".utf8).write(to: store.audioURL(for: local))

    await #expect(throws: SyncError.self) {
        try await SyncEngine(transport: transport).sync(library: store)
    }

    #expect(transport.recording(id: local.id)?.title == "Healthy local")
    #expect(store.recording(id: remote.id) == nil)
}

@MainActor
@Test("concurrent sync request reruns after in-flight local edit")
func concurrentSyncRequestRerunsAfterInFlightLocalEdit() async throws {
    let id = try #require(UUID(uuidString: "5AAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let original = syncRecording(
        id: id,
        title: "Original",
        modifiedAt: 5_500,
        mutationID: "5AAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(original)
    try Data("audio".utf8).write(to: store.audioURL(for: original))
    let transport = InMemorySyncTransport()
    let engine = SyncEngine(transport: transport)
    var triggeredConcurrentSync = false
    transport.beforeUploadAudio = {
        guard !triggeredConcurrentSync else { return }
        triggeredConcurrentSync = true
        var edited = original
        edited.title = "Edited pending"
        try store.update(edited)
        Task {
            try await engine.sync(library: store)
        }
    }

    try await engine.sync(library: store)

    #expect(transport.recording(id: id)?.title == "Edited pending")
    #expect(transport.listCount >= 2)
}

@MainActor
@Test("sync coordinator reruns after a sync request made during long upload")
func syncCoordinatorRerunsAfterSyncRequestMadeDuringLongUpload() async throws {
    let firstID = try #require(UUID(uuidString: "5BBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
    let secondID = try #require(UUID(uuidString: "5CCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"))
    let first = syncRecording(
        id: firstID,
        title: "First",
        modifiedAt: 5_600,
        mutationID: "5BBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
    )
    let second = syncRecording(
        id: secondID,
        title: "Second",
        modifiedAt: 5_700,
        mutationID: "5CCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(first)
    try Data("first audio".utf8).write(to: store.audioURL(for: first))
    let transport = InMemorySyncTransport()
    let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
    settings.isEnabled = true
    settings.endpoint = "https://worker.example"
    settings.token = "secret"
    let coordinator = SyncCoordinator(settings: settings) { _ in transport }
    var triggeredConcurrentSync = false
    transport.beforeUploadAudio = {
        guard !triggeredConcurrentSync else { return }
        triggeredConcurrentSync = true
        try store.add(second)
        try Data("second audio".utf8).write(to: store.audioURL(for: second))
        Task {
            await coordinator.sync(library: store)
        }
    }

    await coordinator.sync(library: store)

    #expect(transport.recording(id: firstID)?.title == "First")
    #expect(transport.recording(id: secondID)?.title == "Second")
    #expect(coordinator.status == String(localized: "Synced"))
    #expect(coordinator.errorMessage == nil)
    #expect(coordinator.lastSyncedAt != nil)
    #expect(transport.listCount >= 2)
}

@MainActor
@Test("sync coordinator cancels current sync after settings change")
func syncCoordinatorCancelsCurrentSyncAfterSettingsChange() async throws {
    let id = try #require(UUID(uuidString: "5DDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB"))
    let recording = syncRecording(
        id: id,
        title: "Old config note",
        modifiedAt: 5_800,
        mutationID: "5DDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try Data("old config audio".utf8).write(to: store.audioURL(for: recording))
    let transport = InMemorySyncTransport()
    let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
    settings.isEnabled = true
    settings.endpoint = "https://old.example"
    settings.token = "old-token"
    let coordinator = SyncCoordinator(settings: settings) { _ in transport }
    transport.beforeUploadAudio = {
        settings.isEnabled = false
        coordinator.settingsDidChange()
    }

    await coordinator.sync(library: store)

    #expect(transport.recording(id: id) == nil)
    #expect(coordinator.errorMessage == nil)
    #expect(coordinator.lastSyncedAt == nil)
}

@MainActor
@Test("sync coordinator cancels stale connection test after settings change")
func syncCoordinatorCancelsStaleConnectionTestAfterSettingsChange() async throws {
    let transport = InMemorySyncTransport()
    let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
    settings.isEnabled = false
    settings.endpoint = "https://old.example"
    settings.token = "secret"
    let coordinator = SyncCoordinator(settings: settings) { _ in transport }
    transport.beforeHealth = {
        settings.endpoint = "https://new.example"
        coordinator.settingsDidChange()
    }

    await coordinator.testConnection()

    #expect(coordinator.status != String(localized: "Connection OK"))
    #expect(coordinator.errorMessage == nil)
    #expect(coordinator.lastSyncedAt == nil)
    #expect(coordinator.isSyncing == false)
}

@MainActor
@Test("sync coordinator cancels a running connection test before syncing")
func syncCoordinatorCancelsRunningConnectionTestBeforeSyncing() async throws {
    let id = try #require(UUID(uuidString: "5EEEEEEE-FFFF-AAAA-BBBB-CCCCCCCCCCCC"))
    let recording = syncRecording(
        id: id,
        title: "Sync after test",
        modifiedAt: 5_900,
        mutationID: "5EEEEEEE-FFFF-AAAA-BBBB-CCCCCCCCCCCC"
    )
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(recording)
    try Data("sync after test audio".utf8).write(to: store.audioURL(for: recording))
    let transport = InMemorySyncTransport()
    let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
    settings.isEnabled = true
    settings.endpoint = "https://worker.example"
    settings.token = "secret"
    let coordinator = SyncCoordinator(settings: settings) { _ in transport }
    var healthStarted = false
    var releaseHealth: CheckedContinuation<Void, Never>?
    transport.beforeHealth = {
        healthStarted = true
        await withCheckedContinuation { continuation in
            releaseHealth = continuation
        }
        try Task.checkCancellation()
    }
    let testTask = Task { @MainActor in
        await coordinator.testConnection()
    }
    while !healthStarted {
        await Task.yield()
    }

    let syncTask = Task { @MainActor in
        await coordinator.sync(library: store)
    }
    await Task.yield()
    releaseHealth?.resume()
    await testTask.value
    await syncTask.value

    #expect(transport.recording(id: id)?.title == "Sync after test")
    #expect(coordinator.status == String(localized: "Synced"))
    #expect(coordinator.errorMessage == nil)
    #expect(coordinator.lastSyncedAt != nil)
    #expect(coordinator.isSyncing == false)
}

@MainActor
@Test("sync coordinator validates health body before reporting connection ok")
func syncCoordinatorValidatesHealthBodyBeforeReportingConnectionOK() async throws {
    let transport = InMemorySyncTransport()
    transport.healthResponse = SyncHealth(ok: false, schemaVersion: 1)
    let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
    settings.isEnabled = false
    settings.endpoint = "https://worker.example"
    settings.token = "secret"
    let coordinator = SyncCoordinator(settings: settings) { _ in transport }

    await coordinator.testConnection()

    #expect(coordinator.status != String(localized: "Connection OK"))
    #expect(coordinator.errorMessage != nil)
    #expect(coordinator.lastSyncedAt == nil)
}

@MainActor
@Test("last write wins conflict order includes tombstones")
func syncLastWriteWinsConflictOrderIncludesTombstones() async throws {
    let id = try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))
    let localLive = syncRecording(
        id: id,
        title: "Live",
        modifiedAt: 6_000,
        mutationID: "66666666-7777-8888-9999-AAAAAAAAAAAA"
    )
    let remoteDeleted = syncRecording(
        id: id,
        title: "Deleted",
        deletedAt: Date(timeIntervalSince1970: 10),
        modifiedAt: 7_000,
        mutationID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )
    let transport = InMemorySyncTransport(recordings: [remoteDeleted])
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(localLive)
    try Data("audio".utf8).write(to: store.audioURL(for: localLive))

    let engine = SyncEngine(transport: transport)
    try await engine.sync(library: store)

    #expect(store.recording(id: id)?.deletedAt == remoteDeleted.deletedAt)
    #expect(store.recording(id: id)?.modifiedAt == 7_000)
}

@MainActor
@Test("sync keeps locally purged identical tombstone hidden without audio transfer")
func syncKeepsLocallyPurgedIdenticalTombstoneHiddenWithoutAudioTransfer() async throws {
    let id = try #require(UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB"))
    let deletedAt = Date(timeIntervalSince1970: 20)
    let tombstone = syncRecording(
        id: id,
        title: "Deleted",
        deletedAt: deletedAt,
        modifiedAt: 7_500,
        mutationID: "77777777-8888-9999-AAAA-BBBBBBBBBBBB"
    )
    let transport = InMemorySyncTransport(recordings: [tombstone])
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(tombstone)
    try Data("local audio".utf8).write(to: store.audioURL(for: tombstone))
    try store.deletePermanently(id: id)

    try await SyncEngine(transport: transport).sync(library: store)

    #expect(store.recording(id: id)?.deletedAt == deletedAt)
    #expect(store.filteredRecordings(in: .recentlyDeleted).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: tombstone).path))
    #expect(transport.audioDownloadCount(for: id, audioVersion: tombstone.audioVersion) == 0)
    #expect(transport.audioUploadCount(for: id, audioVersion: tombstone.audioVersion) == 0)
}

@MainActor
@Test("sync restores a newer remote live record after local purge and allows later soft delete")
func syncRestoresNewerRemoteLiveRecordAfterLocalPurgeAndAllowsLaterSoftDelete() async throws {
    let id = try #require(UUID(uuidString: "77777777-8888-9999-AAAA-CCCCCCCCCCCC"))
    let tombstone = syncRecording(
        id: id,
        title: "Deleted",
        deletedAt: Date(timeIntervalSince1970: 20),
        modifiedAt: 7_500,
        mutationID: "77777777-8888-9999-AAAA-CCCCCCCCCCCC"
    )
    var restored = syncRecording(
        id: id,
        title: "Restored elsewhere",
        modifiedAt: 7_600,
        mutationID: "CCCCCCCC-BBBB-AAAA-9999-888888888888"
    )
    restored.audioVersion = 2
    let transport = InMemorySyncTransport(recordings: [restored])
    try transport.storeAudio(Data("restored audio".utf8), for: restored)
    let store = await LibraryStore.open(paths: LibraryPaths(libraryRoot: uniqueSyncLibraryRoot(), arguments: []))
    try store.add(tombstone)
    try Data("local audio".utf8).write(to: store.audioURL(for: tombstone))
    try store.deletePermanently(id: id)

    try await SyncEngine(transport: transport).sync(library: store)

    #expect(store.filteredRecordings(in: .all).map(\.id) == [id])
    #expect(store.recording(id: id)?.deletedAt == nil)
    #expect(try Data(contentsOf: store.audioURL(for: restored)) == Data("restored audio".utf8))

    try store.moveToRecentlyDeleted(id: id, now: Date(timeIntervalSince1970: 30))

    #expect(store.filteredRecordings(in: .recentlyDeleted).map(\.id) == [id])
}

@Test("sync configuration accepts only HTTPS origins without credentials query or fragment")
func syncConfigurationAcceptsOnlyCleanHTTPSOrigins() throws {
    let valid = try SyncConfiguration(endpoint: "https://example.cloudflareworkers.com/", token: "secret")
    #expect(valid.endpoint.absoluteString == "https://example.cloudflareworkers.com")

    #expect(throws: SyncConfigurationError.self) {
        _ = try SyncConfiguration(endpoint: "http://example.com", token: "secret")
    }
    #expect(throws: SyncConfigurationError.self) {
        _ = try SyncConfiguration(endpoint: "https://user@example.com", token: "secret")
    }
    #expect(throws: SyncConfigurationError.self) {
        _ = try SyncConfiguration(endpoint: "https://example.com?token=secret", token: "secret")
    }
    #expect(throws: SyncConfigurationError.self) {
        _ = try SyncConfiguration(endpoint: "https://example.com#secret", token: "secret")
    }
}

@MainActor
@Test("URL session client rejects redirects and oversized audio uploads")
func urlSessionClientRejectsRedirectsAndOversizedAudioUploads() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SyncURLProtocol.self]
    let client = URLSessionSyncTransport(
        configuration: try SyncConfiguration(endpoint: "https://worker.example", token: "secret"),
        session: URLSession(configuration: configuration)
    )
    let recording = syncRecording(
        id: try #require(UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB")),
        title: "Upload",
        modifiedAt: 8_000,
        mutationID: "77777777-8888-9999-AAAA-BBBBBBBBBBBB"
    )
    let audioURL = FileManager.default.temporaryDirectory.appending(path: "oversized-\(UUID().uuidString).m4a")
    try Data(count: URLSessionSyncTransport.maxAudioByteCount + 1).write(to: audioURL)

    await #expect(throws: SyncError.self) {
        try await client.uploadAudio(for: recording, from: audioURL)
    }

    let uploadURL = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).m4a")
    try Data("small audio".utf8).write(to: uploadURL)
    SyncURLProtocol.handler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == "11")
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            Data()
        )
    }
    try await client.uploadAudio(for: recording, from: uploadURL)

    SyncURLProtocol.handler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://evil.example"]
            )!,
            Data()
        )
    }

    await #expect(throws: SyncError.self) {
        _ = try await client.health()
    }

    let htmlDestination = FileManager.default.temporaryDirectory.appending(path: "html-\(UUID().uuidString).m4a")
    SyncURLProtocol.handler = { request in
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!,
            Data("<html></html>".utf8)
        )
    }
    await #expect(throws: SyncError.self) {
        try await client.downloadAudio(for: recording, to: htmlDestination)
    }
    #expect(!FileManager.default.fileExists(atPath: htmlDestination.path))

    let emptyDestination = FileManager.default.temporaryDirectory.appending(path: "empty-\(UUID().uuidString).m4a")
    SyncURLProtocol.handler = { request in
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mp4"]
            )!,
            Data()
        )
    }
    await #expect(throws: SyncError.self) {
        try await client.downloadAudio(for: recording, to: emptyDestination)
    }
    #expect(!FileManager.default.fileExists(atPath: emptyDestination.path))

    let hugeHeaderDestination = FileManager.default.temporaryDirectory.appending(path: "huge-header-\(UUID().uuidString).m4a")
    SyncURLProtocol.handler = { request in
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": String(URLSessionSyncTransport.maxAudioByteCount + 1)
                ]
            )!,
            Data("too big by header".utf8)
        )
    }
    await #expect(throws: SyncError.self) {
        try await client.downloadAudio(for: recording, to: hugeHeaderDestination)
    }
    #expect(!FileManager.default.fileExists(atPath: hugeHeaderDestination.path))
}

@MainActor
@Test("sync settings save disabled state without endpoint and do not partially save defaults on keychain failure")
func syncSettingsSaveDisabledStateAndDoNotPartiallySaveDefaultsOnKeychainFailure() throws {
    let defaults = try #require(UserDefaults(suiteName: "NoteTakerSyncSettingsTests-\(UUID().uuidString)"))
    let tokenStore = StubSyncTokenStore()
    let settings = SyncSettings(defaults: defaults, tokenStore: tokenStore)
    settings.isEnabled = false
    settings.endpoint = "not a url"
    settings.token = ""

    try settings.save()

    #expect(defaults.bool(forKey: "sync.isEnabled") == false)
    #expect(defaults.string(forKey: "sync.endpoint") == "not a url")
    #expect(tokenStore.savedToken == "")

    tokenStore.saveError = SyncError.transferFailed("Keychain down")
    settings.isEnabled = true
    settings.endpoint = "https://worker.example"
    settings.token = "secret"

    #expect(throws: SyncError.self) {
        try settings.save()
    }

    #expect(defaults.bool(forKey: "sync.isEnabled") == false)
    #expect(defaults.string(forKey: "sync.endpoint") == "not a url")
}

private func syncRecording(
    id: UUID,
    title: String,
    deletedAt: Date? = nil,
    modifiedAt: Int64,
    mutationID: String
) -> Recording {
    Recording(
        id: id,
        title: title,
        createdAt: Date(timeIntervalSince1970: 100),
        duration: 10,
        mode: .micOnly,
        deletedAt: deletedAt,
        modifiedAt: modifiedAt,
        mutationID: mutationID
    )
}

private func uniqueSyncLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "NoteTakerSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func syncDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "NoteTakerSyncTests-\(UUID().uuidString)"))
}

private final class SyncURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { _ in
        (
            HTTPURLResponse(
                url: URL(string: "https://worker.example/v1/health")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            Data(#"{"ok":true,"schemaVersion":1}"#.utf8)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class ScriptedListTransport: SyncTransport {
    private var pages: [SyncRecordingPage]
    private(set) var listCount = 0

    init(pages: [SyncRecordingPage]) {
        self.pages = pages
    }

    func health() async throws -> SyncHealth {
        SyncHealth(ok: true, schemaVersion: 1)
    }

    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        listCount += 1
        guard !pages.isEmpty else {
            return SyncRecordingPage(recordings: [], nextCursor: nil)
        }
        return pages.removeFirst()
    }

    func putRecording(_ recording: Recording) async throws -> Recording {
        recording
    }

    func uploadAudio(for recording: Recording, from url: URL) async throws {}

    func downloadAudio(for recording: Recording, to url: URL) async throws {}
}

@MainActor
private final class InMemorySyncTransport: RecordingFolderSyncTransport {
    var beforeDownloadAudio: (() throws -> Void)?
    var beforeUploadAudio: (() throws -> Void)?
    var failNextDownload = false
    var listCount = 0
    var folderListCount = 0
    var failNextFolderList = false
    var healthResponse = SyncHealth(ok: true, schemaVersion: 1)
    var beforeHealth: (() async throws -> Void)?

    private var recordings: [UUID: Recording]
    private var folders: [UUID: RecordingCollectionFolder] = [:]
    private var audio: [AudioKey: Data] = [:]
    private var uploadCounts: [AudioKey: Int] = [:]
    private var downloadCounts: [AudioKey: Int] = [:]

    init(recordings: [Recording] = []) {
        self.recordings = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
    }

    func health() async throws -> SyncHealth {
        try await beforeHealth?()
        try Task.checkCancellation()
        return healthResponse
    }

    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        listCount += 1
        let sorted = recordings.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return SyncRecordingPage(recordings: sorted, nextCursor: nil)
    }

    func putRecording(_ recording: Recording) async throws -> Recording {
        if let current = recordings[recording.id], current.wins(over: recording) {
            return current
        }
        recordings[recording.id] = recording
        return recording
    }

    func listRecordingFolders(cursor: String?) async throws -> RecordingFolderPage {
        folderListCount += 1
        if failNextFolderList {
            failNextFolderList = false
            throw SyncError.transferFailed("Injected folder list failure")
        }
        let sorted = folders.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return RecordingFolderPage(folders: sorted, nextCursor: nil)
    }

    func putRecordingFolder(_ folder: RecordingCollectionFolder) async throws -> RecordingCollectionFolder {
        if let current = folders[folder.id], current.wins(over: folder) {
            return current
        }
        folders[folder.id] = folder
        return folder
    }

    func uploadAudio(for recording: Recording, from url: URL) async throws {
        try beforeUploadAudio?()
        await Task.yield()
        try Task.checkCancellation()
        let key = AudioKey(recordingID: recording.id, audioVersion: recording.audioVersion)
        audio[key] = try Data(contentsOf: url)
        uploadCounts[key, default: 0] += 1
    }

    func downloadAudio(for recording: Recording, to url: URL) async throws {
        try beforeDownloadAudio?()
        if failNextDownload {
            failNextDownload = false
            throw SyncError.transferFailed("Injected download failure")
        }
        let key = AudioKey(recordingID: recording.id, audioVersion: recording.audioVersion)
        guard let data = audio[key] else {
            throw SyncError.missingAudio(recording.id)
        }
        downloadCounts[key, default: 0] += 1
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func storeAudio(_ data: Data, for recording: Recording) throws {
        let key = AudioKey(recordingID: recording.id, audioVersion: recording.audioVersion)
        audio[key] = data
    }

    func audioUploadCount(for recordingID: UUID, audioVersion: Int) -> Int {
        uploadCounts[AudioKey(recordingID: recordingID, audioVersion: audioVersion), default: 0]
    }

    func audioDownloadCount(for recordingID: UUID, audioVersion: Int) -> Int {
        downloadCounts[AudioKey(recordingID: recordingID, audioVersion: audioVersion), default: 0]
    }

    func recording(id: UUID) -> Recording? {
        recordings[id]
    }

    private struct AudioKey: Hashable {
        let recordingID: UUID
        let audioVersion: Int
    }
}

@MainActor
private final class StubSyncTokenStore: SyncTokenStore {
    var savedToken: String?
    var saveError: Error?

    func loadToken() throws -> String? {
        savedToken
    }

    func saveToken(_ token: String) throws {
        if let saveError {
            throw saveError
        }
        savedToken = token
    }
}
