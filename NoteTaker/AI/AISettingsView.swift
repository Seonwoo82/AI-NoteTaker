import SwiftUI

struct AISettingsView: View {
    @Bindable var configuration: AIConfiguration
    var profile: MeetingProfileStore?
    @State private var apiKey = ""
    @State private var modelSearch = ""
    @State private var transcriptionSearch = ""
    @State private var isSaving = false
    @State private var localMessage: String?
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                noticeCard
                keyCard
                modelCard
                generationCard
                statusCard
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await configuration.refreshModels()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "AI Meeting Notes"), systemImage: "sparkles")
                .font(.title2.weight(.semibold))
            Text(String(localized: "Configure OpenRouter transcription and minutes generation."))
                .foregroundStyle(.secondary)
        }
    }

    private var noticeCard: some View {
        SettingsCard {
            Label(String(localized: "Before you save an API key"), systemImage: "exclamationmark.shield")
                .font(.headline)
            Text(String(localized: "When AI minutes are generated, your recording audio and transcript are sent to OpenRouter and the selected model providers. Provider usage may be billed to your OpenRouter account."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(configuration.hasSyncedPreferences
                 ? String(localized: "Saving a key keeps the automatic-generation preference synced from your other device.")
                 : String(localized: "Save Key & Enable AI turns on automatic minutes for new recordings. You can turn it off below."))
                .font(.caption.weight(.medium))
        }
    }

    private var keyCard: some View {
        SettingsCard {
            HStack {
                Label(String(localized: "OpenRouter API Key"), systemImage: "key.fill")
                    .font(.headline)
                Spacer()
                StatusBadge(
                    text: configuration.hasAPIKey ? String(localized: "Saved") : String(localized: "Not Set"),
                    systemImage: configuration.hasAPIKey ? "checkmark.circle.fill" : "circle"
                )
            }

            if configuration.needsKeyForSyncedSettings {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "An API key is registered on another linked device."), systemImage: "icloud.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "AI preferences are synced. Enter an OpenRouter API key on this device to generate meeting notes here."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Enter API Key on This Device")) { keyFieldFocused = true }
                        .accessibilityIdentifier("ai-enter-key-on-this-device")
                }
                .accessibilityIdentifier("ai-other-device-key-notice")
            }

            SecureField(String(localized: "Paste a new key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai-settings-key")
                .focused($keyFieldFocused)

            HStack {
                Button {
                    saveKey()
                } label: {
                    Label(configuration.shouldEnableAutomaticGenerationOnFirstKeySave ? String(localized: "Save Key & Enable AI") : String(localized: "Save Key"), systemImage: "square.and.arrow.down")
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .accessibilityIdentifier("ai-save-key")

                Button {
                    Task { await configuration.testConnection() }
                } label: {
                    Label(String(localized: "Test"), systemImage: "bolt.horizontal.circle")
                }
                .disabled(!configuration.hasAPIKey || configuration.isLoadingModels)

                Button(role: .destructive) {
                    removeKey()
                } label: {
                    Label(String(localized: "Remove"), systemImage: "trash")
                }
                .disabled(!configuration.hasAPIKey)
            }
            .buttonStyle(.bordered)

            Text(String(localized: "Saved keys are kept in Keychain and are never shown here."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        SettingsCard {
            HStack {
                Label(String(localized: "Models"), systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await configuration.refreshModels() }
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(configuration.isLoadingModels)
            }

            ModelChooser(
                title: String(localized: "Minutes Model"),
                searchText: $modelSearch,
                selection: $configuration.modelID,
                models: summaryModels,
                fallbackID: configuration.modelID
            )

            ModelChooser(
                title: String(localized: "Speech-to-Text Model"),
                searchText: $transcriptionSearch,
                selection: $configuration.transcriptionModelID,
                models: transcriptionModels,
                fallbackID: configuration.transcriptionModelID
            )

            if configuration.isLoadingModels {
                ProgressView(String(localized: "Refreshing models..."))
                    .controlSize(.small)
            }
        }
    }

    private var generationCard: some View {
        SettingsCard {
            Toggle(isOn: $configuration.autoGenerate) {
                Label(String(localized: "Automatically generate minutes after recording"), systemImage: "wand.and.stars")
            }

            if configuration.autoGenerate && !configuration.hasAPIKey {
                Text(String(localized: "Save an API key on this device to automatically generate minutes for new recordings."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let profile {
                Toggle(isOn: Binding(
                    get: { profile.profile.automaticallyAnalyze },
                    set: { setAutomaticMeetingAnalysis($0) }
                )) {
                    Label(String(localized: "Automatically analyze speaker conversations"), systemImage: "person.2.wave.2")
                }
                Text(String(localized: "When automatic generation is enabled, AI-NoteTaker also creates speaker-separated transcripts, commitments, decisions, and briefing sources. This setting syncs; API keys stay device-local."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai-automatic-meeting-analysis-help")
            }

            Picker(String(localized: "Output Language"), selection: $configuration.outputLanguage) {
                Text(String(localized: "Match source")).tag("source")
                Text(String(localized: "Korean")).tag("ko")
                Text(String(localized: "English")).tag("en")
            }
            .pickerStyle(.segmented)
        }
    }

    private var statusCard: some View {
        SettingsCard {
            if let message = localMessage ?? configuration.connectionMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let error = configuration.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if (localMessage ?? configuration.connectionMessage) == nil && configuration.lastError == nil {
                Label(String(localized: "AI settings are ready when a key and models are selected."), systemImage: "checklist")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryModels: [OpenRouterModel] {
        filteredModels(configuration.models.filter(\.supportsSummary), query: modelSearch)
    }

    private var transcriptionModels: [OpenRouterModel] {
        filteredModels(configuration.models.filter(\.supportsTranscription), query: transcriptionSearch)
    }

    private func filteredModels(_ models: [OpenRouterModel], query: String) -> [OpenRouterModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func setAutomaticMeetingAnalysis(_ enabled: Bool) {
        guard let profile else { return }
        do {
            try profile.updateProfile { $0.automaticallyAnalyze = enabled }
            localMessage = enabled
                ? String(localized: "Speaker conversation analysis will run automatically.")
                : String(localized: "Speaker conversation analysis will run only when started manually.")
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try configuration.saveKeyFromSettings(trimmed)
            apiKey = ""
            localMessage = String(localized: "API key saved.")
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try configuration.removeKey()
            apiKey = ""
            localMessage = String(localized: "API key removed.")
        } catch {
            localMessage = error.localizedDescription
        }
    }
}

private struct ModelChooser: View {
    let title: String
    @Binding var searchText: String
    @Binding var selection: String
    let models: [OpenRouterModel]
    let fallbackID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            TextField(String(localized: "Search models"), text: $searchText)
                .textFieldStyle(.roundedBorder)
            Picker(title, selection: $selection) {
                if fallbackID.isEmpty { Text(String(localized: "Select a model")).tag("") }
                if !fallbackID.isEmpty && !models.contains(where: { $0.id == fallbackID }) {
                    Text(fallbackID).tag(fallbackID)
                }
                ForEach(models) { model in
                    Text(modelLabel(model)).tag(model.id)
                }
            }
            .labelsHidden()
        }
    }

    private func modelLabel(_ model: OpenRouterModel) -> String {
        var pieces = [model.name.isEmpty ? model.id : model.name]
        if model.contextLength > 0 {
            pieces.append("\(model.contextLength / 1000)k")
        }
        if model.supportsSummary, let promptPrice = model.promptPrice,
           let rate = Double(promptPrice), rate.isFinite, rate >= 0 {
            let perMillion = (rate * 1_000_000).formatted(.number.precision(.fractionLength(0...3)))
            pieces.append("$\(perMillion)/1M input")
        }
        return pieces.joined(separator: " · ")
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct StatusBadge: View {
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
