import Foundation

/// Client → backend request body for /generate. Encoded snake_case by
/// `APIClient.encoder` (`image_base64`, `previous_responses`, ...).
///
/// Contains no OpenAI-specific properties, prompt strings, or model names —
/// the backend owns all AI details.
///
/// Note: base64 inflates the screenshot payload by ~33%. Phase 3 already
/// caps processed screenshots near 1 MB, and we enforce a hard client-side
/// limit here; the server enforces its own body limit independently.
struct GenerationRequest: Encodable {
    struct Input: Encodable {
        enum Kind: String, Encodable {
            case text
            case image
        }

        let kind: Kind
        let text: String?
        let imageBase64: String?
    }

    /// Hard cap on processed screenshot bytes before base64 encoding.
    static let maxImageBytes = 3_000_000

    let input: Input
    let goal: ResponseGoal
    let refinement: RefinementAction?
    let previousResponses: [GeneratedResponse]?

    /// Base64 conversion happens here — at request-construction time only.
    /// The encoded string lives inside this value and goes out of scope
    /// with it after the request completes. Never persisted, never logged.
    init(
        input: ConversationInput,
        goal: ResponseGoal,
        refinement: RefinementAction? = nil,
        previousResponses: [GeneratedResponse]? = nil
    ) throws {
        switch input {
        case .pastedText(let text):
            self.input = Input(kind: .text, text: text, imageBase64: nil)
        case .screenshot(let imageData):
            guard !imageData.isEmpty, imageData.count <= Self.maxImageBytes else {
                throw APIError.invalidRequest(message: nil)
            }
            self.input = Input(kind: .image, text: nil, imageBase64: imageData.base64EncodedString())
        }
        self.goal = goal
        self.refinement = refinement
        self.previousResponses = previousResponses
    }
}
