// App/session fixtures for compiling the production service in isolation.
// This file is appended to RemoteControlService.swift so its private token
// lifecycle is exercised without exposing test-only API in the application.
import AppKit

enum PaneSplitAxis: String, Codable, Sendable { case horizontal, vertical }
@MainActor final class AppSettings {
    static let shared = AppSettings()
    var remoteHostEnabled = true
    var remoteRelayURL = "https://relay.invalid"
}
@MainActor final class TerminalSession {
    let id = UUID()
    var hasExited = false
    func beginRemoteControl(resize: RemoteResize, output: @escaping (Data) -> Void) {}
    func endRemoteControl() {}
    func receiveRemoteInput(_ data: Data) {}
    func applyRemoteResize(_ resize: RemoteResize) {}
    func remoteBootstrap() async -> Data? { nil }
}
@MainActor enum TerminalManager {
    static func remoteSession(id: UUID) -> TerminalSession? { nil }
    static func remoteTopology(revision: UInt64) -> RemoteTopology {
        RemoteTopology(revision: revision, hostName: "Fixture", projects: [])
    }
}
enum RemoteKeychain {
    nonisolated(unsafe) static var values: [String: Data] = [:]
    static func data(for account: String) -> Data? { values[account] }
    static func set(_ data: Data, for account: String) throws { values[account] = data }
    static func remove(_ account: String) { values[account] = nil }
}

final class RelayResponses: @unchecked Sendable {
    enum Response { case failure(URLError.Code), http(Int, Data) }
    private let lock = NSLock()
    private var responses: [Response] = []
    func set(_ responses: [Response]) { lock.lock(); self.responses = responses; lock.unlock() }
    func next() -> Response { lock.lock(); defer { lock.unlock() }; return responses.removeFirst() }
}
final class RelayProtocol: URLProtocol, @unchecked Sendable {
    static let responses = RelayResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.responses.next() {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .http(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension RemoteControlService {
    static func verifyRefreshFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: AppSettings.shared.remoteRelayURL)!
        let expired = Data(#"{"access_token":"old-access","refresh_token":"old-refresh","expires_at":"2000-01-01T00:00:00Z"}"#.utf8)
        let renewed = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_at":"2100-01-01T00:00:00Z"}"#.utf8)
        for failure in [RelayResponses.Response.failure(.timedOut), .failure(.notConnectedToInternet), .http(500, Data()), .http(503, Data())] {
            let service = RemoteControlService()
            service.api = RemoteAPIClient(relayURL: url, session: session)
            service.tokens = try JSONDecoder().decode(RemoteTokens.self, from: expired)
            try service.persist(tokens: service.tokens!, relayURL: url)
            RelayProtocol.responses.set([failure, .http(200, renewed)])
            do { _ = try await service.validAccessToken(); preconditionFailure("expected refresh failure") }
            catch { precondition(!RemoteAPIError.invalidatesRefreshToken(error)) }
            precondition(service.tokens?.refreshToken == "old-refresh")
            precondition(RemoteKeychain.data(for: service.tokenKey(for: url)) != nil)
            let access = try await service.validAccessToken()
            precondition(access == "new-access", "network recovery did not reuse the retained refresh token")
            precondition(service.tokens?.refreshToken == "new-refresh")
        }
        let service = RemoteControlService()
        service.api = RemoteAPIClient(relayURL: url, session: session)
        service.tokens = try JSONDecoder().decode(RemoteTokens.self, from: expired)
        try service.persist(tokens: service.tokens!, relayURL: url)
        RelayProtocol.responses.set([.http(401, Data())])
        do { _ = try await service.validAccessToken(); preconditionFailure("expected rejected token") }
        catch { precondition(RemoteAPIError.invalidatesRefreshToken(error)) }
        precondition(service.tokens == nil && service.state == .signedOut)
        precondition(RemoteKeychain.data(for: service.tokenKey(for: url)) == nil)
        print("PASS: transient refresh failures retain credentials; 401 clears them")
    }
}
