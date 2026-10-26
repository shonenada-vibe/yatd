import Foundation
import Testing
@testable import YATDCore

/// Answers every request with a canned response and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct NotionHTTPTests {
    let http: NotionHTTP = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return NotionHTTP(token: "ntn_test", session: URLSession(configuration: config))
    }()

    @Test func sendsAuthVersionAndBody() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"ok":true}"#.utf8)
        let data = try await http.api("/v1/pages/abc", method: "PATCH", body: ["in_trash": true])
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)

        let req = try #require(StubProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.notion.com/v1/pages/abc")
        #expect(req.httpMethod == "PATCH")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_test")
        #expect(req.value(forHTTPHeaderField: "Notion-Version") == NotionHTTP.notionVersion)
        let sent = try #require(StubProtocol.lastBody)
        #expect((try JSONSerialization.jsonObject(with: sent) as? [String: Bool]) == ["in_trash": true])
    }

    @Test func mapsErrorsToNotionMessage() async {
        StubProtocol.status = 401
        StubProtocol.body = Data(#"{"object":"error","code":"unauthorized","message":"API token is invalid."}"#.utf8)
        await #expect {
            try await http.api("/v1/users/me", method: "GET")
        } throws: { error in
            guard case NotionError.httpFailed(401, "API token is invalid.") = error else { return false }
            return error.localizedDescription.contains("rejected the token")
        }
    }
}
