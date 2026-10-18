import Foundation

/// Generic async HTTP client for our backend. Builds requests, sends them,
/// inspects status codes, decodes typed responses, and maps failures to
/// `APIError`. No UI logic, no coupling to specific response types.
///
/// Headers sent on every request:
/// - `apikey`: the Supabase publishable key (client-safe project credential;
///   sent per Supabase's publishable-key pattern).
/// - `Authorization`: a short-lived Supabase anonymous-user JWT.
/// Conversation content only ever travels in request bodies, never headers,
/// and is never logged by this client.
final class APIClient {
    /// Shared JSON coding for the backend contract (snake_case wire format).
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let config: APIConfig
    private let accessToken: () async throws -> String
    private let session: URLSession

    init(
        config: APIConfig,
        session: URLSession = .shared,
        accessToken: @escaping () async throws -> String
    ) {
        self.config = config
        self.session = session
        self.accessToken = accessToken
    }

    func send<Response: Decodable>(_ endpoint: APIEndpoint) async throws -> Response {
        let request = try await buildRequest(for: endpoint)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError.offline
            case .timedOut:
                throw APIError.timeout
            case .cancelled:
                throw CancellationError()
            default:
                throw APIError.network(underlying: urlError)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try Self.decoder.decode(Response.self, from: data)
            } catch {
                throw APIError.invalidResponse
            }
        case 400:
            throw APIError.invalidRequest(message: backendPayload(from: data)?.error.message)
        case 401, 403:
            throw APIError.unauthorized
        case 402:
            throw APIError.subscriptionRequired
        case 409:
            let payload = backendPayload(from: data)
            guard payload?.error.code == "DUPLICATE_REQUEST" else {
                throw APIError.invalidResponse
            }
            throw APIError.duplicateRequest(payload?.usage)
        case 429:
            let payload = backendPayload(from: data)
            if payload?.error.code == "USAGE_LIMIT_EXCEEDED" {
                throw APIError.quotaExceeded(payload?.usage)
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw APIError.serverError
        default:
            throw APIError.invalidResponse
        }
    }

    private func buildRequest(for endpoint: APIEndpoint) async throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        #if DEBUG
        if let scenario = AppConfig.debugErrorScenario {
            request.setValue(scenario, forHTTPHeaderField: "x-debug-scenario")
        }
        #endif
        return request
    }

    private func backendPayload(from data: Data) -> BackendErrorPayload? {
        try? Self.decoder.decode(BackendErrorPayload.self, from: data)
    }
}
