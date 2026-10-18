import Foundation
import Security

struct AuthenticatedUser: Equatable {
    let id: String
    let accessToken: String
}

protocol AuthenticationServicing: AnyObject {
    func authenticatedUser() async throws -> AuthenticatedUser
    func accessToken() async throws -> String
}

enum AuthenticationError: Error {
    case invalidResponse
    case unavailable
    /// GoTrue confirmed the refresh token is invalid or revoked.
    /// Only this error may mint a replacement anonymous user.
    case refreshTokenRejected
}

/// Minimal client for Supabase Auth's documented anonymous sign-in and
/// refresh-token endpoints. The refresh token is device-only Keychain data;
/// access tokens are kept in memory and refreshed before expiry.
actor SupabaseAuthService: AuthenticationServicing {
    private struct SessionResponse: Decodable {
        struct User: Decodable {
            let id: String
        }

        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let user: User
    }

    private struct RefreshBody: Encodable {
        let refreshToken: String
    }

    private let config: APIConfig
    private let session: URLSession
    private let tokenStore: AuthTokenStore
    private var current: SessionResponse?
    private var expiresAt = Date.distantPast

    init(
        config: APIConfig,
        session: URLSession = .shared,
        tokenStore: AuthTokenStore = KeychainAuthTokenStore()
    ) {
        self.config = config
        self.session = session
        self.tokenStore = tokenStore
    }

    func authenticatedUser() async throws -> AuthenticatedUser {
        let session = try await validSession()
        return AuthenticatedUser(id: session.user.id, accessToken: session.accessToken)
    }

    func accessToken() async throws -> String {
        let session = try await validSession()
        return session.accessToken
    }

    private func validSession() async throws -> SessionResponse {
        if let current, expiresAt.timeIntervalSinceNow > 60 {
            return current
        }

        if let refreshToken = tokenStore.load() {
            do {
                return try await requestSession(
                    path: "auth/v1/token",
                    queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                    body: RefreshBody(refreshToken: refreshToken),
                    kind: .refresh
                )
            } catch AuthenticationError.refreshTokenRejected {
                tokenStore.clear()
            }
        }

        // GoTrue anonymous sign-in is POST /auth/v1/signup with `{}`.
        // That is the documented HTTP equivalent of signInAnonymously().
        return try await requestSession(
            path: "auth/v1/signup",
            queryItems: [],
            body: EmptyBody(),
            kind: .signup
        )
    }

    private enum SessionKind {
        case refresh
        case signup
    }

    private struct AuthErrorBody: Decodable {
        let error: String?
        let errorCode: String?
        let errorDescription: String?
        let msg: String?
    }

    private func requestSession<Body: Encodable>(
        path: String,
        queryItems: [URLQueryItem],
        body: Body,
        kind: SessionKind
    ) async throws -> SessionResponse {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw AuthenticationError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.supabase.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthenticationError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.unavailable
        }
        guard (200...299).contains(http.statusCode) else {
            if kind == .refresh, isConfirmedRefreshRejection(status: http.statusCode, data: data) {
                throw AuthenticationError.refreshTokenRejected
            }
            throw AuthenticationError.unavailable
        }
        guard let result = try? JSONDecoder.supabase.decode(SessionResponse.self, from: data),
              UUID(uuidString: result.user.id) != nil,
              !result.accessToken.isEmpty,
              !result.refreshToken.isEmpty else {
            // A 2xx body we cannot decode is not proof the refresh token is
            // dead. Fail closed and keep Keychain credentials for retry.
            throw AuthenticationError.unavailable
        }

        current = result
        expiresAt = Date().addingTimeInterval(result.expiresIn)
        tokenStore.save(result.refreshToken)
        return result
    }

    /// GoTrue uses `invalid_grant` / `refresh_token_not_found` when the
    /// stored refresh token is actually unusable. Unknown 400–403 bodies,
    /// already-used rotation races, and empty error JSON stay unavailable.
    private func isConfirmedRefreshRejection(status: Int, data: Data) -> Bool {
        guard [400, 401, 403].contains(status) else { return false }
        guard let body = try? JSONDecoder.supabase.decode(AuthErrorBody.self, from: data) else {
            return false
        }
        let error = (body.error ?? "").lowercased()
        let code = (body.errorCode ?? "").lowercased()
        if error == "invalid_grant" { return true }
        if code == "refresh_token_not_found" || code == "invalid_refresh_token" {
            return true
        }
        return false
    }
}

private struct EmptyBody: Encodable {}

private extension JSONEncoder {
    static let supabase: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

private extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

protocol AuthTokenStore: AnyObject {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

final class KeychainAuthTokenStore: AuthTokenStore {
    private let service: String
    private let account = "supabase-anonymous-refresh-token"

    init(service: String = "com.zenomedia.greenshot") {
        self.service = service
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
