import XCTest
@testable import RizzApp

/// URLProtocol stub — no network access in tests.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (statusCode: Int, data: Data, headers: [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class APIClientTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = APIClient(
            config: APIConfig(
                baseURL: URL(string: "https://unit-test.invalid")!,
                publishableKey: "sb_publishable_test"
            ),
            session: URLSession(configuration: configuration),
            accessToken: { "test-user-jwt" }
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func stub(status: Int, json: String, headers: [String: String] = [:]) {
        MockURLProtocol.handler = { _ in (status, Data(json.utf8), headers) }
    }

    func testHostedDevelopmentConfigRequiresExplicitMatchingProjectRef() {
        let url = URL(string: "https://devproject.supabase.co")!
        let key = "sb_publishable_test"

        XCTAssertNil(APIConfig.development(baseURL: url, publishableKey: key))
        XCTAssertNil(APIConfig.development(
            baseURL: url,
            publishableKey: key,
            hostedProjectRef: "different",
            allowHosted: true
        ))
        XCTAssertNotNil(APIConfig.development(
            baseURL: url,
            publishableKey: key,
            hostedProjectRef: "devproject",
            allowHosted: true
        ))
    }

    func testAnonymousAuthCreatesSessionAndReturnsBearerToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let capture = SignupRequestCapture()
        MockURLProtocol.handler = { request in
            capture.record(request)
            return (200, Data("""
            {
              "access_token": "anonymous-jwt",
              "refresh_token": "refresh-token",
              "expires_in": 3600,
              "user": { "id": "11111111-2222-4333-8444-555555555555" }
            }
            """.utf8), [:])
        }
        let store = MemoryAuthTokenStore()
        let auth = SupabaseAuthService(
            config: APIConfig(
                baseURL: URL(string: "https://unit-test.invalid")!,
                publishableKey: "sb_publishable_test"
            ),
            session: URLSession(configuration: configuration),
            tokenStore: store
        )

        let user = try await auth.authenticatedUser()
        let (captured, capturedBody) = capture.snapshot()

        XCTAssertEqual(user.id, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(user.accessToken, "anonymous-jwt")
        XCTAssertEqual(store.token, "refresh-token")
        XCTAssertEqual(captured?.url?.path, "/auth/v1/signup")
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sb_publishable_test"
        )
        XCTAssertEqual(capturedBody, Data("{}".utf8))
    }

    func testRefreshServerErrorPreservesAnonymousIdentity() async {
        await assertRefreshPreservesIdentity(status: 503, json: #"{ "error": "unavailable" }"#)
    }

    func testRefreshRateLimitPreservesAnonymousIdentity() async {
        await assertRefreshPreservesIdentity(status: 429, json: #"{ "error": "over_request_rate_limit" }"#)
    }

    func testMalformedRefreshSuccessPreservesAnonymousIdentity() async {
        await assertRefreshPreservesIdentity(status: 200, json: "this is not a session {")
    }

    func testIncompleteRefreshSuccessPreservesAnonymousIdentity() async {
        await assertRefreshPreservesIdentity(
            status: 200,
            json: #"{ "access_token": "partial", "expires_in": 3600 }"#
        )
    }

    func testAmbiguousRefreshClientErrorPreservesAnonymousIdentity() async {
        await assertRefreshPreservesIdentity(status: 400, json: #"{ "msg": "bad request" }"#)
        await assertRefreshPreservesIdentity(status: 403, json: "{}")
    }

    func testConfirmedInvalidRefreshTokenMintsReplacementAnonymousUser() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/auth/v1/token") {
                return (400, Data(#"{ "error": "invalid_grant", "error_description": "Invalid Refresh Token" }"#.utf8), [:])
            }
            return (200, Data("""
            {
              "access_token": "replacement-jwt",
              "refresh_token": "replacement-refresh",
              "expires_in": 3600,
              "user": { "id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" }
            }
            """.utf8), [:])
        }
        let store = MemoryAuthTokenStore()
        store.token = "existing-refresh"
        let auth = makeAuthService(session: URLSession(configuration: configuration), store: store)

        let user = try await auth.authenticatedUser()

        XCTAssertEqual(user.id, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(store.token, "replacement-refresh")
        XCTAssertEqual(paths, ["/auth/v1/token", "/auth/v1/signup"])
    }

    private func assertRefreshPreservesIdentity(status: Int, json: String) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in (status, Data(json.utf8), [:]) }
        let store = MemoryAuthTokenStore()
        store.token = "existing-refresh"
        let auth = makeAuthService(session: URLSession(configuration: configuration), store: store)

        do {
            _ = try await auth.authenticatedUser()
            XCTFail("Refresh failure must fail closed")
        } catch AuthenticationError.unavailable {
            XCTAssertEqual(store.token, "existing-refresh")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    private func makeAuthService(
        session: URLSession,
        store: MemoryAuthTokenStore
    ) -> SupabaseAuthService {
        SupabaseAuthService(
            config: APIConfig(
                baseURL: URL(string: "https://unit-test.invalid")!,
                publishableKey: "sb_publishable_test"
            ),
            session: session,
            tokenStore: store
        )
    }

    // MARK: Success decoding

    func testSuccessfulGenerationDecode() async throws {
        stub(status: 200, json: """
        {
          "responses": [
            { "type": "natural", "label": "Natural", "text": "hey" },
            { "type": "bold", "label": "Bolder", "text": "hey you" },
            { "type": "advance", "label": "Make a Move", "text": "come thru" }
          ],
          "usage": { "remaining": 4, "limit": 5, "tier": "free", "refinements_remaining": 2 }
        }
        """)
        let request = try GenerationRequest(input: .pastedText("hi"), goal: .flirty, requestID: UUID())
        let result: GenerationResult = try await client.send(.generate(request))

        XCTAssertEqual(result.responses.count, 3)
        XCTAssertEqual(result.responses[1].type, .bold)
        XCTAssertEqual(result.usage.remaining, 4)
        XCTAssertEqual(result.usage.refinementsRemaining, 2)
    }

    func testUsageDecode() async throws {
        stub(status: 200, json: """
        { "remaining": 5, "limit": 5, "tier": "free", "refinements_remaining": 2 }
        """)
        let status: UsageStatus = try await client.send(.usage)

        XCTAssertEqual(status.remaining, 5)
        XCTAssertEqual(status.tier, .free)
    }

    func testAuthenticatedSubscriberUsageDecode() async throws {
        stub(status: 200, json: """
        { "subscribed": true, "remaining": 149, "limit": 150, "refinements_remaining": 2 }
        """)
        let status: UsageStatus = try await client.send(.usage)

        XCTAssertEqual(status.tier, .plus)
        XCTAssertEqual(status.remaining, 149)
        XCTAssertEqual(status.limit, 150)
    }

    // MARK: Header contract

    func testRequestCarriesRequiredHeaders() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            return (200, Data("""
            { "remaining": 5, "limit": 5, "tier": "free", "refinements_remaining": 2 }
            """.utf8), [:])
        }
        let _: UsageStatus = try await client.send(.usage)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-user-jwt"
        )
        XCTAssertNil(captured?.value(forHTTPHeaderField: "X-Installation-ID"))
    }

    // MARK: Error mapping

    func testBadRequestMapsToInvalidRequest() async throws {
        stub(status: 400, json: """
        { "error": { "code": "INVALID_REQUEST", "message": "Unsupported goal." } }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected invalidRequest")
        } catch APIError.invalidRequest(let message) {
            XCTAssertEqual(message, "Unsupported goal.")
        }
    }

    func testUnauthorizedMapping() async throws {
        stub(status: 401, json: """
        { "error": { "code": "UNAUTHORIZED", "message": "Missing API key." } }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected unauthorized")
        } catch APIError.unauthorized {
            // expected
        }
    }

    func testSubscriptionRequiredMapping() async throws {
        stub(status: 402, json: """
        {
          "error": { "code": "SUBSCRIPTION_REQUIRED", "message": "Subscription required." }
        }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected subscriptionRequired")
        } catch APIError.subscriptionRequired {
            // expected
        }
    }

    func testUsageLimitExceededMappingCarriesUsage() async throws {
        stub(status: 429, json: """
        {
          "error": { "code": "USAGE_LIMIT_EXCEEDED", "message": "Monthly allowance reached." },
          "usage": { "remaining": 0, "limit": 150, "tier": "plus", "refinements_remaining": 0 }
        }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected quotaExceeded")
        } catch APIError.quotaExceeded(let usage) {
            XCTAssertEqual(usage?.remaining, 0)
            XCTAssertEqual(usage?.limit, 150)
        }
    }

    func testDuplicateRequestMappingCarriesUsage() async throws {
        stub(status: 409, json: """
        {
          "error": { "code": "DUPLICATE_REQUEST", "message": "Already processed." },
          "usage": { "remaining": 4, "limit": 5, "tier": "free", "refinements_remaining": 2 }
        }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected duplicateRequest")
        } catch APIError.duplicateRequest(let usage) {
            XCTAssertEqual(usage?.remaining, 4)
            XCTAssertEqual(usage?.refinementsRemaining, 2)
        }
    }

    func testRateLimitedMappingParsesRetryAfter() async throws {
        stub(
            status: 429,
            json: #"{ "error": { "code": "RATE_LIMITED", "message": "Slow down." } }"#,
            headers: ["Retry-After": "30"]
        )
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected rateLimited")
        } catch APIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        }
    }

    func testServerErrorMapping() async throws {
        stub(status: 500, json: #"{ "error": { "code": "INTERNAL", "message": "boom" } }"#)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected serverError")
        } catch APIError.serverError {
            // expected
        }
    }

    func testMalformedJSONMapsToInvalidResponse() async throws {
        stub(status: 200, json: "this is not json {")
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected invalidResponse")
        } catch APIError.invalidResponse {
            // expected
        }
    }
}

/// Capture the body while URLProtocol owns the request, before responding.
private final class SignupRequestCapture {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    func record(_ request: URLRequest) {
        let body = Self.readBody(from: request)
        lock.lock()
        defer { lock.unlock() }
        self.request = request
        self.body = body
    }

    func snapshot() -> (URLRequest?, Data?) {
        lock.lock()
        defer { lock.unlock() }
        return (request, body)
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                XCTFail("Failed to read signup request body: \(String(describing: stream.streamError))")
                return nil
            }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class MemoryAuthTokenStore: AuthTokenStore {
    var token: String?
    func load() -> String? { token }
    func save(_ token: String) { self.token = token }
    func clear() { token = nil }
}
