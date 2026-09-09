import SwiftUI

struct MeetingNotesView: View {
    let recording: Recording
    let service: MeetingNotesService
    @Bindable var configuration: AIConfiguration
    let openAISettings: (() -> Void)?
#if os(macOS)
    @Environment(\.openSettings) private var openSystemSettings
#endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var resolvedTranscript: MeetingTranscript? = nil
    var participantPreparationProgress: ParticipantPreparationProgress? = nil
    @State private var showingEnhancement = false
    @State private var showEnhancementSettingsAfterDismiss = false
    @State private var selectedTab = NotesTab.minutes
    @State private var showingRegenerateConfirmation = false
    @State private var copied = false
    @State private var selectedOutlineBlock: Int?

    init(
        recording: Recording,
        service: MeetingNotesService,
        configuration: AIConfiguration,
        openAISettings: (() -> Void)? = nil,
        resolvedTranscript: MeetingTranscript? = nil,
        participantPreparationProgress: ParticipantPreparationProgress? = nil
    ) {
        self.recording = recording
        self.service = service
        self.configuration = configuration
        self.openAISettings = openAISettings
        self.resolvedTranscript = resolvedTranscript
        self.participantPreparationProgress = participantPreparationProgress
    }

    private var document: MeetingNotesDocument? {
        service.document(for: recording.id)
    }

