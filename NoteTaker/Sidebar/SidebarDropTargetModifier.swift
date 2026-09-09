import SwiftUI

struct SidebarDropTargetModifier: ViewModifier {
    let controller: LibraryController
    let target: SidebarDropTarget
    var allowsFolderReorder = true
    @State private var highlight: Highlight?
    @State private var height: CGFloat = 28

    private enum Highlight { case inside, before, after }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay {
                if highlight == .inside {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 2))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if highlight == .before { insertionLine }
            }
            .overlay(alignment: .bottom) {
                if highlight == .after { insertionLine }
            }
            .dropDestination(for: SidebarDragItem.self, isEnabled: controller.canOrganizeLibrary) { items, session in
                highlight = nil
                guard items.count == 1, let item = items.first, accepts(item) else { return }
                controller.receiveSidebarDrop(item, on: target, below: session.location.y > height / 2)
            }
            .dropConfiguration { session in
                let items = session.localSession?.draggedItemIDs(for: SidebarDragItem.self) ?? []
                let valid = items.count == 1 && items.first.map(accepts) == true
                return DropConfiguration(operation: valid ? .move : .forbidden)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active:
                    let items = session.localSession?.draggedItemIDs(for: SidebarDragItem.self) ?? []
                    guard items.count == 1, let item = items.first, accepts(item) else {
                        highlight = nil
                        return
                    }
                    switch item {
                    case .recording: highlight = .inside
                    case .folder: highlight = session.location.y > height / 2 ? .after : .before
                    }
                case .exiting, .ended, .dataTransferCompleted:
                    highlight = nil
                @unknown default:
                    highlight = nil
                }
            }
    }

    private var insertionLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
    }

    private func accepts(_ item: SidebarDragItem) -> Bool {
        if case .folder = item, !allowsFolderReorder { return false }
        return controller.canDrop(item, on: target)
    }
}
