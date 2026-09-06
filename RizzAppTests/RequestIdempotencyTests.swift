import XCTest
@testable import RizzApp

/// Captures the request IDs the ViewModel hands to the generation service.
private final class SpyGenerationService: GenerationServicing {
    var generateRequestIDs: [UUID] = []
    var refineRequestIDs: [UUID] = []
    var shouldFail = false

    private let canned = [
        GeneratedResponse(type: .natural, label: "Natural", text: "a"),
        GeneratedResponse(type: .bold, label: "Bolder", text: "b"),
        GeneratedResponse(type: .advance, label: "Make a Move", text: "c"),
    ]

    func generate(
        for input: ConversationInput,
        goal: ResponseGoal,
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        generateRequestIDs.append(requestID)
        if shouldFail { throw GenerationError.failed }
        return canned
    }

    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse],
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        refineRequestIDs.append(requestID)
        if shouldFail { throw GenerationError.failed }
        return canned
    }
}

/// Client-side idempotency-key lifecycle. (Quota arithmetic itself is NOT
/// tested here — the backend is authoritative; see the SQL/integration tests.)
@MainActor
final class RequestIdempotencyTests: XCTestCase {
    private func makeModel(spy: SpyGenerationService) -> ResultsViewModel {
        ResultsViewModel(
            input: .pastedText("convo"),
            goal: .flirty,
            generation: spy,
            usage: MockUsageStore(),
            onQuotaExhausted: {}
        )
    }

    func testRetryReusesSameRequestID() async {
        let spy = SpyGenerationService()
        let model = makeModel(spy: spy)

        spy.shouldFail = true
        await model.generate()            // initial attempt fails
        spy.shouldFail = false
        await model.generate(isRetry: true) // retry of the SAME logical request

        XCTAssertEqual(spy.generateRequestIDs.count, 2)
        XCTAssertEqual(
            spy.generateRequestIDs[0], spy.generateRequestIDs[1],
            "Retry must reuse the idempotency key so the backend never double-charges"
        )
    }

    func testNewGenerationGetsNewRequestID() async {
        let spy = SpyGenerationService()
        let model = makeModel(spy: spy)

        await model.generate()  // initial
        await model.generate()  // Generate 3 More — new logical request

        XCTAssertEqual(spy.generateRequestIDs.count, 2)
        XCTAssertNotEqual(spy.generateRequestIDs[0], spy.generateRequestIDs[1])
    }

    func testEachRefinementGetsDistinctRequestID() async {
        let spy = SpyGenerationService()
        let model = makeModel(spy: spy)

        await model.generate()
        await model.refine(.shorter)
        await model.refine(.bolder)

        XCTAssertEqual(spy.refineRequestIDs.count, 2)
        XCTAssertNotEqual(spy.refineRequestIDs[0], spy.refineRequestIDs[1])
    }

    func testQuotaExceededSnapshotUpdatesLiveUsage() async throws {
        // 402 from the backend → LiveGenerationService pushes the usage
        // snapshot before rethrowing, keeping displayed quota authoritative.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in
            (402, Data("""
            {
              "error": { "code": "QUOTA_EXCEEDED", "message": "No analyses remaining." },
              "usage": { "remaining": 0, "limit": 5, "tier": "free", "refinements_remaining": 0 }
            }
            """.utf8), [:])
        }
        defer { MockURLProtocol.handler = nil }

        let client = APIClient(
            config: APIConfig(
                baseURL: URL(string: "https://unit-test.invalid")!,
                publishableKey: "sb_publishable_test"
            ),
            installationID: "11111111-2222-4333-8444-555555555555",
            session: URLSession(configuration: configuration)
        )
        var captured: UsageStatus?
        let service = LiveGenerationService(client: client) { captured = $0 }

        do {
            _ = try await service.generate(
                for: .pastedText("hi"), goal: .flirty, requestID: UUID()
            )
            XCTFail("Expected quotaExceeded")
        } catch APIError.quotaExceeded(let usage) {
            XCTAssertEqual(usage?.remaining, 0)
        }
        XCTAssertEqual(captured?.remaining, 0, "402 snapshot must reach the usage service")
    }
}
