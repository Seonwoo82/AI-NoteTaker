import Foundation

nonisolated enum SyncError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidResponse
    case server(statusCode: Int, message: String)
    case redirectRefused
    case audioTooLarge(limitBytes: Int)
    case missingAudio(UUID)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Sync is disabled."
        case .invalidResponse:
            "The sync server returned an invalid response."
        case let .server(statusCode, message):
            "Sync server error \(statusCode): \(message)"
        case .redirectRefused:
            "Sync refused a redirect so the token stays on the configured Cloudflare origin."
        case let .audioTooLarge(limitBytes):
            "Audio is larger than the 95 MiB sync limit (\(limitBytes) bytes)."
        case let .missingAudio(id):
            "Recording \(id.uuidString) is missing its local audio file."
        case let .transferFailed(message):
            message
        }
    }
}

nonisolated enum SyncConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a clean HTTPS Cloudflare Worker origin without username, password, path, query, or fragment."
        case .missingToken:
            "Enter the sync bearer token created for this app installation."
        }
    }
}

nonisolated struct SyncConfiguration: Equatable, Sendable {
    let endpoint: URL
    let token: String

    init(endpoint: String, token: String) throws {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw SyncConfigurationError.missingToken
        }
        guard var components = URLComponents(string: trimmedEndpoint),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw SyncConfigurationError.invalidEndpoint
        }
        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else {
            throw SyncConfigurationError.invalidEndpoint
        }
        components.scheme = "https"
        components.percentEncodedPath = ""
        guard let normalized = components.url else {
            throw SyncConfigurationError.invalidEndpoint
        }
        self.endpoint = normalized
        self.token = trimmedToken
    }

    func url(path: String) -> URL {
        endpoint.appending(path: path)
    }
}

nonisolated struct SyncHealth: Codable, Equatable, Sendable {
    let ok: Bool
    let schemaVersion: Int
}

nonisolated struct SyncRecordingPage: Codable, Equatable, Sendable {
    let recordings: [Recording]
    let nextCursor: String?
}

nonisolated struct MeetingNotesDescriptor: Codable, Equatable, Sendable {
    let recordingID: UUID
    let audioVersion: Int
    let generatedAtMillis: Int64
    let revision: String
    let byteCount: Int
}

nonisolated struct MeetingNotesPage: Codable, Equatable, Sendable {
    let notes: [MeetingNotesDescriptor]
    let nextCursor: String?
}

@MainActor
protocol SyncTransport: AnyObject {
    func health() async throws -> SyncHealth
    func listRecordings(cursor: String?) async throws -> SyncRecordingPage
    func putRecording(_ recording: Recording) async throws -> Recording
    func uploadAudio(for recording: Recording, from url: URL) async throws
    func downloadAudio(for recording: Recording, to url: URL) async throws
}

@MainActor
protocol MeetingNotesSyncTransport: SyncTransport {
    func listMeetingNotes(cursor: String?) async throws -> MeetingNotesPage
    func uploadMeetingNotes(_ document: MeetingNotesDocument, data: Data) async throws -> MeetingNotesDescriptor
    func downloadMeetingNotes(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws
}
