import CryptoKit
import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@MainActor
@Suite("Meeting data sync")
struct MeetingDataSyncTests {
    @Test("intelligence store saves bounded documents and keeps newer local data")
    func intelligenceStoreKeepsNewerLocalData() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let store = MeetingIntelligenceStore(library: library)
        let local = makeDocument(recording: recording, modifiedAt: 20, mutationID: uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let remote = makeDocument(recording: recording, modifiedAt: 10, mutationID: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        try await store.save(local)

        try await store.applyRemote(data: encode(remote), descriptor: descriptor(for: remote))

        #expect(store.document(for: recording.id) == local)
        #expect(try decodeStoredDocument(library: library, recordingID: recording.id) == local)
    }

    @Test("meeting edit log preserves pending edits and only ingest advances read cursor")
    func editLogPendingAckAndCursor() throws {
        let root = temporaryDirectory()
        let log = MeetingEditLog(root: root)
        let recordingID = uuid("11111111-1111-1111-1111-111111111111")
        var changes = 0
        log.onChange = { changes += 1 }

        let local = try log.append(recordingID: recordingID, audioVersion: 1, kind: .speakerName,
            targetID: "speaker-a", value: "Seonwoo")
        let acknowledged = MeetingEditEntry(sequence: 10, edit: local)
        try log.acknowledge(entry: acknowledged, workspace: "https://sync.example")

        #expect(log.pending(workspace: "https://sync.example").isEmpty)
        #expect(log.cursor(workspace: "https://sync.example") == 0)

        let remote = MeetingEdit(id: uuid("22222222-2222-2222-2222-222222222222"),
            recordingID: recordingID, audioVersion: 1, modifiedAt: 30,
            kind: .actionStatus, targetID: "action-1", value: "done")
        try log.ingest(page: MeetingEditPage(entries: [MeetingEditEntry(sequence: 11, edit: remote)], nextCursor: nil),
            workspace: "https://sync.example")

        #expect(log.cursor(workspace: "https://sync.example") == 11)
        #expect(log.edits(for: recordingID, audioVersion: 1).map(\.id).sortedByUUIDString() == [local.id, remote.id].sortedByUUIDString())
        #expect(changes == 1)
        #expect(MeetingEditLog(root: root).cursor(workspace: "https://sync.example") == 11)
    }

    @Test("synchronizer reads remote profile before publishing pending text profile without voice data")
    func synchronizerSyncsProfileWithoutVoiceData() async throws {
        let root = temporaryDirectory()
        let profileStore = MeetingProfileStore(root: root)
        let voice = LocalVoiceProfile(modelID: "local-voice", embedding: [0.1, 0.2], enrolledAt: Date(), sampleDuration: 3)
        try profileStore.saveVoiceProfile(voice, allowedDimensions: 2...2)
        try profileStore.updateProfile { profile in
            profile.displayName = "Seonwoo"
            profile.modifiedAt = 20
            profile.mutationID = uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        }
        let remote = MeetingUserProfile(displayName: "Remote", modifiedAt: 10,
            mutationID: uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let transport = FakeMeetingDataTransport()
        transport.remoteProfile = remote

        try await MeetingDataSynchronizer(profile: profileStore).synchronizeProfile(
            transport: transport,
            workspace: "https://sync.example"
        )

        #expect(profileStore.profile.displayName == "Seonwoo")
        #expect(profileStore.pendingProfileUpload == nil)
        #expect(transport.profileCallOrder == ["get", "put"])
        #expect(transport.uploadedProfiles == [profileStore.profile])
    }

    @Test("artifact sync adopts remote intelligence then uploads independent pending edits")
    func artifactSyncAdoptsRemoteAndUploadsEdits() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let store = MeetingIntelligenceStore(library: library)
        var localSaveEchoes: [UUID] = []
        store.onDocumentSaved = { localSaveEchoes.append($0) }
        let editLog = MeetingEditLog(root: library.paths.libraryRoot)
        let pending = try editLog.append(recordingID: recording.id, audioVersion: recording.audioVersion,
            kind: .speakerOwner, targetID: "speaker-a", value: "true")
        let remote = makeDocument(recording: recording, modifiedAt: 40, mutationID: uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let transport = FakeMeetingDataTransport()
        try transport.storeRemote(remote)

        try await MeetingDataSynchronizer(store: store, edits: editLog).synchronizeArtifacts(
            transport: transport,
            workspace: "https://sync.example",
            library: library
        )

        #expect(store.document(for: recording.id) == remote)
        #expect(editLog.pending(workspace: "https://sync.example").isEmpty)
        #expect(transport.uploadedEdits.map(\.id) == [pending.id])
        #expect(localSaveEchoes.isEmpty)
    }

    @Test("artifact sync skips unchanged remote descriptors on repeated sync")
    func artifactSyncSkipsUnchangedRemoteDownloads() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let store = MeetingIntelligenceStore(library: library)
        let document = makeDocument(recording: recording, modifiedAt: 40,
            mutationID: uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let transport = FakeMeetingDataTransport()
        try transport.storeRemote(document)
        let sync = MeetingDataSynchronizer(store: store)

        try await sync.synchronizeArtifacts(transport: transport, workspace: "https://sync.example", library: library)
        try await sync.synchronizeArtifacts(transport: transport, workspace: "https://sync.example", library: library)

        #expect(transport.downloadCount == 1)
        #expect(transport.uploadedDocuments.isEmpty)
    }

    @Test("artifact sync preserves malformed local intelligence instead of overwriting it")
    func artifactSyncPreservesMalformedLocalDocument() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let url = library.paths.directory(for: recording.id).appending(path: "meeting-intelligence.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data(#"{"schemaVersion":1,"recordingID":"wrong"}"#.utf8)
        try corrupt.write(to: url, options: .atomic)
        let store = MeetingIntelligenceStore(library: library)
        let remote = makeDocument(recording: recording, modifiedAt: 40,
            mutationID: uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let transport = FakeMeetingDataTransport()
        try transport.storeRemote(remote)

        await #expect(throws: Error.self) {
            try await MeetingDataSynchronizer(store: store).synchronizeArtifacts(
                transport: transport,
                workspace: "https://sync.example",
                library: library
            )
        }

        #expect(try Data(contentsOf: url) == corrupt)
        #expect(transport.downloadCount == 0)
    }

    @Test("rapid meeting edits receive monotonic timestamps")
    func rapidMeetingEditsReceiveMonotonicTimestamps() throws {
        let log = MeetingEditLog(root: temporaryDirectory())
        let recordingID = uuid("11111111-1111-1111-1111-111111111111")

        let first = try log.append(recordingID: recordingID, audioVersion: 1, kind: .actionStatus,
            targetID: "action-1", value: "done")
        let second = try log.append(recordingID: recordingID, audioVersion: 1, kind: .actionStatus,
            targetID: "action-1", value: "open")

        #expect(second.modifiedAt > first.modifiedAt)
    }

    @Test("failed edit log persistence does not advance pending acknowledgements or cursor in memory")
    func failedEditPersistenceDoesNotAdvanceMemory() throws {
        let root = temporaryDirectory()
        let recordingID = uuid("11111111-1111-1111-1111-111111111111")
        let initial = MeetingEditLog(root: root)
        let edit = try initial.append(recordingID: recordingID, audioVersion: 1,
            kind: .speakerName, targetID: "speaker-a", value: "Seonwoo")
        let failing = MeetingEditLog(root: root) { _, _ in throw CocoaError(.fileWriteUnknown) }

        #expect(throws: Error.self) {
            try failing.acknowledge(entry: MeetingEditEntry(sequence: 9, edit: edit), workspace: "https://sync.example")
        }

        #expect(failing.pending(workspace: "https://sync.example").map(\.id) == [edit.id])
        #expect(failing.cursor(workspace: "https://sync.example") == 0)
    }

    @Test("meeting edit log reloads legitimate history larger than the old cap")
    func editLogReloadsHistoryLargerThanOldCap() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = (0..<1_500).map { index in
            MeetingEditLogFixtureRecord(entry: MeetingEditEntry(sequence: Int64(index + 1),
                edit: MeetingEdit(id: uuid(String(format: "AAAAAAAA-BBBB-4CCC-8DDD-%012X", index)),
                    recordingID: uuid("11111111-1111-1111-1111-111111111111"),
                    audioVersion: 1, modifiedAt: Int64(index + 1), kind: .speakerName,
                    targetID: "speaker-\(index)", value: "Speaker \(index)")),
                acknowledgedWorkspaces: [])
        }
        let data = try JSONEncoder().encode(MeetingEditLogFixtureState(entries: records))
        #expect(data.count > 256 * 1_024)
        #expect(data.count < MeetingEditLog.maximumEncodedByteCount)
        try data.write(to: root.appending(path: "meeting-edits.json"), options: .atomic)

        let restarted = MeetingEditLog(root: root)
        #expect(restarted.loadError == nil)
        #expect(restarted.entries.count == records.count)
        _ = try restarted.append(recordingID: uuid("11111111-1111-1111-1111-111111111111"),
            audioVersion: 1, kind: .projectName, targetID: "", value: "AI-NoteTaker")
        #expect(MeetingEditLog(root: root).entries.count == records.count + 1)
    }

