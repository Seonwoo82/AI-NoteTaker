import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SyncSettingsView: View {
    let settings: SyncSettings
    let sync: SyncCoordinator
    let library: LibraryStore?
    @State private var endpoint = ""
    @State private var token = ""
    @State private var enabled = false
    @State private var saveError: String?
    @State private var saved = false
    @FocusState private var focusedInput: Input?
    @Environment(\.dismiss) private var dismiss

    private enum Input: Hashable { case endpoint, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Connect your devices", systemImage: "icloud").font(.headline)
                    Text("Use the same Cloudflare server and sync key on your Mac and iPhone. Your recordings stay available offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Server URL", text: $endpoint, prompt: Text("https://notes.your-name.workers.dev"))
                        .autocorrectionDisabled().accessibilityIdentifier("sync-endpoint")
                        .focused($focusedInput, equals: .endpoint)
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                    SecureField("Sync Key", text: $token)
                        .autocorrectionDisabled().accessibilityIdentifier("sync-token")
                        .focused($focusedInput, equals: .token)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Toggle("Enable Automatic Sync", isOn: $enabled).accessibilityIdentifier("sync-enabled")
                } header: {
                    Text("Cloudflare Connection")
                } footer: {
                    Text("Enter the dedicated sync key from your Worker setup. The key is stored securely in Keychain. Your Cloudflare account API token is not needed.")
                }
                Section {
                    Button("Save Connection") { save() }.accessibilityIdentifier("save-sync-settings")
                    Button("Copy Sync Key") { copyToken() }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("copy-sync-key")
                    Button("Test Connection") {
                        if save() { Task { await sync.testConnection() } }
                    }
                    .disabled(sync.isSyncing)
                    Button("Sync Now") {
                        if save(), let library { Task { await sync.sync(library: library) } }
                    }
                    .disabled(!enabled || library == nil || sync.isSyncing)
                    .accessibilityIdentifier("sync-now")
                }
                Section("Status") {
                    if saved { Label("Connection Settings Saved", systemImage: "checkmark.circle") }
                    if sync.isSyncing { ProgressView("Syncing…") }
                    Text(sync.status)
                    if let last = sync.lastSyncedAt {
                        LabeledContent("Last Synced") {
                            Text(last, format: .dateTime.month().day().hour().minute().second())
                        }
                    }
                    if let message = saveError ?? sync.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section("About Sync") {
                    Text("Sync checks for changes every 30 seconds while active and after local edits. Failed transfers retry automatically.")
                    Text("Automatic sync keeps running when you close the Mac window. Quit the app to stop it.")
                    Text("If both devices edit the same note, the edit with the later device timestamp wins. Keep device clocks set automatically.")
                    Text("Audio uploads are limited to 95 MiB per recording. Deleted notes can be restored from Recently Deleted; their cloud audio is retained.")
                    Text("Recordings, AI minutes, and completed transcripts sync between devices. Set your OpenRouter API key separately on each device.")
                    Text("AI models, output language, and automatic-generation preferences sync too. API keys stay on each device.")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped).navigationTitle("Settings")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedInput = nil }
                        .accessibilityIdentifier("hide-sync-keyboard")
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 700)
        #endif
        .onAppear {
            endpoint = settings.endpoint
            token = settings.token
            enabled = settings.isEnabled
        }
        .alert("Connection Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @discardableResult
    private func save() -> Bool {
        focusedInput = nil
        let previous = (settings.endpoint, settings.token, settings.isEnabled)
        settings.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.isEnabled = enabled
        do {
            try settings.save()
            if previous.0 != settings.endpoint || previous.1 != settings.token || previous.2 != settings.isEnabled {
                sync.settingsDidChange()
            }
            saveError = nil
            saved = true
            return true
        } catch {
            (settings.endpoint, settings.token, settings.isEnabled) = previous
            saveError = error.localizedDescription
            saved = false
            return false
        }
    }

    private func copyToken() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmedToken, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = trimmedToken
        #endif
        saved = false
        saveError = nil
        sync.status = String(localized: "Sync key copied")
    }
}
