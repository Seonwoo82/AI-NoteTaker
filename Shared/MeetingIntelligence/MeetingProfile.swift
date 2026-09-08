import Foundation
import Observation

nonisolated enum GlossaryCategory: String, CaseIterable, Codable, Equatable, Sendable {
    case person
    case organization
    case project
    case abbreviation
    case general
}

nonisolated struct GlossaryTerm: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var term: String
    var spokenAs: String
    var meaning: String
    var category: GlossaryCategory

    init(
        id: UUID = UUID(),
        term: String,
        spokenAs: String = "",
        meaning: String = "",
        category: GlossaryCategory = .general
    ) {
        self.id = id
        self.term = term
        self.spokenAs = spokenAs
        self.meaning = meaning
        self.category = category
    }

    func validate() throws {
        try MeetingProfileValidation.validateText(term, maxUTF8Bytes: 120, allowEmpty: false)
        try MeetingProfileValidation.validateText(spokenAs, maxUTF8Bytes: 120, allowEmpty: true)
        try MeetingProfileValidation.validateText(meaning, maxUTF8Bytes: 500, allowEmpty: true)
    }
}

nonisolated struct GlossaryDisplayRange: Codable, Equatable, Sendable {
    let location: Int
    let length: Int
}

nonisolated struct GlossaryDisplaySubstitution: Codable, Equatable, Sendable {
    let termID: UUID
    let sourceText: String
    let displayText: String
    let utf16Range: GlossaryDisplayRange
}

nonisolated struct MeetingUserProfile: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var displayName: String
    var aliases: [String]
    var role: String
    var automaticallyAnalyze: Bool
    var terms: [GlossaryTerm]
    var modifiedAt: Int64
    var mutationID: UUID

    init(
        displayName: String = "",
        aliases: [String] = [],
        role: String = "",
        automaticallyAnalyze: Bool = false,
        terms: [GlossaryTerm] = [],
        modifiedAt: Int64 = 0,
        mutationID: UUID = UUID()
    ) {
        self.displayName = displayName
        self.aliases = aliases
        self.role = role
        self.automaticallyAnalyze = automaticallyAnalyze
        self.terms = terms
        self.modifiedAt = modifiedAt
        self.mutationID = mutationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        displayName = try container.decode(String.self, forKey: .displayName)
        aliases = try container.decode([String].self, forKey: .aliases)
        role = try container.decode(String.self, forKey: .role)
        automaticallyAnalyze = try container.decodeIfPresent(Bool.self, forKey: .automaticallyAnalyze) ?? false
        terms = try container.decode([GlossaryTerm].self, forKey: .terms)
        modifiedAt = try container.decode(Int64.self, forKey: .modifiedAt)
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
    }

    var isEmpty: Bool {
        displayName.isEmpty && aliases.isEmpty && role.isEmpty && !automaticallyAnalyze && terms.isEmpty
    }

    var promptContext: String {
        var lines: [String] = []
        if !displayName.isEmpty { lines.append("Owner: \(displayName)") }
        if !aliases.isEmpty { lines.append("Owner aliases: \(aliases.joined(separator: ", "))") }
        if !role.isEmpty { lines.append("Owner role: \(role)") }
        let glossaryLines = terms.map { term in
            let spoken = term.spokenAs.isEmpty ? "" : " (spoken as: \(term.spokenAs))"
            let meaning = term.meaning.isEmpty ? "" : " - \(term.meaning)"
            return "- [\(term.category.rawValue)] \(term.term)\(spoken)\(meaning)"
        }
        if !glossaryLines.isEmpty {
            lines.append("Glossary:")
            lines.append(contentsOf: glossaryLines)
        }
        return MeetingProfileValidation.truncatedUTF8(lines.joined(separator: "\n"), maxBytes: 12_000)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw MeetingProfileValidationError.unsupportedSchemaVersion }
        try MeetingProfileValidation.validateText(displayName, maxUTF8Bytes: 120, allowEmpty: true)
        try MeetingProfileValidation.validateText(role, maxUTF8Bytes: 160, allowEmpty: true)
        guard aliases.count <= 24, terms.count <= 200 else { throw MeetingProfileValidationError.tooLarge }
        var seenAliases = Set<String>()
        for alias in aliases {
            try MeetingProfileValidation.validateText(alias, maxUTF8Bytes: 120, allowEmpty: false)
            guard seenAliases.insert(alias.normalizedProfileKey).inserted else {
                throw MeetingProfileValidationError.duplicateValue
            }
        }
        var seenTerms = Set<UUID>()
        for term in terms {
            try term.validate()
            guard seenTerms.insert(term.id).inserted else { throw MeetingProfileValidationError.duplicateValue }
        }
        guard modifiedAt >= 0, modifiedAt <= MeetingProfileValidation.maxSafeInteger else {
            throw MeetingProfileValidationError.invalidTimestamp
        }
        try MeetingProfileValidation.validateSharedProfileEncoding(self)
    }

    func wins(over other: Self) -> Bool {
        modifiedAt > other.modifiedAt
            || (modifiedAt == other.modifiedAt && mutationID.uuidString > other.mutationID.uuidString)
    }

    func glossaryDisplaySubstitutions(in sourceText: String) -> [GlossaryDisplaySubstitution] {
        guard !sourceText.isEmpty else { return [] }
        let nsSource = sourceText as NSString
        var substitutions: [GlossaryDisplaySubstitution] = []
        var occupiedRanges: [NSRange] = []
        for term in terms {
            let spoken = term.spokenAs.trimmingCharacters(in: .whitespacesAndNewlines)
            let needle = spoken.isEmpty ? term.term.trimmingCharacters(in: .whitespacesAndNewlines) : spoken
            guard !needle.isEmpty, term.term != needle else { continue }
            var searchRange = NSRange(location: 0, length: nsSource.length)
            while searchRange.length > 0 {
                let found = nsSource.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                if !occupiedRanges.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    substitutions.append(GlossaryDisplaySubstitution(
                        termID: term.id,
                        sourceText: nsSource.substring(with: found),
                        displayText: term.term,
                        utf16Range: GlossaryDisplayRange(location: found.location, length: found.length)
                    ))
                    occupiedRanges.append(found)
                }
                let nextLocation = found.location + max(found.length, 1)
                guard nextLocation < nsSource.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsSource.length - nextLocation)
            }
        }
        return substitutions.sorted {
            if $0.utf16Range.location != $1.utf16Range.location {
                return $0.utf16Range.location < $1.utf16Range.location
            }
            return $0.utf16Range.length > $1.utf16Range.length
        }
    }
}

