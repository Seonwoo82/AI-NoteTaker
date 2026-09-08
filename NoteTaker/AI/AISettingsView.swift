import SwiftUI

struct AISettingsView: View {
    @Bindable var configuration: AIConfiguration
    @State private var apiKey = ""
    @State private var modelSearch = ""
    @State private var transcriptionSearch = ""
    @State private var isSaving = false
    @State private var localMessage: String?

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
            Text(String(localized: "Save Key & Enable AI turns on automatic minutes for new recordings. You can turn it off below."))
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

            SecureField(String(localized: "Paste a new key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai-settings-key")

            HStack {
                Button {
                    saveKey()
                } label: {
                    Label(configuration.hasAPIKey ? String(localized: "Save Key") : String(localized: "Save Key & Enable AI"), systemImage: "square.and.arrow.down")
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

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let enablingAI = !configuration.hasAPIKey
            try configuration.saveKey(trimmed)
            if enablingAI { configuration.autoGenerate = true }
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
