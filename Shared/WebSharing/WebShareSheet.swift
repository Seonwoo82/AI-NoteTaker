import SwiftUI
import Observation

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
    @State private var state = WebShareSheetState()

    var body: some View {
        NavigationStack {
            WebShareSheetContent(isLoading: state.isLoading, progressTitle: state.progressTitle, shareURL: state.shareURL,
                expiresAt: state.expiresAt, isActive: state.isActive, statusIsKnown: state.statusIsKnown, copied: state.copied,
                message: state.message, errorMessage: state.errorMessage,
                publish: {
                    Task { await state.publish(sourceID: recording.id, title: recording.title, markdown: document.markdown, client: client) }
                }, revoke: {
                    Task { await state.revoke(sourceID: recording.id, client: client) }
                }, copy: state.copy, openSyncSettings: openSyncSettings)
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
        .task(id: [recording.id.uuidString, syncSettings.endpoint, String(syncSettings.token.hashValue)]) {
            await state.refresh(sourceID: recording.id, client: client)
        }
    }

    private func client() throws -> WebShareClient {
        WebShareClient(configuration: try syncSettings.connectionTestConfiguration())
    }
}

/// Only transient presentation state lives here. Every newly opened sheet reads
/// its URL from the authenticated server, including after an app restart.
@MainActor
@Observable
final class WebShareSheetState {
    private(set) var isLoading = false
    private(set) var progressTitle = String(localized: "Checking web sharing...")
    private(set) var shareURL: URL?
    private(set) var expiresAt: Date?
    private(set) var isActive = false
    private(set) var statusIsKnown = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    private(set) var copied = false
    private var operationID = UUID()

    func publish(sourceID: UUID, title: String, markdown: String, client: @escaping @MainActor () throws -> WebShareClient) async {
        guard statusIsKnown, !isActive, !isLoading else { return }
        await runSharingOperation(String(localized: "Creating web link...")) { id in
            let publication = try await client().publish(sourceID: sourceID, title: title, markdown: markdown)
            guard self.canApply(id) else { return }
            self.shareURL = publication.url
            self.expiresAt = publication.expiresAt
            self.isActive = true
            self.copied = false
            self.message = String(localized: "Web link created.")
        }
    }

    func revoke(sourceID: UUID, client: @escaping @MainActor () throws -> WebShareClient) async {
        guard isActive, !isLoading else { return }
        await runSharingOperation(String(localized: "Revoking web link...")) { id in
            try await client().revoke(sourceID: sourceID)
            guard self.canApply(id) else { return }
            self.shareURL = nil
            self.expiresAt = nil
            self.isActive = false
            self.statusIsKnown = true
            self.copied = false
            self.message = String(localized: "Web link revoked.")
        }
    }

    func refresh(sourceID: UUID, client: @escaping @MainActor () throws -> WebShareClient) async {
        await runSharingOperation(String(localized: "Checking web sharing..."), replacingCurrent: true) { id in
            self.shareURL = nil
            self.expiresAt = nil
            self.isActive = false
            self.statusIsKnown = false
            self.copied = false
            let status = try await client().status(sourceID: sourceID)
            guard self.canApply(id) else { return }
            self.shareURL = status.url
            self.expiresAt = status.expiresAt
            self.isActive = status.active
            self.statusIsKnown = true
        }
    }

    func copy(_ url: URL) {
        copied = WebShareClipboard.copy(url)
    }

    private func canApply(_ id: UUID) -> Bool {
        operationID == id && !Task.isCancelled
    }

    private func runSharingOperation(_ title: String, replacingCurrent: Bool = false,
        _ operation: @escaping @MainActor (UUID) async throws -> Void) async {
        guard !isLoading || replacingCurrent else { return }
        let id = UUID()
        operationID = id
        progressTitle = title
        isLoading = true
        errorMessage = nil
        message = nil
        defer { if operationID == id { isLoading = false } }
        do {
            try await operation(id)
        } catch {
            guard canApply(id) else { return }
            if error as? WebShareError == .activeLinkURLUnavailable {
                // Older servers confirm an active link but cannot return its URL.
                // Keep cancellation available without creating a replacement.
                isActive = true
                statusIsKnown = true
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
                } else if statusIsKnown {
                    Label(String(localized: "No active web link."), systemImage: "link.badge.plus")
                } else {
                    Label(String(localized: "Sharing status could not be checked."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }

                if let shareURL {
                    copyableLink(shareURL)
                } else if isActive {
                    Text(String(localized: "The active link address could not be restored. Update the sharing server, then reopen this window."))
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
