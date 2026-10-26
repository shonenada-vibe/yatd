import Foundation

/// Sends a request to Notion's public API and returns the response body.
public protocol NotionTransport: Sendable {
    func api(_ path: String, method: String, body: [String: Any]?) async throws -> Data
}

extension NotionTransport {
    public func api(_ path: String, method: String) async throws -> Data {
        try await api(path, method: method, body: nil)
    }
}

/// Calls api.notion.com directly with an integration token. Used where `ntn` can't run,
/// e.g. the sandboxed App Store / TestFlight build.
public struct NotionHTTP: NotionTransport {
    public static let notionVersion = "2026-03-11"

    public let token: String
    public let baseURL: URL
    public let session: URLSession

    public init(token: String, baseURL: URL = URL(string: "https://api.notion.com")!, session: URLSession = .shared) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    public func api(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NotionError.httpFailed(status: status, body: Self.message(from: data))
        }
        return data
    }

    /// Notion errors look like `{"object":"error","code":"unauthorized","message":"..."}`.
    private static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String {
            return message
        }
        return String(decoding: data, as: UTF8.self)
    }
}
