import XCTest
@testable import RizzApp

/// Wire-format tests for the generation request contract (snake_case).
final class GenerationRequestTests: XCTestCase {
    private func encodeToDictionary(_ request: GenerationRequest) throws -> [String: Any] {
        let data = try APIClient.encoder.encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTextRequestEncoding() throws {
        let request = try GenerationRequest(
            input: .pastedText("them: hey lol"),
            goal: .keepItGoing
        )
        let json = try encodeToDictionary(request)
        let input = try XCTUnwrap(json["input"] as? [String: Any])

        XCTAssertEqual(input["kind"] as? String, "text")
        XCTAssertEqual(input["text"] as? String, "them: hey lol")
        XCTAssertNil(input["image_base64"])
        XCTAssertEqual(json["goal"] as? String, "keep_it_going")
        XCTAssertNil(json["refinement"] ?? nil)
        XCTAssertNil(json["previous_responses"] ?? nil)
    }

    func testScreenshotRequestEncoding() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let request = try GenerationRequest(
            input: .screenshot(imageData: imageData),
            goal: .flirty
        )
        let json = try encodeToDictionary(request)
        let input = try XCTUnwrap(json["input"] as? [String: Any])

        XCTAssertEqual(input["kind"] as? String, "image")
        XCTAssertEqual(input["image_base64"] as? String, imageData.base64EncodedString())
        XCTAssertNil(input["text"])
    }

    func testRefinementRequestEncoding() throws {
        let previous = [
            GeneratedResponse(type: .natural, label: "Natural", text: "hey"),
        ]
        let request = try GenerationRequest(
            input: .pastedText("convo"),
            goal: .funny,
            refinement: .moreLikeMe,
            previousResponses: previous
        )
        let json = try encodeToDictionary(request)

        XCTAssertEqual(json["refinement"] as? String, "more_like_me")
        let encoded = try XCTUnwrap(json["previous_responses"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 1)
        XCTAssertEqual(encoded[0]["type"] as? String, "natural")
        XCTAssertEqual(encoded[0]["text"] as? String, "hey")
    }

    func testOversizedImageThrows() {
        let oversized = Data(count: GenerationRequest.maxImageBytes + 1)
        XCTAssertThrowsError(
            try GenerationRequest(input: .screenshot(imageData: oversized), goal: .flirty)
        )
    }

    func testEmptyImageThrows() {
        XCTAssertThrowsError(
            try GenerationRequest(input: .screenshot(imageData: Data()), goal: .flirty)
        )
    }

    func testInstallationIdentityInjection() {
        let identity = StaticInstallationIdentity(installationID: "fixed-id")
        XCTAssertEqual(identity.installationID, "fixed-id")

        // Keychain-backed provider is stable within an instance.
        let keychain = KeychainInstallationIdentityService(service: "test.\(UUID().uuidString)")
        let first = keychain.installationID
        let second = keychain.installationID
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
    }
}
