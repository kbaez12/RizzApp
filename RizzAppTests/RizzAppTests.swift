import XCTest
@testable import RizzApp

/// Placeholder suite so the test target builds. Real tests (API parsing,
/// usage limits, entitlements) arrive in later phases alongside the logic.
final class RizzAppTests: XCTestCase {
    func testGeneratedResponseDecoding() throws {
        let json = """
        {
          "responses": [
            { "type": "natural", "label": "Natural", "text": "hey" },
            { "type": "bold", "label": "Bolder", "text": "hey you" },
            { "type": "advance", "label": "Make a Move", "text": "come over" }
          ],
          "usage": { "remaining": 4, "limit": 5, "tier": "free", "refinementsRemaining": 2 }
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(GenerationResult.self, from: json)
        XCTAssertEqual(result.responses.count, 3)
        XCTAssertEqual(result.responses[0].type, .natural)
        XCTAssertEqual(result.usage.remaining, 4)
        XCTAssertEqual(result.usage.tier, .free)
    }
}
