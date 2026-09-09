import AudioPipeline
import Foundation

nonisolated struct RecordingFolderAssignment: Codable, Hashable, Sendable {
    var id: UUID?

    init(id: UUID?) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }
}

nonisolated struct Recording: Identifiable, Codable, Hashable, Sendable {
    var schemaVersion: Int
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval
    var isFavorite: Bool
    var deletedAt: Date?
    var mode: CaptureMode
    var audioVersion: Int
    var hasTranscript: Bool
    var transcriptionError: String?
    var playbackRate: Double
    var skipsSilence: Bool
    var enhances: Bool
    var warnings: [String]
    var folderAssignment: RecordingFolderAssignment?
    var modifiedAt: Int64
    var mutationID: String

    var folderID: UUID? {
        get { folderAssignment?.id }
        set { folderAssignment = RecordingFolderAssignment(id: newValue) }
    }

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: TimeInterval,
        mode: CaptureMode,
        isFavorite: Bool = false,
        deletedAt: Date? = nil,
        audioVersion: Int = 1,
        hasTranscript: Bool = false,
        transcriptionError: String? = nil,
        playbackRate: Double = 1.0,
        skipsSilence: Bool = false,
        enhances: Bool = false,
        warnings: [String] = [],
        folderAssignment: RecordingFolderAssignment? = nil,
        modifiedAt: Int64? = nil,
        mutationID: String = UUID().uuidString.uppercased()
    ) {
        self.schemaVersion = 1
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.isFavorite = isFavorite
        self.deletedAt = deletedAt
        self.mode = mode
        self.audioVersion = audioVersion
        self.hasTranscript = hasTranscript
        self.transcriptionError = transcriptionError
        self.playbackRate = playbackRate
        self.skipsSilence = skipsSilence
        self.enhances = enhances
        self.warnings = warnings
        self.folderAssignment = folderAssignment
        self.modifiedAt = modifiedAt ?? Self.milliseconds(since1970: createdAt)
        self.mutationID = mutationID.uppercased()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        mode = try container.decode(CaptureMode.self, forKey: .mode)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        audioVersion = try container.decodeIfPresent(Int.self, forKey: .audioVersion) ?? 1
        hasTranscript = try container.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
        transcriptionError = try container.decodeIfPresent(String.self, forKey: .transcriptionError)
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1.0
        skipsSilence = try container.decodeIfPresent(Bool.self, forKey: .skipsSilence) ?? false
        enhances = try container.decodeIfPresent(Bool.self, forKey: .enhances) ?? false
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        folderAssignment = try container.decodeIfPresent(RecordingFolderAssignment.self, forKey: .folderAssignment)
        modifiedAt = try container.decodeIfPresent(Int64.self, forKey: .modifiedAt) ?? Self.milliseconds(since1970: createdAt)
        mutationID = try (container.decodeIfPresent(String.self, forKey: .mutationID) ?? id.uuidString).uppercased()
    }

    func wins(over other: Recording?) -> Bool {
        guard let other else { return true }
        if modifiedAt != other.modifiedAt {
            return modifiedAt > other.modifiedAt
        }
        return mutationID > other.mutationID
    }

    func locallyStamped(after previous: Recording?, now: Date = .now) -> Recording {
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
