import Foundation
import Observation

nonisolated struct RecordingCollectionFolder: Identifiable, Codable, Hashable, Sendable {
    var schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Int64
    var mutationID: String
    var deletedAt: Date?
    var sortOrder: Int?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        modifiedAt: Int64? = nil,
        mutationID: String = UUID().uuidString.uppercased(),
        deletedAt: Date? = nil,
        sortOrder: Int? = nil
    ) {
        self.schemaVersion = 1
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? Self.milliseconds(since1970: createdAt)
        self.mutationID = mutationID.uppercased()
        self.deletedAt = deletedAt
        self.sortOrder = sortOrder
    }

    func wins(over other: RecordingCollectionFolder?) -> Bool {
        guard let other else { return true }
        if modifiedAt != other.modifiedAt {
            return modifiedAt > other.modifiedAt
        }
        return mutationID > other.mutationID
    }

    func locallyStamped(after previous: RecordingCollectionFolder?, now: Date = .now) -> RecordingCollectionFolder {
        var stamped = self
        let wallClock = Self.milliseconds(since1970: now)
        let floor = previous.map { $0.modifiedAt + 1 } ?? modifiedAt
        stamped.modifiedAt = max(wallClock, floor)
        stamped.mutationID = UUID().uuidString.uppercased()
        return stamped
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}

nonisolated enum RecordingFolderStoreError: Error, Equatable, Sendable {
    case folderNotFound(UUID)
    case folderDeleted(UUID)
    case duplicateName(String)
    case emptyName
    case nameTooLong
    case tooManyFolders
    case invalidMetadata(String)
    case metadataWriteFailed(String)
}

@MainActor
@Observable
final class RecordingFolderStore {
    private(set) var folders: [RecordingCollectionFolder]
    private let metadataURL: URL
    @ObservationIgnored private let loadError: RecordingFolderStoreError?

    var activeFolders: [RecordingCollectionFolder] {
        Self.sortedActiveFolders(folders)
    }

    init(paths: LibraryPaths) {
        self.metadataURL = Self.metadataURL(paths: paths)
        let result = Self.loadFolders(from: metadataURL)
        self.folders = result.folders
        self.loadError = result.error
    }

    func folder(id: UUID) -> RecordingCollectionFolder? {
        folders.first { $0.id == id }
    }

    func isActive(id: UUID) -> Bool {
        guard let folder = folder(id: id) else { return false }
        return folder.deletedAt == nil
    }

    @discardableResult
    func create(name: String) throws -> RecordingCollectionFolder {
        try ensureWritable()
        let normalizedName = try validatedName(name)
        guard activeFolders.count < Self.maximumLiveFolderCount else {
            throw RecordingFolderStoreError.tooManyFolders
        }
        try rejectDuplicateLiveName(normalizedName, excluding: nil)
        let result = createFolderInsertion(name: normalizedName)
        try persist(result.folders)
        folders = result.folders
        return result.folder
    }

    @discardableResult
    func rename(id: UUID, name: String) throws -> RecordingCollectionFolder {
        try ensureWritable()
        guard let existing = folder(id: id) else {
            throw RecordingFolderStoreError.folderNotFound(id)
        }
        guard existing.deletedAt == nil else {
            throw RecordingFolderStoreError.folderDeleted(id)
        }
        let normalizedName = try validatedName(name)
        try rejectDuplicateLiveName(normalizedName, excluding: id)
        var renamed = existing
        renamed.name = normalizedName
        renamed = renamed.locallyStamped(after: existing)
        try replace(renamed)
        return renamed
    }

    func delete(id: UUID, now: Date = .now) throws {
        try ensureWritable()
        guard let existing = folder(id: id) else {
            throw RecordingFolderStoreError.folderNotFound(id)
        }
        var deleted = existing
        deleted.deletedAt = now
        deleted = deleted.locallyStamped(after: existing, now: now)
        try replace(deleted)
    }

