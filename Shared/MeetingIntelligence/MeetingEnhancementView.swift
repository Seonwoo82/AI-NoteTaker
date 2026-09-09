import SwiftUI

struct MeetingEnhancementView: View {
    let recording: Recording
    let service: MeetingNotesService
    let configuration: AIConfiguration
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @State private var instructions = ""
    @State private var applyError: String?
    @State private var requestedPreview = false
    @FocusState private var editingInstructions: Bool

    init(recording: Recording, service: MeetingNotesService, configuration: AIConfiguration,
         onOpenSettings: @escaping () -> Void, onClose: @escaping () -> Void, initialInstructions: String = "") {
        self.recording = recording
        self.service = service
        self.configuration = configuration
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        _instructions = State(initialValue: initialInstructions)
    }

    private var progress: MeetingNotesProgress { service.progress(for: recording.id) }
    private var preview: MeetingNotesEnhancementPreview? { service.enhancementPreview(for: recording.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(String(localized: "Enhance Minutes"), systemImage: "wand.and.stars")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Close"))
                }

                Text(String(localized: "Describe incorrect names or missing context. Review the revised minutes before replacing the current report."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Corrections and missing context")).font(.headline)
                    Text(String(localized: "Example: July launch is a target, not a confirmed schedule. Reflect that the final timeline will be decided after the budget review."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $instructions)
                        .focused($editingInstructions)
                        .frame(minHeight: 110, maxHeight: 180)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                        .disabled(progress.isRunning)
                        .accessibilityLabel(String(localized: "Corrections and missing context"))
                        .accessibilityIdentifier("ai-enhancement-instructions")
                    if instructions.utf8.count > 8_000 {
                        Text(String(localized: "Your correction is too long. Split it into smaller requests."))
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                HStack {
                    Text(String(localized: "Enhancement Model"))
                    Text(configuration.effectiveEnhancementModelID)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                .font(.caption)
                .accessibilityIdentifier("ai-enhancement-model")

                if !configuration.isEnhancementConfigured {
                    Button(String(localized: "Open AI Settings"), action: onOpenSettings)
                        .buttonStyle(.bordered)
                }

                if progress.isRunning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "Preparing a revised report…"))
                        Spacer()
                        Button(String(localized: "Cancel")) { service.cancel(recording.id) }
                    }
                } else {
                    Button {
                        editingInstructions = false
                        applyError = nil
                        requestedPreview = true
                        service.enhance(recording, instructions: instructions)
                    } label: {
                        Label(String(localized: "Generate Enhancement"), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!configuration.isEnhancementConfigured || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || instructions.utf8.count > 8_000)
                    .accessibilityIdentifier("ai-enhancement-generate")
                }

                if requestedPreview, case .failed(let message) = progress {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let applyError {
                    Label(applyError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                if let preview {
                    Divider()
                    Text(String(localized: "Enhancement Preview")).font(.title3.weight(.semibold))
                    Text(String(localized: "The current report is unchanged until you apply this preview."))
                        .font(.callout).foregroundStyle(.secondary)
                    MarkdownDocumentView(document: MarkdownDocument(preview.markdown))
                        .accessibilityIdentifier("ai-enhancement-preview")
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if preview != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { previewActions }
                    VStack(alignment: .leading, spacing: 8) { previewActions }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.regularMaterial)
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { editingInstructions = false }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onChange(of: instructions) { _, _ in
            if !progress.isRunning { service.discardEnhancement(recording.id) }
            applyError = nil
        }
        .onDisappear {
            if requestedPreview { service.cancel(recording.id) }
            service.discardEnhancement(recording.id)
        }
        #if os(macOS)
        .frame(width: 760, height: 700)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var previewActions: some View {
        Button {
            do {
                try service.applyEnhancement(recording)
                onClose()
            } catch {
                applyError = (error as? AIError)?.message ?? error.localizedDescription
            }
        } label: {
            Label(String(localized: "Apply Enhancement"), systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("ai-enhancement-apply")
        Button(String(localized: "Discard Preview")) { service.discardEnhancement(recording.id) }
            .buttonStyle(.bordered)
    }

    private func close() {
        if requestedPreview { service.cancel(recording.id) }
        service.discardEnhancement(recording.id)
        onClose()
    }
}
