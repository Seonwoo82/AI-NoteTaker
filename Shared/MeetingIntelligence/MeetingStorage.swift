import CryptoKit
import Foundation
import Observation

nonisolated enum MeetingStorageError: LocalizedError, Equatable, Sendable {
    case missingRecording(UUID)
    case deletedRecording(UUID)
    case audioVersionMismatch
    case invalidDescriptor
    case documentTooLarge
    case editLogTooLarge
    case invalidEditPage
    case editConflict(UUID)
    case editLogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .missingRecording(id):
            "Recording \(id.uuidString) is missing."
        case let .deletedRecording(id):
            "Recording \(id.uuidString) is deleted."
        case .audioVersionMismatch:
            "Meeting intelligence is for a different audio version."
        case .invalidDescriptor:
            "The meeting intelligence descriptor is invalid."
        case .documentTooLarge:
            "Meeting intelligence is larger than the 4 MiB sync limit."
        case .editLogTooLarge:
            "Meeting edit history is larger than the 16 MiB sync limit."
        case .invalidEditPage:
            "The meeting edit page is invalid."
        case let .editConflict(id):
            "Meeting edit \(id.uuidString) conflicts with an existing edit."
        case let .editLogUnavailable(message):
            message
        }
    }
}

@MainActor
@Observable
final class MeetingIntelligenceStore {
    private(set) var documents: [UUID: MeetingIntelligenceDocument] = [:]

    @ObservationIgnored var onDocumentSaved: ((UUID) -> Void)?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    init(library: LibraryStore, fileManager: FileManager = .default) {
        self.library = library
        self.fileManager = fileManager
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    func document(for recordingID: UUID) -> MeetingIntelligenceDocument? {
        guard let recording = library.recording(id: recordingID),
              recording.deletedAt == nil,
              !isLocallyPurged(recordingID),
              let cached = documents[recordingID],
              cached.audioVersion == recording.audioVersion
        else { return nil }
        return cached
    }

    @discardableResult
    func load(_ recording: Recording) async -> MeetingIntelligenceDocument? {
        guard let loaded = try? loadDocument(for: recording) else {
            return nil
        }
        documents[recording.id] = loaded
        return loaded
    }

    func save(_ document: MeetingIntelligenceDocument) async throws {
        try Task.checkCancellation()
        let recording = try currentRecording(for: document.recordingID)
        guard recording.audioVersion == document.audioVersion else { throw MeetingStorageError.audioVersionMismatch }
        try document.validate(duration: recording.duration)
        let data = try encoder.encode(document)
        guard !data.isEmpty, data.count <= MeetingIntelligenceDocument.maximumEncodedByteCount else {
            throw MeetingStorageError.documentTooLarge
        }
        if let existing = try loadDocument(for: recording) {
            let existingData = try readData(from: intelligenceURL(for: recording.id))
            if existing == document, existingData == data {
                documents[recording.id] = existing
                return
            }
            if existing.wins(over: document) {
                documents[recording.id] = existing
                return
            }
        }
        try Task.checkCancellation()
        let latest = try currentRecording(for: document.recordingID)
        guard latest.audioVersion == document.audioVersion else { throw MeetingStorageError.audioVersionMismatch }
        try write(data, to: intelligenceURL(for: recording.id))
        documents[recording.id] = document
        onDocumentSaved?(recording.id)
    }

    func applyRemote(data: Data, descriptor: MeetingNotesDescriptor) async throws {
        let recording = try currentRecording(for: descriptor.recordingID)
        let document = try validateDownloadedDescriptor(descriptor, data: data, recording: recording)
        _ = try await publishRemote(document, data: data, descriptor: descriptor)
    }

    func localDescriptor(for recording: Recording) throws -> MeetingNotesDescriptor? {
        guard let document = try loadDocument(for: recording) else { return nil }
        let data = try readData(from: intelligenceURL(for: recording.id))
        return MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt, revision: Self.sha256Hex(data), byteCount: data.count)
    }

    func localDocumentWithData(for recording: Recording) throws -> (document: MeetingIntelligenceDocument, data: Data, descriptor: MeetingNotesDescriptor)? {
        guard let document = try loadDocument(for: recording) else { return nil }
        let data = try readData(from: intelligenceURL(for: recording.id))
        let descriptor = MeetingNotesDescriptor(recordingID: document.recordingID, audioVersion: document.audioVersion,
            generatedAtMillis: document.modifiedAt, revision: Self.sha256Hex(data), byteCount: data.count)
        return (document, data, descriptor)
    }