    @Test("corrupt meeting edit log refuses writes and preserves existing bytes")
    func corruptEditLogRefusesWritesAndPreservesBytes() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "meeting-edits.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url, options: .atomic)

        let log = MeetingEditLog(root: root)

        #expect(log.loadError != nil)
        #expect(throws: Error.self) {
            try log.append(recordingID: uuid("11111111-1111-1111-1111-111111111111"),
                audioVersion: 1, kind: .speakerName, targetID: "speaker-a", value: "Seonwoo")
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("pending old audio-version edits are retained without blocking current edits")
    func pendingOldVersionEditsDoNotBlockCurrentEdits() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording(audioVersion: 2)
        try library.add(recording)
        let editLog = MeetingEditLog(root: library.paths.libraryRoot)
        let stale = try editLog.append(recordingID: recording.id, audioVersion: 1,
            kind: .speakerName, targetID: "speaker-a", value: "Old")
        let current = try editLog.append(recordingID: recording.id, audioVersion: 2,
            kind: .speakerName, targetID: "speaker-a", value: "Current")
        let transport = FakeMeetingDataTransport()

        try await MeetingDataSynchronizer(edits: editLog).synchronizeArtifacts(
            transport: transport, workspace: "https://sync.example", library: library)

        #expect(transport.uploadedEdits.map(\.id) == [current.id])
        #expect(editLog.pending(workspace: "https://sync.example").map(\.id) == [stale.id])
    }

    @Test("pending edit upload failures do not block later pending edits")
    func pendingEditUploadFailuresDoNotBlockLaterEdits() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let editLog = MeetingEditLog(root: library.paths.libraryRoot)
        let failing = try editLog.append(recordingID: recording.id, audioVersion: recording.audioVersion,
            kind: .speakerName, targetID: "speaker-a", value: "Fails")
        let succeeding = try editLog.append(recordingID: recording.id, audioVersion: recording.audioVersion,
            kind: .speakerName, targetID: "speaker-b", value: "Succeeds")
        let transport = FakeMeetingDataTransport()
        transport.failedEditIDs = [failing.id]

        await #expect(throws: Error.self) {
            try await MeetingDataSynchronizer(edits: editLog).synchronizeArtifacts(
                transport: transport, workspace: "https://sync.example", library: library)
        }

        #expect(transport.uploadedEditAttempts == [failing.id, succeeding.id])
        #expect(editLog.pending(workspace: "https://sync.example").map(\.id) == [failing.id])
    }

    @Test("cancelled edit listing response is not ingested")
    func cancelledEditListingResponseIsNotIngested() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let editLog = MeetingEditLog(root: library.paths.libraryRoot)
        let transport = FakeMeetingDataTransport()
        let remote = MeetingEdit(id: uuid("22222222-2222-2222-2222-222222222222"),
            recordingID: uuid("11111111-1111-1111-1111-111111111111"), audioVersion: 1,
            modifiedAt: 30, kind: .speakerName, targetID: "speaker-a", value: "Remote")
        transport.editPages = [MeetingEditPage(entries: [MeetingEditEntry(sequence: 1, edit: remote)], nextCursor: nil)]
        var task: Task<Void, Error>!
        transport.afterListMeetingEdits = { task.cancel() }
        task = Task {
            try await MeetingDataSynchronizer(edits: editLog).synchronizeArtifacts(
                transport: transport, workspace: "https://sync.example", library: library)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(editLog.cursor(workspace: "https://sync.example") == 0)
        #expect(editLog.entries.isEmpty)
    }

    @Test("cancelled edit upload response is not acknowledged")
    func cancelledEditUploadResponseIsNotAcknowledged() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        let editLog = MeetingEditLog(root: library.paths.libraryRoot)
        let edit = try editLog.append(recordingID: recording.id, audioVersion: recording.audioVersion,
            kind: .speakerName, targetID: "speaker-a", value: "Seonwoo")
        let transport = FakeMeetingDataTransport()
        var task: Task<Void, Error>!
        transport.afterUploadMeetingEdit = { task.cancel() }
        task = Task {
            try await MeetingDataSynchronizer(edits: editLog).synchronizeArtifacts(
                transport: transport, workspace: "https://sync.example", library: library)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(editLog.pending(workspace: "https://sync.example").map(\.id) == [edit.id])
    }

    @Test("sync coordinator syncs meeting profile before recordings and meeting artifacts after audio")
    func syncCoordinatorOrdersMeetingDataAroundRecordingSync() async throws {
        let library = await LibraryStore.open(paths: LibraryPaths(libraryRoot: temporaryDirectory(), arguments: []))
        let recording = makeRecording()
        try library.add(recording)
        try Data("audio".utf8).write(to: library.audioURL(for: recording), options: .atomic)
        let profileStore = MeetingProfileStore(root: library.paths.libraryRoot)
        try profileStore.updateProfile { profile in
            profile.displayName = "Seonwoo"
            profile.modifiedAt = 20
            profile.mutationID = uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        }
        let store = MeetingIntelligenceStore(library: library)
        let document = makeDocument(recording: recording, modifiedAt: 30,
            mutationID: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        try await store.save(document)
        let edits = MeetingEditLog(root: library.paths.libraryRoot)
        _ = try edits.append(recordingID: recording.id, audioVersion: recording.audioVersion,
            kind: .speakerName, targetID: "speaker-a", value: "Seonwoo")
        let settings = SyncSettings(defaults: try syncDefaults(), tokenStore: StubSyncTokenStore())
        settings.endpoint = "https://sync.example"
        settings.token = "secret"
        settings.isEnabled = true
        let transport = CoordinatorMeetingDataTransport()
        let coordinator = SyncCoordinator(settings: settings) { _ in transport }
        coordinator.configureMeetingDataSync(profile: profileStore, store: store, edits: edits)

        await coordinator.sync(library: library)

        #expect(transport.events.first == "getProfile")
        #expect(transport.events.firstIndex(of: "getProfile")! < transport.events.firstIndex(of: "listRecordings")!)
        #expect(transport.events.firstIndex(of: "uploadAudio")! < transport.events.firstIndex(of: "listMeetingEdits")!)
        #expect(transport.events.firstIndex(of: "uploadAudio")! < transport.events.firstIndex(of: "listMeetingIntelligence")!)
        #expect(transport.uploadedProfiles == [profileStore.profile])
        #expect(transport.uploadedDocuments == [document])
        #expect(transport.uploadedEdits.count == 1)
        #expect(coordinator.errorMessage == nil)
    }

    private func makeRecording(
        id: UUID = UUID(uuidString: "81111111-2222-3333-8444-555555555555")!,
        audioVersion: Int = 1,
        deletedAt: Date? = nil
    ) -> Recording {
        Recording(id: id, title: "Meeting", createdAt: Date(timeIntervalSince1970: 1_788_310_923),
            duration: 12, mode: .micOnly, deletedAt: deletedAt, audioVersion: audioVersion,
            hasTranscript: true, modifiedAt: 1_788_310_923_000, mutationID: id.uuidString.uppercased())
    }

    private func makeDocument(recording: Recording, modifiedAt: Int64, mutationID: UUID) -> MeetingIntelligenceDocument {
        let transcript = MeetingTranscript(recordingID: recording.id, audioVersion: recording.audioVersion,
            transcriptionModelID: "fixture/transcription",
            speakers: [MeetingSpeaker(id: "speaker-a", name: "Speaker A", isOwner: false)],
            turns: [TranscriptTurn(id: "turn-1", start: 0, end: 2, speakerID: "speaker-a", text: "I will follow up.")])
        let insights = MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Follow up",
                actorSpeakerID: "speaker-a", targetSpeakerID: nil, dueText: nil, evidenceTurnIDs: ["turn-1"])
        ])
        return MeetingIntelligenceDocument(recordingID: recording.id, audioVersion: recording.audioVersion,
            modifiedAt: modifiedAt, mutationID: mutationID, projectName: "AI-NoteTaker",
            transcript: transcript, insights: insights, actionStates: ["action-1": "open"],
            analysisModelID: "openrouter/test")
    }

    private func descriptor(for document: MeetingIntelligenceDocument) throws -> MeetingNotesDescriptor {
        let data = try encode(document)
        return MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt, revision: sha256Hex(data), byteCount: data.count)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeStoredDocument(library: LibraryStore, recordingID: UUID) throws -> MeetingIntelligenceDocument {
        let url = library.paths.directory(for: recordingID).appending(path: "meeting-intelligence.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingIntelligenceDocument.self, from: Data(contentsOf: url))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uuid(_ string: String) -> UUID {
        UUID(uuidString: string)!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MeetingDataSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

@MainActor
private final class CoordinatorMeetingDataTransport: SyncTransport, MeetingDataSyncTransport {
    var events: [String] = []
    var recordings: [UUID: Recording] = [:]
    var audio: [UUID: Data] = [:]
    var remoteProfile: MeetingUserProfile?
    var uploadedProfiles: [MeetingUserProfile?] = []
    var uploadedDocuments: [MeetingIntelligenceDocument] = []
    var uploadedEdits: [MeetingEdit] = []

    func health() async throws -> SyncHealth {
        SyncHealth(ok: true, schemaVersion: 1)
    }

    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        events.append("listRecordings")
        return SyncRecordingPage(recordings: recordings.values.sorted { $0.id.uuidString < $1.id.uuidString },
            nextCursor: nil)
    }

    func putRecording(_ recording: Recording) async throws -> Recording {
        events.append("putRecording")
        recordings[recording.id] = recording
        return recording
    }

    func uploadAudio(for recording: Recording, from url: URL) async throws {
        events.append("uploadAudio")
        audio[recording.id] = try Data(contentsOf: url)
    }

    func downloadAudio(for recording: Recording, to url: URL) async throws {
        events.append("downloadAudio")
        guard let data = audio[recording.id] else { throw SyncError.missingAudio(recording.id) }
        try data.write(to: url, options: .atomic)
    }

    func getMeetingProfile() async throws -> MeetingProfileResponse {
        events.append("getProfile")
        return MeetingProfileResponse(profile: remoteProfile)
    }

    func putMeetingProfile(_ upload: MeetingProfileUpload) async throws -> MeetingProfileResponse {
        events.append("putProfile")
        uploadedProfiles.append(upload.profile)
        if let profile = upload.profile, remoteProfile.map({ profile.wins(over: $0) }) ?? true {
            remoteProfile = profile
        }
        return MeetingProfileResponse(profile: remoteProfile)
    }

    func listMeetingIntelligence(cursor: String?) async throws -> MeetingIntelligencePage {
        events.append("listMeetingIntelligence")
        return MeetingIntelligencePage(intelligence: [], nextCursor: nil)
    }

    func uploadMeetingIntelligence(_ document: MeetingIntelligenceDocument, data: Data) async throws -> MeetingNotesDescriptor {
        events.append("uploadMeetingIntelligence")
        uploadedDocuments.append(document)
        return MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count)
    }

    func downloadMeetingIntelligence(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws {
        events.append("downloadMeetingIntelligence")
        throw SyncError.invalidResponse
    }

    func listMeetingEdits(after cursor: Int64) async throws -> MeetingEditPage {
        events.append("listMeetingEdits")
        return MeetingEditPage(entries: [], nextCursor: nil)
    }

    func uploadMeetingEdit(_ edit: MeetingEdit) async throws -> MeetingEditEntry {
        events.append("uploadMeetingEdit")
        uploadedEdits.append(edit)
        return MeetingEditEntry(sequence: Int64(uploadedEdits.count), edit: edit)
    }
}

@MainActor
private final class FakeMeetingDataTransport: MeetingDataSyncTransport {
    var remoteProfile: MeetingUserProfile?
    var uploadedProfiles: [MeetingUserProfile?] = []
    var profileCallOrder: [String] = []
    var remoteDocuments: [String: (descriptor: MeetingNotesDescriptor, data: Data)] = [:]
    var uploadedDocuments: [MeetingIntelligenceDocument] = []
    var editPages: [MeetingEditPage] = []
    var uploadedEdits: [MeetingEdit] = []
    var uploadedEditAttempts: [UUID] = []
    var failedEditIDs: Set<UUID> = []
    var afterListMeetingEdits: (() -> Void)?
    var afterUploadMeetingEdit: (() -> Void)?
    var downloadCount = 0

    func getMeetingProfile() async throws -> MeetingProfileResponse {
        profileCallOrder.append("get")
        return MeetingProfileResponse(profile: remoteProfile)
    }

    func putMeetingProfile(_ upload: MeetingProfileUpload) async throws -> MeetingProfileResponse {
        profileCallOrder.append("put")
        uploadedProfiles.append(upload.profile)
        if let profile = upload.profile, remoteProfile.map({ profile.wins(over: $0) }) ?? true {
            remoteProfile = profile
        }
        return MeetingProfileResponse(profile: remoteProfile)
    }

    func listMeetingIntelligence(cursor: String?) async throws -> MeetingIntelligencePage {
        let descriptors = remoteDocuments.values.map(\.descriptor).sorted {
            if $0.recordingID.uuidString == $1.recordingID.uuidString {
                return $0.audioVersion < $1.audioVersion
            }
            return $0.recordingID.uuidString < $1.recordingID.uuidString
        }
        let filtered = descriptors.filter { descriptor in
            guard let cursor else { return true }
            return "\(descriptor.recordingID.uuidString):\(String(format: "%010d", descriptor.audioVersion))" > cursor
        }
        return MeetingIntelligencePage(intelligence: filtered, nextCursor: nil)
    }

    func uploadMeetingIntelligence(_ document: MeetingIntelligenceDocument, data: Data) async throws -> MeetingNotesDescriptor {
        uploadedDocuments.append(document)
        let descriptor = MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count)
        remoteDocuments[key(for: descriptor)] = (descriptor, data)
        return descriptor
    }

    func downloadMeetingIntelligence(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws {
        guard let remote = remoteDocuments[key(for: descriptor)] else { throw SyncError.invalidResponse }
        downloadCount += 1
        try remote.data.write(to: url, options: .atomic)
    }

    func listMeetingEdits(after cursor: Int64) async throws -> MeetingEditPage {
        let page = editPages.isEmpty ? MeetingEditPage(entries: [], nextCursor: nil) : editPages.removeFirst()
        afterListMeetingEdits?()
        return page
    }

    func uploadMeetingEdit(_ edit: MeetingEdit) async throws -> MeetingEditEntry {
        uploadedEditAttempts.append(edit.id)
        afterUploadMeetingEdit?()
        if failedEditIDs.contains(edit.id) {
            throw SyncError.server(statusCode: 409, message: "fixture rejection")
        }
        uploadedEdits.append(edit)
        return MeetingEditEntry(sequence: Int64(uploadedEdits.count), edit: edit)
    }

    func storeRemote(_ document: MeetingIntelligenceDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let descriptor = MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count)
        remoteDocuments[key(for: descriptor)] = (descriptor, data)
    }

    private func key(for descriptor: MeetingNotesDescriptor) -> String {
        "\(descriptor.recordingID.uuidString):\(descriptor.audioVersion)"
    }
}

private nonisolated struct MeetingEditLogFixtureState: Encodable {
    var schemaVersion = 1
    let entries: [MeetingEditLogFixtureRecord]
    var workspaceStates: [String: MeetingEditLogFixtureWorkspaceState] = [:]
}

private nonisolated struct MeetingEditLogFixtureRecord: Encodable {
    let entry: MeetingEditEntry
    let acknowledgedWorkspaces: [String]
}

private nonisolated struct MeetingEditLogFixtureWorkspaceState: Encodable {
    var cursor: Int64 = 0
}

private func syncDefaults() throws -> UserDefaults {
    let suiteName = "MeetingDataSync.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private final class StubSyncTokenStore: SyncTokenStore {
    var storedToken: String?

    func loadToken() throws -> String? {
        storedToken
    }

    func saveToken(_ token: String) throws {
        storedToken = token
    }
}

private extension Array where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