    private var progress: MeetingNotesProgress {
        service.progress(for: recording.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    progressView

                    if let document {
                        documentTabs(document) { heading in
                            selectedOutlineBlock = heading.blockIndex
                            let anchor = MarkdownDocument.Anchor.block(heading.blockIndex)
                            if reduceMotion {
                                proxy.scrollTo(anchor, anchor: .top)
                            } else {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            }
                        }
                    } else if !progress.isRunning {
                        emptyState
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.appWindowBackground)
        .task(id: recording.id) {
            await service.load(recording)
        }
        .onChange(of: recording.id) { oldID, _ in
            if showingEnhancement { service.cancel(oldID) }
            showingEnhancement = false
            copied = false
            selectedTab = .minutes
        }
        .onChange(of: document?.markdown) {
            copied = false
            selectedOutlineBlock = nil
        }
        .sheet(isPresented: $showingEnhancement, onDismiss: {
            if showEnhancementSettingsAfterDismiss {
                showEnhancementSettingsAfterDismiss = false
                openAISettings?()
            }
        }) {
            MeetingEnhancementView(recording: recording, service: service, configuration: configuration,
                onOpenSettings: {
                    showEnhancementSettingsAfterDismiss = true
                    showingEnhancement = false
                },
                onClose: { showingEnhancement = false })
        }
        .confirmationDialog(
            String(localized: "Regenerate Minutes?"),
            isPresented: $showingRegenerateConfirmation
        ) {
            Button(String(localized: "Regenerate"), role: .destructive) {
                service.generate(recording, regenerate: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The previous minutes stay visible while new minutes are generated."))
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                headerTitle
                Spacer()
                if recording.deletedAt == nil {
                    controls
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                if recording.deletedAt == nil {
                    controls
                }
            }
        }
    }

    private var headerTitle: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(recording.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    MeetingNotesBadge(text: String(localized: "AI"), systemImage: "sparkles")
                }

                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch progress {
        case .idle, .completed, .cancelled:
            EmptyView()
        case .queued:
            runningCard(
                title: participantPreparationTitle ?? String(localized: "Queued"),
                detail: participantPreparationProgress?.status,
                fraction: nil
            )
        case .transcribing(let completed, let total):
            runningCard(
                title: participantPreparationTitle ?? String(localized: "Transcribing audio"),
                detail: participantPreparationProgress?.status,
                fraction: participantPreparationProgress?.fraction ?? fraction(completed: completed, total: total)
            )
        case .summarizing(let completed, let total):
            runningCard(
                title: participantPreparationTitle ?? String(localized: "Writing minutes"),
                detail: participantPreparationProgress?.status,
                fraction: participantPreparationProgress?.fraction ?? fraction(completed: completed, total: total)
            )
        case .failed(let message):
            NotesCard {
                Label(String(localized: "Generation failed"), systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if progress.isRunning {
                Button {
                    service.cancel(recording.id)
                } label: {
                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                }
            } else if document != nil {
                Button {
                    service.discardEnhancement(recording.id)
                    showingEnhancement = true
                } label: {
                    Label(String(localized: "Enhance Minutes"), systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("ai-enhance-minutes")
                Button {
                    showingRegenerateConfirmation = true
                } label: {
                    Label(String(localized: "Regenerate"), systemImage: "arrow.clockwise")
                }
                .disabled(!configuration.isConfigured)
            }
        }
        .buttonStyle(.bordered)
    }

    private func documentTabs(_ document: MeetingNotesDocument, onSelectHeading: @escaping (MarkdownDocument.Heading) -> Void) -> some View {
        let markdown = MarkdownDocument(document.markdown)
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    tabPicker
                    Spacer()
                    copyButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    tabPicker
                    copyButton
                }
            }

            NotesCard {
                switch selectedTab {
                case .minutes:
                    ReportOverview(document: document, recording: recording)
                    if let enhancement = document.enhancement {
                        Text("\(String(localized: "Last enhanced with")): \(enhancement.modelID)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !markdown.outlineHeadings.isEmpty {
                        MeetingNotesOutline(headings: markdown.outlineHeadings,
                                            selectedBlockIndex: selectedOutlineBlock,
                                            onSelect: onSelectHeading)
                            .id(document.recordingID)
                    }
                    MarkdownDocumentView(document: markdown)
                case .transcript:
                    if let transcript = document.participantTranscript(resolvingWith: resolvedTranscript) {
                        Text(String(localized: "Participant labels are estimates. Overlapping or unclear speech may remain unidentified."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(String(localized: "Participant Transcript Model")): \(transcript.transcriptionModelID)")
                            .font(.caption).foregroundStyle(.secondary)
                        NumberedTranscriptView(transcript: transcript)
                    } else {
                        Text(String(localized: "Participant labels are not available yet. Identify participants to add speaker numbers to this transcript."))
                            .font(.callout).foregroundStyle(.secondary)
                        if recording.deletedAt == nil {
                            Button {
                                service.identifyParticipants(recording)
                            } label: {
                                Label(String(localized: "Identify Participants"), systemImage: "person.2.wave.2")
                            }
                            .buttonStyle(.bordered)
                            .disabled(progress.isRunning || !configuration.isConfigured)
                            .accessibilityIdentifier("ai-identify-participants")
                        }
                        Text(document.transcript.isEmpty ? String(localized: "No transcript was stored.") : document.transcript)
                            .font(.body).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !progress.isRunning, let notice = service.transcriptNotice(for: recording.id) {
                        Label(notice, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("participant-identification-status")
                    }
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker(String(localized: "Summary"), selection: $selectedTab) {
            Text(String(localized: "Minutes")).tag(NotesTab.minutes)
            Text(String(localized: "Transcript")).tag(NotesTab.transcript)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var copyButton: some View {
        Button {
            copied = service.copyMarkdown(for: recording.id)
        } label: {
            Label(
                copied ? String(localized: "Copied") : String(localized: "Copy Markdown"),
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("ai-copy-markdown")
    }

    private var emptyState: some View {
        NotesCard {
            if recording.deletedAt != nil {
                ContentUnavailableView(
                    String(localized: "No AI Minutes"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(String(localized: "Deleted recordings keep existing minutes read-only, but new minutes cannot be generated."))
                )
            } else if configuration.isConfigured {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Ready to generate minutes"), systemImage: "sparkles")
                        .font(.headline)
                    Text(String(localized: "Create clear minutes and a transcript from this recording."))
                        .foregroundStyle(.secondary)
                    Button {
                        service.generate(recording)
                    } label: {
                        Label(String(localized: "Generate"), systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai-generate")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "AI setup needed"), systemImage: "key")
                        .font(.headline)
                    Text(String(localized: "Save an OpenRouter API key before generating minutes."))
                        .foregroundStyle(.secondary)
                    Button {
                        configuration.settingsTab = "ai"
                        openSettingsPanel()
                    } label: {
                        Label(String(localized: "Open AI Settings"), systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var metadataText: String {
        let date = DateFormat.recordingList.string(from: document?.generatedAt ?? recording.createdAt)
        let duration = DurationFormat.list(recording.duration)
        let model = document?.modelID ?? configuration.modelID
        if model.isEmpty {
            return "\(date) · \(duration)"
        }
        return "\(date) · \(duration) · \(model)"
    }

    private var participantPreparationTitle: String? {
        guard progress.isRunning, participantPreparationProgress != nil else { return nil }
        return String(localized: "Identifying participants")
    }

    private func runningCard(title: String, detail: String? = nil, fraction: Double?) -> some View {
        NotesCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    runningProgress(title: title, detail: detail, fraction: fraction)
                    Spacer()
                    Button(String(localized: "Cancel")) {
                        service.cancel(recording.id)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    runningProgress(title: title, detail: detail, fraction: fraction)
                    Button(String(localized: "Cancel")) {
                        service.cancel(recording.id)
                    }
                }
            }
        }
    }

    private func runningProgress(title: String, detail: String?, fraction: Double?) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: fraction)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(localized: "The existing minutes remain available while this runs. Keep this app open until generation finishes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSettingsPanel() {
        configuration.settingsTab = "ai"
        if let openAISettings {
            openAISettings()
            return
        }
#if os(macOS)
        openSystemSettings()
#endif
    }

    private func fraction(completed: Int, total: Int) -> Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

private enum NotesTab: Hashable {
    case minutes
    case transcript
}

private struct NotesCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.appSeparator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct ReportOverview: View {
    let document: MeetingNotesDocument
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                overviewCards
                VStack(alignment: .leading, spacing: 10) {
                    generatedCard
                    durationCard
                    costCard
                }
            }

        }
        .padding(.bottom, 4)
    }

    private var overviewCards: some View {
        HStack(alignment: .top, spacing: 10) {
            generatedCard
            durationCard
            costCard
        }
    }

    private var generatedCard: some View {
        InsightCard(
            title: String(localized: "Generated"),
            value: DateFormat.recordingList.string(from: document.generatedAt),
            systemImage: "calendar"
        )
    }

    private var durationCard: some View {
        InsightCard(
            title: String(localized: "Duration"),
            value: DurationFormat.list(recording.duration),
            systemImage: "clock"
        )
    }

    @ViewBuilder
    private var costCard: some View {
        if let cost = document.costUSD {
            InsightCard(
                title: String(localized: "Cost"),
                value: cost.formatted(.currency(code: "USD").precision(.fractionLength(4))),
                systemImage: "creditcard"
            )
        }
    }
}

private struct InsightCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MeetingNotesBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}