    func readDownloadedData(from url: URL) throws -> Data {
        try readData(from: url)
    }

    func validateDownloadedDescriptor(
        _ descriptor: MeetingNotesDescriptor,
        data: Data,
        recording: Recording
    ) throws -> MeetingIntelligenceDocument {
        guard data.count == descriptor.byteCount,
              data.count > 0,
              data.count <= MeetingIntelligenceDocument.maximumEncodedByteCount,
              Self.sha256Hex(data) == descriptor.revision
        else {
            throw MeetingStorageError.invalidDescriptor
        }
        let document = try decoder.decode(MeetingIntelligenceDocument.self, from: data)
        guard document.recordingID == descriptor.recordingID,
              document.audioVersion == descriptor.audioVersion,
              document.modifiedAt == descriptor.generatedAtMillis,
              recording.audioVersion == descriptor.audioVersion
        else {
            throw MeetingStorageError.invalidDescriptor
        }
        try document.validate(duration: recording.duration)
        return document
    }

    @discardableResult
    func publishRemote(
        _ document: MeetingIntelligenceDocument,
        data: Data,
        descriptor: MeetingNotesDescriptor
    ) async throws -> Bool {
        try Task.checkCancellation()
        let recording = try currentRecording(for: descriptor.recordingID)
        let validated = try validateDownloadedDescriptor(descriptor, data: data, recording: recording)
        guard validated == document else { throw MeetingStorageError.invalidDescriptor }
        if let existing = try loadDocument(for: recording) {
            let existingData = try readData(from: intelligenceURL(for: recording.id))
            if existing == document, existingData == data {
                documents[recording.id] = existing
                return false
            }
            if existing.wins(over: document) {
                documents[recording.id] = existing
                return false
            }
        }
        try Task.checkCancellation()
        let latest = try currentRecording(for: descriptor.recordingID)
        guard latest.audioVersion == descriptor.audioVersion else { throw MeetingStorageError.audioVersionMismatch }
        try write(data, to: intelligenceURL(for: recording.id))
        documents[recording.id] = document
        return true
    }

    func allDocuments() async -> [MeetingIntelligenceDocument] {
        var result: [MeetingIntelligenceDocument] = []
        for recording in library.recordings where recording.deletedAt == nil && !isLocallyPurged(recording.id) {
            if let document = try? loadDocument(for: recording) {
                documents[recording.id] = document
                result.append(document)
            }
        }
        return result
    }

    func data(for document: MeetingIntelligenceDocument) throws -> Data {
        try readData(from: intelligenceURL(for: document.recordingID))
    }

