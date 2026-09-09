import CryptoKit
import Foundation

@MainActor
final class URLSessionSyncTransport: MeetingNotesSyncTransport, RecordingFolderSyncTransport, AISettingsSyncTransport, MeetingDataSyncTransport {
    nonisolated static let maxAudioByteCount = 95 * 1_024 * 1_024
    nonisolated static let maxMeetingNotesByteCount = 2 * 1_024 * 1_024
    nonisolated static let maxMeetingIntelligenceByteCount = 4 * 1_024 * 1_024

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

    func listRecordingFolders(cursor: String?) async throws -> RecordingFolderPage {
        var components = URLComponents(url: configuration.url(path: "v1/folders"), resolvingAgainstBaseURL: false)
        if let cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        guard let url = components?.url else {
            throw SyncError.invalidResponse
        }
        let (data, response) = try await session.data(for: request(url: url))
        try validate(response: response, data: data)
        return try decoder.decode(RecordingFolderPage.self, from: data)
    }

    func putRecordingFolder(_ folder: RecordingCollectionFolder) async throws -> RecordingCollectionFolder {
        var request = request(path: "v1/folders/\(folder.id.uuidString.uppercased())")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(folder)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(RecordingFolderResponse.self, from: data).folder
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

    func getMeetingProfile() async throws -> MeetingProfileResponse {
        try await requestMeetingProfile(request(path: "v1/profile"))
    }

    func putMeetingProfile(_ upload: MeetingProfileUpload) async throws -> MeetingProfileResponse {
        try upload.profile?.validate()
        var request = request(path: "v1/profile")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(upload)
        guard (request.httpBody?.count ?? 0) <= 64 * 1_024 else { throw SyncError.invalidResponse }
        return try await requestMeetingProfile(request)
    }

    func listMeetingIntelligence(cursor: String?) async throws -> MeetingIntelligencePage {
        var components = URLComponents(url: configuration.url(path: "v1/intelligence"), resolvingAgainstBaseURL: false)
        if let cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        guard let url = components?.url else {
            throw SyncError.invalidResponse
        }
        let (data, response) = try await session.data(for: request(url: url))
        try validate(response: response, data: data)
        return try decoder.decode(MeetingIntelligencePage.self, from: data)
    }

    func uploadMeetingIntelligence(_ document: MeetingIntelligenceDocument, data: Data) async throws -> MeetingNotesDescriptor {
        guard data.count <= Self.maxMeetingIntelligenceByteCount else {
            throw SyncError.transferFailed("Meeting intelligence is larger than the 4 MiB sync limit.")
        }
        var request = request(
            path: "v1/recordings/\(document.recordingID.uuidString.uppercased())/intelligence/\(document.audioVersion)"
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try validate(response: response, data: responseData)
        return try decoder.decode(MeetingIntelligenceResponse.self, from: responseData).intelligence
    }

    func downloadMeetingIntelligence(_ descriptor: MeetingNotesDescriptor, to url: URL) async throws {
        let request = request(
            path: "v1/recordings/\(descriptor.recordingID.uuidString.uppercased())/intelligence/\(descriptor.audioVersion)/\(descriptor.revision)"
        )
        let (downloadedURL, response) = try await session.download(for: request)
        do {
            try validateMeetingIntelligenceDownload(response: response, downloadedURL: downloadedURL, descriptor: descriptor)
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

    func listMeetingEdits(after cursor: Int64) async throws -> MeetingEditPage {
        var components = URLComponents(url: configuration.url(path: "v1/meeting-edits"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        guard let url = components?.url else { throw SyncError.invalidResponse }
        let (data, response) = try await session.data(for: request(url: url))
        try validate(response: response, data: data)
        return try decoder.decode(MeetingEditPage.self, from: data)
    }

    func uploadMeetingEdit(_ edit: MeetingEdit) async throws -> MeetingEditEntry {
        try edit.validate(recordingID: edit.recordingID, audioVersion: edit.audioVersion)
        var request = request(path: "v1/meeting-edits/\(edit.id.uuidString.uppercased())")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(edit)
        guard (request.httpBody?.count ?? 0) <= 16 * 1_024 else { throw SyncError.invalidResponse }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(MeetingEditResponse.self, from: data).entry
    }

    func getAISettings(deviceID: UUID) async throws -> AISettingsResponse {
        var components = URLComponents(url: configuration.url(path: "v1/ai-settings"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "deviceID", value: deviceID.uuidString)]
        guard let url = components?.url else { throw SyncError.invalidResponse }
        return try await requestAISettings(request(url: url))
    }

    func putAISettings(_ upload: AISettingsUpload) async throws -> AISettingsResponse {
        try upload.preferences?.validate()
        var request = request(path: "v1/ai-settings")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(upload)
        guard (request.httpBody?.count ?? 0) <= 16 * 1024 else { throw SyncError.invalidResponse }
        return try await requestAISettings(request)
    }

    private func requestAISettings(_ request: URLRequest) async throws -> AISettingsResponse {
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.expectedContentLength, length > 16 * 1024 {
            throw SyncError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1024 else { throw SyncError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        try validate(response: response, data: data)
        let decoded = try decoder.decode(AISettingsResponse.self, from: data)
        try decoded.preferences?.validate()
        return decoded
    }

    private func requestMeetingProfile(_ request: URLRequest) async throws -> MeetingProfileResponse {
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.expectedContentLength, length > 64 * 1_024 {
            throw SyncError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 64 * 1_024 else { throw SyncError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        try validate(response: response, data: data)
        let decoded = try decoder.decode(MeetingProfileResponse.self, from: data)
        try decoded.profile?.validate()
        return decoded
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

    private func validateMeetingIntelligenceDownload(
        response: URLResponse,
        downloadedURL: URL,
        descriptor: MeetingNotesDescriptor
    ) throws {
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
           byteCount != descriptor.byteCount || byteCount > Self.maxMeetingIntelligenceByteCount {
            throw SyncError.invalidResponse
        }
        let data = try Data(contentsOf: downloadedURL)
        guard data.count == descriptor.byteCount,
              data.count > 0,
              data.count <= Self.maxMeetingIntelligenceByteCount,
              Self.sha256Hex(data) == descriptor.revision
        else {
            throw SyncError.invalidResponse
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private struct RecordingFolderResponse: Decodable {
    let folder: RecordingCollectionFolder
}

private struct MeetingNotesResponse: Decodable {
    let note: MeetingNotesDescriptor
}

private struct MeetingIntelligenceResponse: Decodable {
    let intelligence: MeetingNotesDescriptor
}

private struct MeetingEditResponse: Decodable {
    let entry: MeetingEditEntry
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
