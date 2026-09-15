import Foundation

nonisolated struct WebSharePublication: Equatable, Sendable {
    let url: URL
    let expiresAt: Date
}

nonisolated struct WebShareStatus: Equatable, Sendable {
    let active: Bool
    let url: URL?
    let expiresAt: Date?

    init(active: Bool, url: URL? = nil, expiresAt: Date?) {
        self.active = active
        self.url = url
        self.expiresAt = expiresAt
    }
}

nonisolated enum WebShareError: LocalizedError, Equatable, Sendable {
    case invalidContent(String)
    case invalidResponse
    case activeLinkURLUnavailable
    case redirectRefused
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidContent(message):
            message
        case .invalidResponse:
            String(localized: "The sharing service returned an invalid response.")
        case .activeLinkURLUnavailable:
            String(localized: "The server could not restore the active link address. Update the sharing server, then reopen this window. You can still cancel sharing.")
        case .redirectRefused:
            String(localized: "Sharing stopped because the server tried to redirect the request.")
        case let .server(statusCode, message):
            String(localized: "Sharing server error \(statusCode): \(message)")
        }
    }
}

final class WebShareClient: @unchecked Sendable {
    nonisolated static let maximumMarkdownByteCount = 1 * 1_024 * 1_024

    private let configuration: SyncConfiguration
    private let session: URLSession
    private let redirectDelegate: WebShareRedirectRefusingDelegate?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: SyncConfiguration) {
        let redirectDelegate = WebShareRedirectRefusingDelegate()
        self.configuration = configuration
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        encoder.outputFormatting = [.sortedKeys]
    }

    init(configuration: SyncConfiguration, session: URLSession) {
        self.configuration = configuration
        self.session = session
        self.redirectDelegate = nil
        encoder.outputFormatting = [.sortedKeys]
    }

    func publish(sourceID: UUID, title: String, markdown: String) async throws -> WebSharePublication {
        let upload = try WebShareUpload(title: title, markdown: markdown)
        var request = request(path: "v1/shares/\(sourceID.uuidString.uppercased())")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try encoder.encode(upload)
        guard body.count <= Self.maximumMarkdownByteCount + 8 * 1_024 else {
            throw WebShareError.invalidContent(String(localized: "The minutes copy is too large to share."))
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try decoder.decode(WebSharePublicationResponse.self, from: data)
        guard let url = validatedPublicURL(decoded.url),
              let expiresAt = Date(millisecondsSince1970: decoded.expiresAt) else {
            throw WebShareError.invalidResponse
        }
        return WebSharePublication(url: url, expiresAt: expiresAt)
    }

    func status(sourceID: UUID) async throws -> WebShareStatus {
        var request = request(path: "v1/shares/\(sourceID.uuidString.uppercased())")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try decoder.decode(WebShareStatusResponse.self, from: data)
        guard decoded.active else { return WebShareStatus(active: false, expiresAt: nil) }
        guard let expiresAt = decoded.expiresAt.flatMap(Date.init(millisecondsSince1970:)) else {
            throw WebShareError.invalidResponse
        }
        guard let address = decoded.url else { throw WebShareError.activeLinkURLUnavailable }
        guard let url = validatedPublicURL(address) else { throw WebShareError.invalidResponse }
        return WebShareStatus(active: true, url: url, expiresAt: expiresAt)
    }

    func revoke(sourceID: UUID) async throws {
        var request = request(path: "v1/shares/\(sourceID.uuidString.uppercased())")
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw WebShareError.invalidResponse
        }
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.url(path: path))
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw WebShareError.invalidResponse
        }
        guard !(300..<400).contains(response.statusCode) else {
            throw WebShareError.redirectRefused
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = serverErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw WebShareError.server(statusCode: response.statusCode, message: sanitized(message))
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        guard let decoded = try? decoder.decode(WebShareServerErrorResponse.self, from: data) else {
            return String(data: data, encoding: .utf8)
        }
        if let code = decoded.error.code, !code.isEmpty {
            return "\(code): \(decoded.error.message)"
        }
        return decoded.error.message
    }

    private func sanitized(_ message: String) -> String {
        let sanitized = message
            .replacingOccurrences(of: configuration.token, with: "[sync key]")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitized.count > 240 else { return sanitized }
        return "\(sanitized.prefix(240))..."
    }

    private func validatedPublicURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              sameOrigin(url, configuration.endpoint),
              components.path.hasPrefix("/s/"),
              components.path.split(separator: "/").count == 2,
              let token = components.path.split(separator: "/").last,
              token.count == 43,
              token.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
              })
        else {
            return nil
        }
        return url
    }

    private func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host(percentEncoded: false)?.lowercased() == second.host(percentEncoded: false)?.lowercased()
            && first.port == second.port
    }
}

private struct WebShareUpload: Encodable {
    let title: String
    let markdown: String

    init(title: String, markdown: String) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw WebShareError.invalidContent(String(localized: "Enter a title before sharing."))
        }
        guard cleanTitle.unicodeScalars.count <= 300 else {
            throw WebShareError.invalidContent(String(localized: "The title is too long to share."))
        }
        guard !cleanMarkdown.isEmpty else {
            throw WebShareError.invalidContent(String(localized: "There is no minutes copy to share."))
        }
        guard cleanMarkdown.data(using: .utf8)?.count ?? 0 <= WebShareClient.maximumMarkdownByteCount else {
            throw WebShareError.invalidContent(String(localized: "The minutes copy is too large to share."))
        }
        self.title = cleanTitle
        self.markdown = cleanMarkdown
    }
}

private struct WebSharePublicationResponse: Decodable {
    let url: String
    let expiresAt: Int64
}

private struct WebShareStatusResponse: Decodable {
    let active: Bool
    let url: String?
    let expiresAt: Int64?
}

private struct WebShareServerErrorResponse: Decodable {
    struct Body: Decodable {
        let code: String?
        let message: String
    }

    let error: Body
}

private extension Date {
    init?(millisecondsSince1970 milliseconds: Int64) {
        guard milliseconds >= 0 else { return nil }
        self.init(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private final class WebShareRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
