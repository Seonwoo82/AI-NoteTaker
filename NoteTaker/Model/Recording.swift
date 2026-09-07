import AudioPipeline
import Foundation

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
        warnings: [String] = []
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
    }
}
