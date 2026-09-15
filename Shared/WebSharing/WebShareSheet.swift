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
    @State private var isLoading = false
    @State private var progressTitle = String(localized: "Checking web sharing...")
    @State private var shareURL: URL?
    @State private var expiresAt: Date?
    @State private var isActive = false
    @State private var statusIsKnown = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            WebShareSheetContent(isLoading: isLoading, progressTitle: progressTitle, shareURL: shareURL,
                expiresAt: expiresAt, isActive: isActive, statusIsKnown: statusIsKnown, copied: copied,
                message: message, errorMessage: errorMessage,
                publish: publish, revoke: revoke, copy: copy, openSyncSettings: openSyncSettings)
            .navigationTitle(String(localized: "Share to Web"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 500)
        #endif
        .task(id: recording.id) {
            await refreshStatus()
        }
    }

    private func publish() {
        guard statusIsKnown, !isActive, !isLoading else { return }
        Task {
            guard statusIsKnown, !isActive else { return }
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
                message = String(localized: "Web link created.")
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
            statusIsKnown = false
            let status = try await client().status(sourceID: recording.id)
            statusIsKnown = true
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
        copied = WebShareClipboard.copy(url)
    }

    private func userMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}

/// Presentation is separate from server operations so every local sharing state
/// can be rendered without creating or replacing a public link.
struct WebShareSheetContent: View {
    let isLoading: Bool
    let progressTitle: String
    let shareURL: URL?
    let expiresAt: Date?
    let isActive: Bool
    let statusIsKnown: Bool
    let copied: Bool
    let message: String?
    let errorMessage: String?
    let publish: () -> Void
    let revoke: () -> Void
    let copy: (URL) -> Void
    let openSyncSettings: () -> Void

    var body: some View {
        Form {
            Section {
                Label(String(localized: "Share to Web"), systemImage: "link")
                    .font(.headline)
                Text(String(localized: "This shares a copy of the title and minutes only. Anyone with the link can read it until it expires in 7 days."))
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
                    copyableLink(shareURL)
                } else if isActive {
                    Text(String(localized: "The link address is shown only when it is created. You can still cancel sharing here."))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if isActive {
                    Button(role: .destructive, action: revoke) {
                        Text(String(localized: "Revoke Web Link"))
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("web-share-revoke")
                } else {
                    Button(action: publish) {
                        Label(String(localized: "Create Web Link"), systemImage: "link.badge.plus")
                    }
                    .disabled(isLoading || !statusIsKnown)
                    .accessibilityIdentifier("web-share-create")
                }
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
    }

    private func copyableLink(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Button {
                copy(url)
            } label: {
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(String(localized: "Copy Link"))
            .accessibilityValue(url.absoluteString)
            .accessibilityIdentifier("web-share-url-copy")

            Button {
                copy(url)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Copy Link"))
            .accessibilityValue(copied ? String(localized: "Copied") : "")
            .accessibilityIdentifier("web-share-copy")

            #if os(iOS)
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Share Link"))
            .accessibilityIdentifier("web-share-system-share")
            #endif
        }
        .accessibilityIdentifier("web-share-url-row")
    }
}

@MainActor
enum WebShareClipboard {
    static func copy(_ url: URL) -> Bool {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = url.absoluteString
        return UIPasteboard.general.string == url.absoluteString
        #else
        return false
        #endif
    }
}
