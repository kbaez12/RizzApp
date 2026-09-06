import Foundation

/// Declarative description of one backend call. We have exactly two
/// endpoints — deliberately not a networking framework.
struct APIEndpoint {
    enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    let path: String
    let method: Method
    /// Pre-encoded JSON body (snake_case), nil for GET.
    let body: Data?
    let timeout: TimeInterval

    /// POST /functions/v1/generate — generous timeout because Phase 5 puts
    /// a vision model behind this.
    static func generate(_ request: GenerationRequest) throws -> APIEndpoint {
        APIEndpoint(
            path: "functions/v1/generate",
            method: .post,
            body: try APIClient.encoder.encode(request),
            timeout: 60
        )
    }

    /// GET /functions/v1/usage
    static var usage: APIEndpoint {
        APIEndpoint(path: "functions/v1/usage", method: .get, body: nil, timeout: 15)
    }
}
