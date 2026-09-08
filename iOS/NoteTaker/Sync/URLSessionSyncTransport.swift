import Foundation

@MainActor
final class URLSessionSyncTransport: MeetingNotesSyncTransport {
    nonisolated static let maxAudioByteCount = 95 * 1_024 * 1_024
    nonisolated static let maxMeetingNotesByteCount = 2 * 1_024 * 1_024

    private let configuration: SyncConfiguration
    private let session: URLSession
    private let redirectDelegate: RedirectRefusingDelegate?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: SyncConfiguration) {
        let redirectDelegate = RedirectRefusingDelegate()
        self.redirectDelegate = redirectDelegate
        self.configuration = configuration
        self.session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    init(configuration: SyncConfiguration, session: URLSession) {
        self.configuration = configuration
        self.session = session
        self.redirectDelegate = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func health() async throws -> SyncHealth {
        let (data, response) = try await session.data(for: request(path: "v1/health"))
        try validate(response: response, data: data)
        return try decoder.decode(SyncHealth.self, from: data)
    }

    func listRecordings(cursor: String?) async throws -> SyncRecordingPage {
        var components = URLComponents(url: configuration.url(path: "v1/recordings"), resolvingAgainstBaseURL: false)
        if let cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        guard let url = components?.url else {
            throw SyncError.invalidResponse
        }
        let (data, response) = try await session.data(for: request(url: url))
        try validate(response: response, data: data)
        return try decoder.decode(SyncRecordingPage.self, from: data)
    }

    func putRecording(_ recording: Recording) async throws -> Recording {
        var request = request(path: "v1/recordings/\(recording.id.uuidString.uppercased())")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(recording)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(SyncRecordingResponse.self, from: data).recording
    }

    func uploadAudio(for recording: Recording, from url: URL) async throws {
        let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard byteCount <= Self.maxAudioByteCount else {
            throw SyncError.audioTooLarge(limitBytes: Self.maxAudioByteCount)
        }
        var request = request(
            path: "v1/recordings/\(recording.id.uuidString.uppercased())/audio/\(recording.audioVersion)"
        )
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: url)
        try validate(response: response, data: data)
    }

    func downloadAudio(for recording: Recording, to url: URL) async throws {
        let request = request(
            path: "v1/recordings/\(recording.id.uuidString.uppercased())/audio/\(recording.audioVersion)"
        )
        let (downloadedURL, response) = try await session.download(for: request)
        do {
            try validateAudioDownload(response: response, downloadedURL: downloadedURL)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: downloadedURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
    }

    func listMeetingNotes(cursor: String?) async throws -> MeetingNotesPage {
        var components = URLComponents(url: configuration.url(path: "v1/notes"), resolvingAgainstBaseURL: false)
        if let cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        guard let url = components?.url else {
            throw SyncError.invalidResponse
        }
        let (data, response) = try await session.data(for: request(url: url))
        try validate(response: response, data: data)
        return try decoder.decode(MeetingNotesPage.self, from: data)
    }

    func uploadMeetingNotes(_ document: MeetingNotesDocument, data: Data) async throws -> MeetingNotesDescriptor {
        guard data.count <= Self.maxMeetingNotesByteCount else {
            throw SyncError.transferFailed("Meeting notes are larger than the 2 MiB sync limit.")
        }
        var request = request(
            path: "v1/recordings/\(document.recordingID.uuidString.uppercased())/notes/\(document.audioVersion)"
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try validate(response: response, data: responseData)
        return try decoder.decode(MeetingNotesResponse.self, from: responseData).note
    }

    func downloadMeetingNotes(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws {
        let request = request(
            path: "v1/recordings/\(descriptor.recordingID.uuidString.uppercased())/notes/\(descriptor.audioVersion)/\(descriptor.revision)"
        )
        let (downloadedURL, response) = try await session.download(for: request)
        do {
            try validateMeetingNotesDownload(response: response, downloadedURL: downloadedURL)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: downloadedURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
    }

    private func request(path: String) -> URLRequest {
        request(url: configuration.url(path: path))
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        guard !(300..<400).contains(response.statusCode) else {
            throw SyncError.redirectRefused
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = serverErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw SyncError.server(statusCode: response.statusCode, message: message)
        }
    }

    private func validateAudioDownload(response: URLResponse, downloadedURL: URL) throws {
        try validate(response: response, data: Data())
        guard let response = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.split(separator: ";", maxSplits: 1).first == "audio/mp4" else {
            throw SyncError.invalidResponse
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let byteCount = Int(contentLength),
           byteCount > Self.maxAudioByteCount {
            throw SyncError.audioTooLarge(limitBytes: Self.maxAudioByteCount)
        }
        let fileSize = try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else {
            throw SyncError.invalidResponse
        }
        guard fileSize <= Self.maxAudioByteCount else {
            throw SyncError.audioTooLarge(limitBytes: Self.maxAudioByteCount)
        }
    }

    private func validateMeetingNotesDownload(response: URLResponse, downloadedURL: URL) throws {
        try validate(response: response, data: Data())
        guard let response = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.split(separator: ";", maxSplits: 1).first == "application/json" else {
            throw SyncError.invalidResponse
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let byteCount = Int(contentLength),
           byteCount > Self.maxMeetingNotesByteCount {
            throw SyncError.transferFailed("Meeting notes are larger than the 2 MiB sync limit.")
        }
        let fileSize = try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else {
            throw SyncError.invalidResponse
        }
        guard fileSize <= Self.maxMeetingNotesByteCount else {
            throw SyncError.transferFailed("Meeting notes are larger than the 2 MiB sync limit.")
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        guard let decoded = try? decoder.decode(SyncServerErrorResponse.self, from: data) else {
            return nil
        }
        if let code = decoded.error.code, !code.isEmpty {
            return "\(code): \(decoded.error.message)"
        }
        return decoded.error.message
    }
}

private struct SyncRecordingResponse: Decodable {
    let recording: Recording
}

private struct MeetingNotesResponse: Decodable {
    let note: MeetingNotesDescriptor
}

private struct SyncServerErrorResponse: Decodable {
    struct Body: Decodable {
        let code: String?
        let message: String
    }

    let error: Body
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
