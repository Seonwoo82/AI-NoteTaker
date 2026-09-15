import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct WebShareSheet: View {
    let recording: Recording
    let document: MeetingNotesDocument
    let syncSettings: SyncSettings
    let openSyncSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isLoading = false
    @State private var progressTitle = String(localized: "Checking web sharing...")
    @State private var shareURL: URL?
    @State private var expiresAt: Date?
    @State private var isActive = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(String(localized: "Share to Web"), systemImage: "link")
                        .font(.headline)
                    Text(String(localized: "This shares a copy of the title and minutes only. Anyone with the link can read it until it expires in 7 days. Creating a new link invalidates the previous one."))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Revoking stops future access to the link, but it cannot retract copies someone already saved."))
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Share Status")) {
                    if isLoading {
                        ProgressView(progressTitle)
                    } else if isActive {
                        Label(String(localized: "A web link is active."), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        if let expiresAt {
                            LabeledContent(String(localized: "Expires")) {
                                Text(expiresAt, format: .dateTime.month().day().hour().minute())
                            }
                        }
                    } else {
                        Label(String(localized: "No active web link."), systemImage: "link.badge.plus")
                    }

                    if let shareURL {
                        Text(shareURL.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } else if isActive {
                        Text(String(localized: "This device can revoke or replace the active link. The link address is shown only when a link is created here."))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        publish()
                    } label: {
                        Label(
                            isActive ? String(localized: "Create New Link") : String(localized: "Create Web Link"),
                            systemImage: "link.badge.plus"
                        )
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("web-share-create")

                    if let shareURL {
                        platformShareControls(url: shareURL)
                    }

                    Button(role: .destructive) {
                        revoke()
                    } label: {
                        Label(String(localized: "Revoke Web Link"), systemImage: "trash")
                    }
                    .disabled(!isActive || isLoading)
                    .accessibilityIdentifier("web-share-revoke")
                } footer: {
                    Text(String(localized: "Sync does not need to be enabled, but the server URL and sync key must be saved in Sync settings."))
                }

                Section(String(localized: "Connection")) {
                    Button {
                        openSyncSettings()
                    } label: {
                        Label(String(localized: "Open Sync Settings"), systemImage: "gearshape")
                    }
                    if let message {
                        Label(message, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Share to Web"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 560)
        #endif
        .task(id: recording.id) {
            await refreshStatus()
        }
    }

    @ViewBuilder
    private func platformShareControls(url: URL) -> some View {
        #if os(iOS)
        ShareLink(item: url) {
            Label(String(localized: "Share Link"), systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("web-share-system-share")
        #endif

        Button {
            copy(url)
        } label: {
            Label(copied ? String(localized: "Copied") : String(localized: "Copy Link"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("web-share-copy")

        Button {
            openURL(url)
        } label: {
            Label(String(localized: "Open Link"), systemImage: "safari")
        }
        .accessibilityIdentifier("web-share-open")
    }

    private func publish() {
        Task {
            await runSharingOperation(String(localized: "Creating web link...")) {
                let publication = try await client().publish(
                    sourceID: recording.id,
                    title: recording.title,
                    markdown: document.markdown
                )
                shareURL = publication.url
                expiresAt = publication.expiresAt
                isActive = true
                copied = false
                message = String(localized: "Web link created. The previous link is no longer valid.")
            }
        }
    }

    private func revoke() {
        Task {
            await runSharingOperation(String(localized: "Revoking web link...")) {
                try await client().revoke(sourceID: recording.id)
                shareURL = nil
                expiresAt = nil
                isActive = false
                copied = false
                message = String(localized: "Web link revoked.")
            }
        }
    }

    private func refreshStatus() async {
        await runSharingOperation(String(localized: "Checking web sharing...")) {
            let status = try await client().status(sourceID: recording.id)
            isActive = status.active
            expiresAt = status.expiresAt
            if !status.active {
                shareURL = nil
            }
        }
    }

    private func runSharingOperation(_ title: String, _ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isLoading else { return }
        progressTitle = title
        isLoading = true
        errorMessage = nil
        message = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func client() throws -> WebShareClient {
        WebShareClient(configuration: try syncSettings.connectionTestConfiguration())
    }

    private func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = url.absoluteString
        copied = UIPasteboard.general.string == url.absoluteString
        #else
        copied = false
        #endif
    }

    private func userMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}