    func move(id: UUID, before destinationID: UUID?) throws {
        try ensureWritable()
        guard let source = folder(id: id) else {
            throw RecordingFolderStoreError.folderNotFound(id)
        }
        guard source.deletedAt == nil else {
            throw RecordingFolderStoreError.folderDeleted(id)
        }
        if destinationID == id {
            return
        }
        if let destinationID {
            guard let destination = folder(id: destinationID) else {
                throw RecordingFolderStoreError.folderNotFound(destinationID)
            }
            guard destination.deletedAt == nil else {
                throw RecordingFolderStoreError.folderDeleted(destinationID)
            }
        }

        var reordered = activeFolders
        guard let sourceIndex = reordered.firstIndex(where: { $0.id == id }) else {
            throw RecordingFolderStoreError.folderNotFound(id)
        }
        if destinationID == nil && sourceIndex == reordered.index(before: reordered.endIndex) {
            return
        }
        if let destinationID,
           sourceIndex < reordered.index(before: reordered.endIndex),
           reordered[reordered.index(after: sourceIndex)].id == destinationID {
            return
        }

        let moved = reordered.remove(at: sourceIndex)
        if let destinationID,
           let destinationIndex = reordered.firstIndex(where: { $0.id == destinationID }) {
            reordered.insert(moved, at: destinationIndex)
        } else {
            reordered.append(moved)
        }

        let reranked = rerank(reordered)
        guard !reranked.isEmpty else { return }

        var updated = folders
        for folder in reranked {
            if let index = updated.firstIndex(where: { $0.id == folder.id }) {
                updated[index] = folder
            }
        }
        try persist(updated)
        folders = updated
    }

    func applyRemote(_ remote: RecordingCollectionFolder) throws {
        try ensureWritable()
        try validate(remote)
        let existing = folder(id: remote.id)
        guard remote.wins(over: existing) else { return }
        var merged = remote
        if merged.sortOrder == nil {
            merged.sortOrder = existing?.sortOrder
        }
        try replace(merged)
    }

    private func rerank(_ reordered: [RecordingCollectionFolder]) -> [RecordingCollectionFolder] {
        var changed: [RecordingCollectionFolder] = []
        for (index, folder) in reordered.enumerated() where folder.sortOrder != index {
            var reranked = folder
            reranked.sortOrder = index
            reranked = reranked.locallyStamped(after: folder)
            changed.append(reranked)
        }
        return changed
    }

    private func createFolderInsertion(name: String) -> (folder: RecordingCollectionFolder, folders: [RecordingCollectionFolder]) {
        var folder = RecordingCollectionFolder(name: name)
        var updated = folders
        let active = activeFolders
        guard active.contains(where: { $0.sortOrder != nil }) else {
            updated.append(folder)
            return (folder, updated)
        }

        let needsNormalization = active.contains(where: { $0.sortOrder == nil })
            || active.contains(where: { $0.sortOrder == Self.maximumSortOrder })
        if needsNormalization {
            folder.sortOrder = active.count
            let changed = rerank(active)
            for folder in changed {
                if let index = updated.firstIndex(where: { $0.id == folder.id }) {
                    updated[index] = folder
                }
            }
        } else {
            folder.sortOrder = (active.compactMap(\.sortOrder).max() ?? -1) + 1
        }
        updated.append(folder)
        return (folder, updated)
    }

    private func replace(_ folder: RecordingCollectionFolder) throws {
        var updated = folders
        if let index = updated.firstIndex(where: { $0.id == folder.id }) {
            updated[index] = folder
        } else {
            updated.append(folder)
        }
        try persist(updated)
        folders = updated
    }