nonisolated struct LocalVoiceProfile: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let modelID: String
    let embedding: [Float]
    let enrolledAt: Date
    let sampleDuration: Double

    init(modelID: String, embedding: [Float], enrolledAt: Date, sampleDuration: Double) {
        self.modelID = modelID
        self.embedding = embedding
        self.enrolledAt = enrolledAt
        self.sampleDuration = sampleDuration
    }

    func validate(allowedDimensions: ClosedRange<Int> = 1...MeetingProfileValidation.maximumEmbeddingDimensions) throws {
        guard schemaVersion == 1 else { throw MeetingProfileValidationError.unsupportedSchemaVersion }
        try MeetingProfileValidation.validateText(modelID, maxUTF8Bytes: 256, allowEmpty: false)
        guard allowedDimensions.contains(embedding.count),
              embedding.count <= MeetingProfileValidation.maximumEmbeddingDimensions else {
            throw MeetingProfileValidationError.invalidEmbedding
        }
        guard embedding.allSatisfy({ $0.isFinite }) else { throw MeetingProfileValidationError.invalidEmbedding }
        guard sampleDuration.isFinite, sampleDuration > 0, sampleDuration <= 600 else {
            throw MeetingProfileValidationError.invalidSampleDuration
        }
    }
}

enum MeetingProfileValidationError: Error, Equatable {
    case unsupportedSchemaVersion
    case invalidText
    case tooLarge
    case duplicateValue
    case invalidTimestamp
    case invalidEmbedding
    case invalidSampleDuration
}

@MainActor
@Observable
final class MeetingProfileStore {
    private(set) var profile: MeetingUserProfile
    private(set) var localVoice: LocalVoiceProfile?
    private(set) var lastError: String?

    @ObservationIgnored var onProfileChanged: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let fileStore: MeetingProfileFileStore
    @ObservationIgnored private var syncState: MeetingProfileSyncState

