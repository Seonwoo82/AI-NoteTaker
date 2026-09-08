import SwiftUI

struct LibraryCommands: Commands {
    let container: AppContainer?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Recording")) {
                guard let container else { return }
                Task { await container.libraryController.startNewRecordingFromKeyboard() }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(container?.session.phase != .idle || container?.model.isEditingText == true)

            Button(String(localized: "Done")) {
                guard let container else { return }
                Task { await container.session.finish() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!(container?.session.phase == .recording || container?.session.phase == .paused))

            Divider()

            Button(String(localized: "Export...")) {
                guard let container else { return }
                Task { await container.libraryController.exportSelectedAudio() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(container == nil || container?.libraryController.selectedRecording == nil || container?.model.isEditingText == true)

            Button(String(localized: "Show in Finder")) {
                container?.libraryController.revealSelectedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(container == nil || container?.libraryController.selectedRecording == nil || container?.model.isEditingText == true)

            Button(String(localized: "Sync Now")) {
                guard let container else { return }
                Task { await container.syncCoordinator.sync(library: container.library) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(container == nil || container?.syncCoordinator.isSyncing == true)
        }

        CommandMenu(String(localized: "Library")) {
            Button(String(localized: "Rename")) {
                guard let recording = container?.libraryController.selectedRecording else { return }
                container?.libraryController.beginRename(recording.id)
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(container == nil || container?.libraryController.selectedRecording?.deletedAt != nil || container?.model.isEditingText == true)

            Button(String(localized: "Delete")) {
                guard let recording = container?.libraryController.selectedRecording else { return }
                Task { try? await container?.libraryController.moveToRecentlyDeleted(recording.id) }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(container == nil || container?.libraryController.selectedRecording?.deletedAt != nil || container?.model.isEditingText == true)

            Button(String(localized: "Favorite")) {
                guard let recording = container?.libraryController.selectedRecording else { return }
                Task { try? await container?.libraryController.toggleFavorite(recording.id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(container == nil || container?.libraryController.selectedRecording?.deletedAt != nil || container?.model.isEditingText == true)

            Divider()

            Button(String(localized: "Find")) {
                container?.libraryController.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu(String(localized: "Playback")) {
            Button(String(localized: "Play/Pause")) {
                guard let container, !container.model.isEditingText else { return }
                Task { await container.playback.togglePlayPause() }
            }
            .disabled(container?.model.isEditingText == true)

            Button(String(localized: "Back 15 Seconds")) {
                guard let container, !container.model.isEditingText else { return }
                Task { await container.playback.skipBackward() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(container?.model.isEditingText == true)

            Button(String(localized: "Forward 15 Seconds")) {
                guard let container, !container.model.isEditingText else { return }
                Task { await container.playback.skipForward() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(container?.model.isEditingText == true)
        }
    }
}
