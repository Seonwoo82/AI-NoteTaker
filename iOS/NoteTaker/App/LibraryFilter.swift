import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, favorites, deleted
    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All Recordings")
        case .favorites: String(localized: "Favorites")
        case .deleted: String(localized: "Recently Deleted")
        }
    }

    var symbol: String {
        switch self {
        case .all: "waveform"
        case .favorites: "star"
        case .deleted: "trash"
        }
    }

    func recordings(in library: LibraryStore, search: String) -> [Recording] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.recordings.filter { recording in
            let included = switch self {
            case .all: recording.deletedAt == nil
            case .favorites: recording.deletedAt == nil && recording.isFavorite
            case .deleted: recording.deletedAt != nil
            }
            return included && (query.isEmpty || recording.title.localizedCaseInsensitiveContains(query))
        }
    }
}