    private func loadDocument(for recording: Recording) throws -> MeetingIntelligenceDocument? {
        guard recording.deletedAt == nil, !isLocallyPurged(recording.id) else { return nil }
        let url = intelligenceURL(for: recording.id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try readData(from: url)
        let document = try decoder.decode(MeetingIntelligenceDocument.self, from: data)
        guard document.recordingID == recording.id else { throw MeetingStorageError.invalidDescriptor }
        guard document.audioVersion == recording.audioVersion else { return nil }
        try document.validate(duration: recording.duration)
        return document
    }

    private func readData(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw MeetingStorageError.invalidDescriptor }
        guard size <= MeetingIntelligenceDocument.maximumEncodedByteCount else { throw MeetingStorageError.documentTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MeetingIntelligenceDocument.maximumEncodedByteCount + 1) ?? Data()
        guard data.count > 0 else { throw MeetingStorageError.invalidDescriptor }
        guard data.count <= MeetingIntelligenceDocument.maximumEncodedByteCount else {
            throw MeetingStorageError.documentTooLarge
        }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func currentRecording(for id: UUID) throws -> Recording {
        guard let recording = library.recording(id: id) else { throw MeetingStorageError.missingRecording(id) }
        guard recording.deletedAt == nil, !isLocallyPurged(id) else { throw MeetingStorageError.deletedRecording(id) }
        return recording
    }

    private func intelligenceURL(for recordingID: UUID) -> URL {
        library.paths.directory(for: recordingID).appending(path: "meeting-intelligence.json")
    }

    private func isLocallyPurged(_ recordingID: UUID) -> Bool {
        fileManager.fileExists(atPath: library.paths.directory(for: recordingID).appending(path: ".purged").path)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class MeetingEditLog {
    private(set) var entries: [MeetingEditEntry] = []
    private(set) var loadError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let writeData: (Data, URL) throws -> Void
    @ObservationIgnored private var state: MeetingEditLogState

    init(root: URL, writeData: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) {
        self.root = root
        self.url = root.appending(path: "meeting-edits.json")
        self.writeData = writeData
        let loaded: MeetingEditLogState
        do {
            loaded = try Self.load(from: url) ?? MeetingEditLogState()
        } catch {
            self.loadError = Self.loadErrorMessage
            loaded = MeetingEditLogState()
        }
        self.state = loaded
        self.entries = loaded.entries.map { $0.entry }
    }

    @discardableResult
    func append(recordingID: UUID, audioVersion: Int, kind: MeetingEditKind, targetID: String, value: String) throws -> MeetingEdit {
        try ensureAvailable()
        let latestKnown = state.entries.map(\.entry.edit.modifiedAt).max() ?? 0
        let timestamp = max(Self.millisecondsSince1970(), min(latestKnown + 1, 9_007_199_254_740_991))
        let edit = MeetingEdit(id: UUID(), recordingID: recordingID, audioVersion: audioVersion,
            modifiedAt: timestamp, kind: kind, targetID: targetID, value: value)
        try edit.validate(recordingID: recordingID, audioVersion: audioVersion)
        try merge(entry: MeetingEditEntry(sequence: 0, edit: edit), acknowledgedWorkspace: nil)
        return edit
    }

    func edits(for recordingID: UUID, audioVersion: Int) -> [MeetingEdit] {
        entries
            .map(\.edit)
            .filter { $0.recordingID == recordingID && $0.audioVersion == audioVersion }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func pending(workspace: String) -> [MeetingEdit] {
        let key = workspaceKey(workspace)
        return state.entries
            .filter { !$0.acknowledgedWorkspaces.contains(key) }
            .map(\.entry.edit)
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func acknowledge(entry: MeetingEditEntry, workspace: String) throws {
        try ensureAvailable()
        try merge(entry: entry, acknowledgedWorkspace: workspaceKey(workspace), shouldAdvanceCursor: false,
            shouldNotify: false)
    }

    func ingest(page: MeetingEditPage, workspace: String) throws {
        try ensureAvailable()
        guard page.nextCursor == nil || !page.entries.isEmpty else {
            throw MeetingStorageError.invalidEditPage
        }
        let key = workspaceKey(workspace)
        var updated = state
        var last = updated.workspaceStates[key]?.cursor ?? 0
        for entry in page.entries {
            guard entry.sequence > last else { throw MeetingStorageError.invalidEditPage }
            try entry.edit.validate(recordingID: entry.edit.recordingID, audioVersion: entry.edit.audioVersion)
            try merge(entry: entry, acknowledgedWorkspace: key, into: &updated)
            last = entry.sequence
        }
        if let nextCursor = page.nextCursor, nextCursor < last {
            throw MeetingStorageError.invalidEditPage
        }
        updated.workspaceStates[key, default: MeetingEditWorkspaceState()].cursor = last
        try persist(updated)
        state = updated
        refreshEntries()
    }

    func cursor(workspace: String) -> Int64 {
        state.workspaceStates[workspaceKey(workspace)]?.cursor ?? 0
    }

    private func merge(
        entry: MeetingEditEntry,
        acknowledgedWorkspace: String?,
        shouldAdvanceCursor: Bool = false,
        shouldNotify: Bool = true
    ) throws {
        try ensureAvailable()
        var updated = state
        try merge(entry: entry, acknowledgedWorkspace: acknowledgedWorkspace, shouldAdvanceCursor: shouldAdvanceCursor, into: &updated)
        try persist(updated)
        state = updated
        refreshEntries()
        if shouldNotify { onChange?() }
    }

    private func merge(
        entry: MeetingEditEntry,
        acknowledgedWorkspace: String?,
        shouldAdvanceCursor: Bool = false,
        into state: inout MeetingEditLogState
    ) throws {
        let normalizedSequence = max(0, entry.sequence)
        let normalizedEntry = MeetingEditEntry(sequence: normalizedSequence, edit: entry.edit)
        if let index = state.entries.firstIndex(where: { $0.entry.edit.id == entry.edit.id }) {
            guard state.entries[index].entry.edit == entry.edit else {
                throw MeetingStorageError.editConflict(entry.edit.id)
            }
            if normalizedSequence > 0 {
                state.entries[index].entry = normalizedEntry
            }
            if let acknowledgedWorkspace {
                state.entries[index].acknowledgedWorkspaces.insert(acknowledgedWorkspace)
                if shouldAdvanceCursor {
                    state.workspaceStates[acknowledgedWorkspace, default: MeetingEditWorkspaceState()].cursor = normalizedSequence
                }
            }
        } else {
            state.entries.append(MeetingEditLogRecord(entry: normalizedEntry,
                acknowledgedWorkspaces: acknowledgedWorkspace.map { [$0] } ?? []))
            if let acknowledgedWorkspace, shouldAdvanceCursor {
                state.workspaceStates[acknowledgedWorkspace, default: MeetingEditWorkspaceState()].cursor = normalizedSequence
            }
        }
    }

    private func persist(_ state: MeetingEditLogState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        guard data.count <= Self.maximumEncodedByteCount else { throw MeetingStorageError.editLogTooLarge }
        try writeData(data, url)
    }

    private func ensureAvailable() throws {
        guard loadError == nil else { throw MeetingStorageError.editLogUnavailable(Self.loadErrorMessage) }
    }

    private func refreshEntries() {
        entries = state.entries
            .map(\.entry)
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.edit.id.uuidString < $1.edit.id.uuidString
            }
    }

    private func workspaceKey(_ workspace: String) -> String {
        workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func load(from url: URL) throws -> MeetingEditLogState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumEncodedByteCount + 1) ?? Data()
        guard data.count <= maximumEncodedByteCount else { throw MeetingStorageError.editLogTooLarge }
        var state = try decoder.decode(MeetingEditLogState.self, from: data)
        try state.validate()
        state.entries.sort {
            if $0.entry.sequence != $1.entry.sequence { return $0.entry.sequence < $1.entry.sequence }
            return $0.entry.edit.id.uuidString < $1.entry.edit.id.uuidString
        }
        return state
    }

    private static func millisecondsSince1970(date: Date = Date()) -> Int64 {
        min(Int64(date.timeIntervalSince1970 * 1_000), 9_007_199_254_740_991)
    }

    nonisolated static let maximumEncodedByteCount = 16 * 1_024 * 1_024
    private static let loadErrorMessage = "회의 편집 로그를 불러오지 못했어요. 기존 기록을 보호하기 위해 복구 전까지 새 편집을 저장하지 않습니다."

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

private nonisolated struct MeetingEditLogState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var entries: [MeetingEditLogRecord] = []
    var workspaceStates: [String: MeetingEditWorkspaceState] = [:]

    mutating func validate() throws {
        guard schemaVersion == 1 else { throw MeetingStorageError.invalidEditPage }
        var ids = Set<UUID>()
        for record in entries {
            guard ids.insert(record.entry.edit.id).inserted else {
                throw MeetingStorageError.editConflict(record.entry.edit.id)
            }
            try record.entry.edit.validate(recordingID: record.entry.edit.recordingID,
                audioVersion: record.entry.edit.audioVersion)
            guard record.entry.sequence >= 0 else { throw MeetingStorageError.invalidEditPage }
        }
        for state in workspaceStates.values where state.cursor < 0 {
            throw MeetingStorageError.invalidEditPage
        }
    }
}

private nonisolated struct MeetingEditLogRecord: Codable, Equatable, Sendable {
    var entry: MeetingEditEntry
    var acknowledgedWorkspaces: Set<String>
}

private nonisolated struct MeetingEditWorkspaceState: Codable, Equatable, Sendable {
    var cursor: Int64 = 0
}

extension MeetingIntelligenceDocument {
    func wins(over other: MeetingIntelligenceDocument) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && mutationID.uuidString > other.mutationID.uuidString)
    }
}
