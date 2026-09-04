import AuthenticationServices
import AppKit
import CryptoKit
import Foundation
import Security

struct RemoteTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        if let date = try? values.decode(Date.self, forKey: .expiresAt) {
            expiresAt = date
            return
        }
        let raw = try values.decode(String.self, forKey: .expiresAt)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        guard let date = fractional.date(from: raw) ?? ordinary.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: values,
                debugDescription: "Invalid RFC 3339 expiry"
            )
        }
        expiresAt = date
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accessToken, forKey: .accessToken)
        try values.encode(refreshToken, forKey: .refreshToken)
        try values.encode(expiresAt, forKey: .expiresAt)
    }
}

final class RemoteAPIClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let relayURL: URL
    private let session: URLSession
    private var authenticationSession: ASWebAuthenticationSession?

    init(relayURL: URL, session: URLSession = .shared) {
        self.relayURL = relayURL
        self.session = session
    }

    @MainActor
    func signIn(identity: RemoteDeviceIdentity) async throws -> RemoteTokens {
        let verifier = try Self.randomToken(byteCount: 32)
        let challenge = Self.pkceChallenge(verifier)
        var components = URLComponents(
            url: relayURL.appending(path: "v1/auth/google/start"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "callback", value: "kero://remote-auth"),
        ]
        guard let startURL = components.url else { throw RemoteAPIError.invalidURL }

        let callbackURL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let auth = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: "kero"
            ) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: RemoteAPIError.missingCallback) }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = true
            authenticationSession = auth
            guard auth.start() else {
                continuation.resume(throwing: RemoteAPIError.authenticationDidNotStart)
                return
            }
        }
        authenticationSession = nil
        guard let code = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw RemoteAPIError.missingCallback
        }
        return try await post(
            "v1/auth/exchange",
            body: [
                "code": code,
                "verifier": verifier,
                "id": identity.id.uuidString.lowercased(),
                "agreement_key": identity.record.agreementKey,
                "signing_key": identity.record.signingKey,
            ],
            as: RemoteTokens.self
        )
    }

    func refresh(_ refreshToken: String) async throws -> RemoteTokens {
        try await post(
            "v1/auth/refresh",
            body: ["refresh_token": refreshToken],
            as: RemoteTokens.self
        )
    }

    func register(identity: RemoteDeviceIdentity, accessToken: String) async throws {
        var request = authorizedRequest(path: "v1/devices", token: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(identity.record)
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    func devices(accessToken: String) async throws -> [RemoteDeviceRecord] {
        let (data, response) = try await session.data(
            for: authorizedRequest(path: "v1/devices", token: accessToken)
        )
        try Self.validate(response)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).devices
    }

    func revoke(deviceID: UUID, accessToken: String) async throws {
        var request = authorizedRequest(
            path: "v1/devices/\(deviceID.uuidString.lowercased())",
            token: accessToken
        )
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    func socket(deviceID: UUID, accessToken: String) -> URLSessionWebSocketTask {
        var components = URLComponents(
            url: relayURL.appending(path: "v1/socket"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "device_id", value: deviceID.uuidString.lowercased())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }

    private func authorizedRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: relayURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func post<T: Decodable>(
        _ path: String,
        body: [String: String],
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: relayURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw RemoteAPIError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw RemoteAPIError.randomGenerationFailed }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct DeviceResponse: Codable {
        let devices: [RemoteDeviceRecord]
    }
}

enum RemoteAPIError: Error {
    case invalidURL
    case missingCallback
    case authenticationDidNotStart
    case randomGenerationFailed
    case requestFailed(Int)
}

extension RemoteAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The relay URL is invalid.")
        case .missingCallback:
            String(localized: "The sign-in callback was missing.")
        case .authenticationDidNotStart:
            String(localized: "Could not start Google sign-in.")
        case .randomGenerationFailed:
            String(localized: "Could not create a secure sign-in challenge.")
        case .requestFailed:
            String(localized: "The relay request failed.")
        }
    }
}