    private func persist(_ folders: [RecordingCollectionFolder]) throws {
        do {
            let data = try Self.encoder.encode(FolderFile(folders: folders))
            guard data.count <= Self.maximumMetadataBytes else {
                throw RecordingFolderStoreError.invalidMetadata("Folder metadata exceeds 512 KiB.")
            }
            guard folders.count <= Self.maximumStoredFolderCount else {
                throw RecordingFolderStoreError.invalidMetadata("Folder metadata contains too many entries.")
            }
            guard folders.filter({ $0.deletedAt == nil }).count <= Self.maximumLiveFolderCount else {
                throw RecordingFolderStoreError.tooManyFolders
            }
            try FileManager.default.createDirectory(
                at: metadataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw RecordingFolderStoreError.metadataWriteFailed(String(describing: error))
        }
    }

    private func ensureWritable() throws {
        if let loadError {
            throw loadError
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecordingFolderStoreError.emptyName
        }
        guard trimmed.count <= Self.maximumNameCharacters,
              trimmed.lengthOfBytes(using: .utf8) <= Self.maximumNameBytes
        else {
            throw RecordingFolderStoreError.nameTooLong
        }
        return trimmed
    }

    private func validate(_ folder: RecordingCollectionFolder) throws {
        _ = try validatedName(folder.name)
        guard folder.schemaVersion == 1 else { throw RecordingFolderStoreError.invalidMetadata("Unsupported folder schema version.") }
        guard folder.modifiedAt >= 0 && folder.modifiedAt <= Self.maximumSafeInteger else {
            throw RecordingFolderStoreError.invalidMetadata("Folder modifiedAt is out of range.")
        }
        guard UUID(uuidString: folder.mutationID)?.uuidString == folder.mutationID else {
            throw RecordingFolderStoreError.invalidMetadata("Folder mutationID must be a canonical uppercase UUID.")
        }
        guard folder.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecordingFolderStoreError.invalidMetadata("Folder createdAt is invalid.")
        }
        guard folder.deletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw RecordingFolderStoreError.invalidMetadata("Folder deletedAt is invalid.")
        }
        guard Self.validSortOrder(folder.sortOrder) else {
            throw RecordingFolderStoreError.invalidMetadata("Folder sortOrder is out of range.")
        }
    }

    private func rejectDuplicateLiveName(_ name: String, excluding id: UUID?) throws {
        let folded = Self.foldedName(name)
        if activeFolders.contains(where: { $0.id != id && Self.foldedName($0.name) == folded }) {
            throw RecordingFolderStoreError.duplicateName(name)
        }
    }

    nonisolated private static func metadataURL(paths: LibraryPaths) -> URL {
        paths.libraryRoot.appending(path: "recording-folders.json")
    }

    nonisolated private static func loadFolders(from url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(folders: [], error: nil)
        }
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= maximumMetadataBytes
        else {
            return LoadResult(folders: [], error: .invalidMetadata("Folder metadata exceeds 512 KiB."))
        }
        let file: FolderFile
        do {
            let data = try Data(contentsOf: url)
            file = try decoder.decode(FolderFile.self, from: data)
        } catch {
            return LoadResult(folders: [], error: .invalidMetadata("Folder metadata could not be decoded."))
        }
        guard file.folders.count <= maximumStoredFolderCount else {
            return LoadResult(folders: [], error: .invalidMetadata("Folder metadata contains too many entries."))
        }
        guard file.folders.filter({ $0.deletedAt == nil }).count <= maximumLiveFolderCount else {
            return LoadResult(folders: [], error: .tooManyFolders)
        }
        var byID: [UUID: RecordingCollectionFolder] = [:]
        for folder in file.folders {
            do {
                try validateLoadedFolder(folder)
            } catch {
                return LoadResult(folders: [], error: .invalidMetadata("Folder metadata contains an invalid entry."))
            }
            if folder.wins(over: byID[folder.id]) {
                byID[folder.id] = folder
            }
        }
        return LoadResult(
            folders: byID.values.sorted { lhs, rhs in lhs.id.uuidString < rhs.id.uuidString },
            error: nil
        )
    }

    nonisolated private static func validateLoadedFolder(_ folder: RecordingCollectionFolder) throws {
        let trimmed = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecordingFolderStoreError.emptyName }
        guard folder.schemaVersion == 1,
              trimmed == folder.name,
              trimmed.count <= maximumNameCharacters,
              trimmed.lengthOfBytes(using: .utf8) <= maximumNameBytes,
              folder.modifiedAt >= 0,
              folder.modifiedAt <= maximumSafeInteger,
              UUID(uuidString: folder.mutationID)?.uuidString == folder.mutationID,
              folder.createdAt.timeIntervalSinceReferenceDate.isFinite,
              folder.deletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              validSortOrder(folder.sortOrder)
        else {
            throw RecordingFolderStoreError.invalidMetadata("Invalid folder metadata.")
        }
    }

    nonisolated private static func sortedActiveFolders(_ folders: [RecordingCollectionFolder]) -> [RecordingCollectionFolder] {
        let active = folders.filter { $0.deletedAt == nil }
        let hasCustomOrdering = active.contains { $0.sortOrder != nil }
        return active.sorted { lhs, rhs in
            if hasCustomOrdering {
                let lhsOrder = lhs.sortOrder ?? Int.max
                let rhsOrder = rhs.sortOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    nonisolated private static func validSortOrder(_ sortOrder: Int?) -> Bool {
        guard let sortOrder else { return true }
        return sortOrder >= 0 && sortOrder <= maximumSortOrder
    }

    nonisolated private static func foldedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated private static let maximumNameCharacters = 120
    nonisolated private static let maximumNameBytes = 512
    nonisolated private static let maximumMetadataBytes = 512 * 1_024
    nonisolated private static let maximumLiveFolderCount = 256
    nonisolated private static let maximumStoredFolderCount = 512
    nonisolated private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    nonisolated private static let maximumSortOrder = 9_007_199_254_740_991

    nonisolated private struct FolderFile: Codable, Sendable {
        let folders: [RecordingCollectionFolder]
    }

    nonisolated private struct LoadResult: Sendable {
        let folders: [RecordingCollectionFolder]
        let error: RecordingFolderStoreError?
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
