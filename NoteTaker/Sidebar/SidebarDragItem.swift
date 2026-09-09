import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Only identifiers travel in a drag. Audio and private note text stay in the library.
nonisolated enum SidebarDragItem: Codable, Hashable, Sendable, Transferable {
    case recording(UUID)
    case folder(UUID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .aiNoteTakerLibraryItem)
            .visibility(.ownProcess)
    }
}

nonisolated extension UTType {
    static let aiNoteTakerLibraryItem = UTType(exportedAs: "com.seonwoo.notetaker.library-item")
}

nonisolated enum SidebarDropTarget: Equatable {
    case folder(UUID)
    case unfiled
}

extension LibraryController {
    func canDrop(_ item: SidebarDragItem, on target: SidebarDropTarget) -> Bool {
        guard canOrganizeLibrary else { return false }
        if case let .folder(id) = target, !library.folderStore.isActive(id: id) { return false }
        switch item {
        case let .recording(id):
            guard let recording = library.recording(id: id), recording.deletedAt == nil else { return false }
            switch target {
            case let .folder(folderID): return recording.folderID != folderID
            case .unfiled: return recording.folderID != nil
            }
        case let .folder(id):
            guard library.folderStore.isActive(id: id), case let .folder(targetID) = target else { return false }
            return id != targetID
        }
    }

    @discardableResult
    func receiveSidebarDrop(_ item: SidebarDragItem, on target: SidebarDropTarget, below: Bool = false) -> Bool {
        guard canDrop(item, on: target) else { return false }
        switch item {
        case let .recording(id):
            let folderID: UUID?
            switch target {
            case let .folder(id): folderID = id
            case .unfiled: folderID = nil
            }
            return moveDroppedRecording(id, toFolder: folderID)
        case let .folder(id):
            guard case let .folder(targetID) = target else { return false }
            let others = activeCustomFolders.filter { $0.id != id }
            guard let targetIndex = others.firstIndex(where: { $0.id == targetID }) else { return false }
            let insertionIndex = targetIndex + (below ? 1 : 0)
            let before = insertionIndex < others.count ? others[insertionIndex].id : nil
            return moveDroppedFolder(id, before: before)
        }
    }
}
