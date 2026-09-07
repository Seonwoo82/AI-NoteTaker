import Foundation

nonisolated enum RecordingFolder: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites
    case recentlyDeleted

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            String(localized: "All Recordings")
        case .favorites:
            String(localized: "Favorites")
        case .recentlyDeleted:
            String(localized: "Recently Deleted")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "tray.full"
        case .favorites:
            "star"
        case .recentlyDeleted:
            "trash"
        }
    }
}
