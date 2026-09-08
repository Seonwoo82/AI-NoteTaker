import AppKit
import SwiftUI

/// A native field keeps first-responder ownership stable when a sidebar button
/// is replaced by an inline editor. Both locations share the same rename session.
struct RecordingTitleEditor: NSViewRepresentable {
    let controller: LibraryController
    let session: RecordingRenameSession

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, session: session) }

    func makeNSView(context: Context) -> TitleField {
        let field = TitleField()
        field.stringValue = controller.renameDraft
        field.placeholderString = String(localized: "Title")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: session.location == .sidebar ? 12 : 17, weight: .medium)
        field.alignment = session.location == .sidebar ? .left : .center
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier(session.location == .sidebar ? "sidebar-recording-title-field" : "recording-title-field")
        field.setAccessibilityLabel(String(localized: "Title"))
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.onAttach = { [weak coordinator = context.coordinator] in
            // Finish the enclosing row replacement before requesting first responder.
            DispatchQueue.main.async { coordinator?.focus() }
        }
        context.coordinator.installClickMonitor()
        return field
    }

    func updateNSView(_ field: TitleField, context: Context) {
        // Do not replace the field editor's contents/marked text while typing.
        if field.currentEditor() == nil, controller.renameSession?.id == session.id {
            field.stringValue = controller.renameDraft
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: session.location == .sidebar ? 20 : 28)
    }

    static func dismantleNSView(_ field: TitleField, coordinator: Coordinator) {
        field.onAttach = nil
        field.delegate = nil
        coordinator.deactivate()
    }

    final class TitleField: NSTextField {
        var onAttach: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: LibraryController
        let session: RecordingRenameSession
        weak var field: TitleField?
        private var monitor: Any?
        private var isFinishing = false
        private var isActive = true

        init(controller: LibraryController, session: RecordingRenameSession) {
            self.controller = controller
            self.session = session
        }

        func focus() {
            guard isActive, controller.renameSession?.id == session.id,
                  let field, field.window != nil else { return }
            field.selectText(nil)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard isActive, controller.renameSession?.id == session.id else { return }
            controller.model.isEditingText = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard isActive, controller.renameSession?.id == session.id, let field else { return }
            controller.renameDraft = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { finish() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Enter/Escape first belong to the input method while composing text.
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(cancel: true)
                return true
            }
            return false
        }

        func finish(cancel: Bool = false) {
            guard isActive, !isFinishing, controller.renameSession?.id == session.id else { return }
            isFinishing = true
            defer { isFinishing = false }
            do {
                if cancel {
                    controller.cancelRename(sessionID: session.id)
                } else {
                    // Let AppKit finalize the input method/field editor before
                    // taking the value that will be written to recording metadata.
                    if let field, let window = field.window, field.currentEditor() != nil {
                        guard window.makeFirstResponder(nil) else { return }
                    }
                    if let field { controller.renameDraft = field.stringValue }
                    try controller.commitRename(sessionID: session.id)
                }
                // Clear the shared field editor; still let the original mouse
                // event activate the control the user actually clicked.
                if let field, field.currentEditor() != nil {
                    field.window?.makeFirstResponder(nil)
                }
            } catch {
                // Keep invalid/unsaved input and its error visible for correction.
                focus()
            }
        }

        func installClickMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let field = self.field,
                       let window = field.window, event.window === window,
                       !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                        self.finish()
                    }
                }
                return event
            }
        }

        func deactivate() {
            // SwiftUI can replace a native view within the same rename session.
            // Teardown is not a user commit; invalidate queued focus callbacks too.
            isActive = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
