import Foundation

/// Typed error taxonomy for backend calls. ViewModels map these to friendly
/// UI states — raw backend/system errors never reach the screen.
enum APIError: Error {
    case offline
    case timeout
    case unauthorized
    /// Server refused because quota is exhausted (HTTP 402). Carries the
    /// server's usage snapshot when the error body included one.
    case quotaExceeded(UsageStatus?)
    case rateLimited(retryAfter: TimeInterval?)
    /// Client-side or server-side invalid request (HTTP 400).
    case invalidRequest(message: String?)
    /// Non-HTTP response, undecodable body, or unexpected status.
    case invalidResponse
    case serverError
    /// Any other transport-level failure.
    case network(underlying: Error)
}

/// Safe structured error body the backend returns:
/// `{ "error": { "code": "...", "message": "..." }, "usage": { ... } }`
/// Messages are operator-facing; the UI shows its own copy instead.
struct BackendErrorPayload: Decodable {
    struct Info: Decodable {
        let code: String
        let message: String
    }

    let error: Info
    let usage: UsageStatus?
}