    var pendingProfileUpload: MeetingUserProfile? {
        shouldUploadProfile ? profile : nil
    }

    init(root: URL) {
        self.root = root
        self.fileStore = MeetingProfileFileStore(root: root)
        var loadedError: (any Error)?
        var loadedProfile = MeetingUserProfile()
        var loadedVoice: LocalVoiceProfile?
        var loadedState = MeetingProfileSyncState()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            loadedError = error
        }
        do {
            loadedProfile = try fileStore.loadSharedProfile() ?? MeetingUserProfile()
            try loadedProfile.validate()
        } catch {
            loadedProfile = MeetingUserProfile()
            loadedError = error
        }
        do {
            loadedState = try fileStore.loadSyncState() ?? MeetingProfileSyncState()
            try loadedState.validate()
        } catch {
            loadedState = MeetingProfileSyncState()
            loadedError = error
        }
        do {
            loadedVoice = try fileStore.loadLocalVoiceProfile()
            try loadedVoice?.validate()
        } catch {
            loadedVoice = nil
            loadedError = error
        }
        self.profile = loadedProfile
        self.localVoice = loadedVoice
        self.syncState = loadedState
        self.lastError = loadedError.map { Self.message(for: $0) }
    }

    func updateProfile(_ mutate: (inout MeetingUserProfile) -> Void) throws {
        var updated = profile
        mutate(&updated)
        updated.modifiedAt = max(
            MeetingProfileValidation.millisecondsSince1970(),
            min(profile.modifiedAt + 1, MeetingProfileValidation.maxSafeInteger)
        )
        updated.mutationID = UUID()
        try updated.validate()
        try fileStore.saveSharedProfile(updated)
        var updatedState = syncState
        updatedState.allowNextRemoteAdoption = false
        try fileStore.saveSyncState(updatedState)
        profile = updated
        syncState = updatedState
        lastError = nil
        onProfileChanged?()
    }

    @discardableResult
    func applyRemoteProfile(_ remote: MeetingUserProfile) throws -> Bool {
        try remote.validate()
        guard syncState.allowNextRemoteAdoption || remote.wins(over: profile) else {
            return false
        }
        try fileStore.saveSharedProfile(remote)
        var updatedState = syncState
        updatedState.allowNextRemoteAdoption = false
        updatedState.lastAcknowledgedMutationID = remote.mutationID
        try fileStore.saveSyncState(updatedState)
        profile = remote
        syncState = updatedState
        lastError = nil
        return true
    }

    @discardableResult
    func markProfileUploadFinished(_ uploaded: MeetingUserProfile) -> Bool {
        guard shouldUploadProfile, uploaded == profile else { return true }
        var updatedState = syncState
        updatedState.lastAcknowledgedMutationID = uploaded.mutationID
        do {
            try fileStore.saveSyncState(updatedState)
            syncState = updatedState
            lastError = nil
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func setSyncWorkspace(_ endpoint: String) -> Bool {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEndpoint.isEmpty else { return false }
        guard syncState.workspaceEndpoint != normalizedEndpoint else { return true }
        var updatedState = syncState
        if syncState.workspaceEndpoint != nil {
            updatedState.lastAcknowledgedMutationID = profile.mutationID
            updatedState.allowNextRemoteAdoption = true
        }
        updatedState.workspaceEndpoint = normalizedEndpoint
        do {
            try fileStore.saveSyncState(updatedState)
            syncState = updatedState
            lastError = nil
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func saveVoiceProfile(
        _ voice: LocalVoiceProfile,
        allowedDimensions: ClosedRange<Int> = 1...MeetingProfileValidation.maximumEmbeddingDimensions
    ) throws {
        try voice.validate(allowedDimensions: allowedDimensions)
        try fileStore.saveLocalVoiceProfile(voice)
        localVoice = voice
        lastError = nil
    }

    func deleteVoiceProfile() throws {
        try fileStore.deleteLocalVoiceProfile()
        localVoice = nil
        lastError = nil
    }

    private static func message(for error: any Error) -> String {
        "프로필을 불러오지 못했어요. 설정을 확인한 뒤 다시 시도해 주세요."
    }

    private var shouldUploadProfile: Bool {
        guard !syncState.allowNextRemoteAdoption, profile.modifiedAt > 0 else { return false }
        return syncState.lastAcknowledgedMutationID != profile.mutationID
    }
}

private nonisolated enum MeetingProfileValidation {
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991
    static let maximumEmbeddingDimensions = 4_096
    static let maximumSharedProfileBytes = 60 * 1_024

    static func validateText(_ value: String, maxUTF8Bytes: Int, allowEmpty: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty else { throw MeetingProfileValidationError.invalidText }
        guard value.utf8.count <= maxUTF8Bytes else { throw MeetingProfileValidationError.tooLarge }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) else {
            throw MeetingProfileValidationError.invalidText
        }
    }

    static func truncatedUTF8(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = value
        while result.utf8.count > maxBytes {
            result.removeLast()
        }
        return result
    }

    static func millisecondsSince1970(date: Date = Date()) -> Int64 {
        min(Int64(date.timeIntervalSince1970 * 1_000), maxSafeInteger)
    }

    static func validateSharedProfileEncoding(_ profile: MeetingUserProfile) throws {
        guard (try? MeetingProfileFileStore.encodedSize(profile)) ?? (maximumSharedProfileBytes + 1) <= maximumSharedProfileBytes else {
            throw MeetingProfileValidationError.tooLarge
        }
    }
}

private nonisolated struct MeetingProfileSyncState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var workspaceEndpoint: String?
    var lastAcknowledgedMutationID: UUID?
    var allowNextRemoteAdoption = false

    func validate() throws {
        guard schemaVersion == 1 else { throw MeetingProfileValidationError.unsupportedSchemaVersion }
        guard workspaceEndpoint.map({ $0.utf8.count <= 2_048 }) ?? true else {
            throw MeetingProfileValidationError.tooLarge
        }
    }
}

private nonisolated struct MeetingProfileFileStore {
    private static let maximumSharedProfileBytes: UInt64 = UInt64(MeetingProfileValidation.maximumSharedProfileBytes)
    private static let maximumLocalVoiceBytes: UInt64 = 262_144
    private static let maximumSyncStateBytes: UInt64 = 8_192

    let root: URL

    private var sharedProfileURL: URL { root.appending(path: "meeting-profile.json") }
    private var localVoiceProfileURL: URL { root.appending(path: "local-voice-profile.json") }
    private var syncStateURL: URL { root.appending(path: "meeting-profile-state.json") }

    func loadSharedProfile() throws -> MeetingUserProfile? {
        try load(MeetingUserProfile.self, from: sharedProfileURL, maximumBytes: Self.maximumSharedProfileBytes)
    }

    func saveSharedProfile(_ profile: MeetingUserProfile) throws {
        try save(profile, to: sharedProfileURL)
    }

    func loadSyncState() throws -> MeetingProfileSyncState? {
        try load(MeetingProfileSyncState.self, from: syncStateURL, maximumBytes: Self.maximumSyncStateBytes)
    }

    func saveSyncState(_ state: MeetingProfileSyncState) throws {
        try save(state, to: syncStateURL)
    }

    func loadLocalVoiceProfile() throws -> LocalVoiceProfile? {
        try load(LocalVoiceProfile.self, from: localVoiceProfileURL, maximumBytes: Self.maximumLocalVoiceBytes)
    }

    func saveLocalVoiceProfile(_ voice: LocalVoiceProfile) throws {
        try save(voice, to: localVoiceProfileURL)
    }

    func deleteLocalVoiceProfile() throws {
        guard FileManager.default.fileExists(atPath: localVoiceProfileURL.path) else { return }
        try FileManager.default.removeItem(at: localVoiceProfileURL)
    }

    private func load<Value: Decodable>(_ type: Value.Type, from url: URL, maximumBytes: UInt64) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = Int(maximumBytes) + 1
        let data = try handle.read(upToCount: limit) ?? Data()
        guard data.count <= maximumBytes else { throw MeetingProfileValidationError.tooLarge }
        return try Self.decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        if Value.self == MeetingUserProfile.self {
            guard data.count <= MeetingProfileValidation.maximumSharedProfileBytes else {
                throw MeetingProfileValidationError.tooLarge
            }
        }
        try data.write(to: url, options: .atomic)
    }

    static func encodedSize<Value: Encodable>(_ value: Value) throws -> Int {
        try encoder.encode(value).count
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

nonisolated private extension String {
    var normalizedProfileKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
