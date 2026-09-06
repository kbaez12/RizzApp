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

    private static let testInstallationID = "11111111-2222-4333-8444-555555555555"

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = APIClient(
            config: APIConfig(
                baseURL: URL(string: "https://unit-test.invalid")!,
                publishableKey: "sb_publishable_test"
            ),
            installationID: Self.testInstallationID,
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func stub(status: Int, json: String, headers: [String: String] = [:]) {
        MockURLProtocol.handler = { _ in (status, Data(json.utf8), headers) }
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
        let request = try GenerationRequest(input: .pastedText("hi"), goal: .flirty)
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
            captured?.value(forHTTPHeaderField: "X-Installation-ID"),
            Self.testInstallationID
        )
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

    func testQuotaExceededMappingCarriesUsage() async throws {
        stub(status: 402, json: """
        {
          "error": { "code": "QUOTA_EXCEEDED", "message": "No analyses remaining." },
          "usage": { "remaining": 0, "limit": 5, "tier": "free", "refinements_remaining": 0 }
        }
        """)
        do {
            let _: UsageStatus = try await client.send(.usage)
            XCTFail("Expected quotaExceeded")
        } catch APIError.quotaExceeded(let usage) {
            XCTAssertEqual(usage?.remaining, 0)
            XCTAssertEqual(usage?.limit, 5)
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
