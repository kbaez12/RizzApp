import Foundation

/// Honest read of a conversation, as returned by POST /analyze.
/// Decoded from snake_case by `APIClient`.
struct ChatAnalysis: Codable, Equatable {
    /// 0–100 estimates based only on visible texting signals.
    let yourInterest: Int
    let theirInterest: Int
    let vibe: String
    let greenFlags: [String]
    let redFlags: [String]
    /// One message the user could send next, in their style.
    let nextMove: String
}

struct AnalysisResult: Codable, Equatable {
    let analysis: ChatAnalysis
    let usage: UsageStatus
}

/// Client → backend body for /analyze: the conversation plus an
/// idempotency key. No goal — analysis is goal-independent.
struct AnalysisRequest: Encodable {
    let input: GenerationRequest.Input
    let requestId: UUID

    init(input: ConversationInput, requestID: UUID) throws {
        self.input = try GenerationRequest.Input(input)
        self.requestId = requestID
    }
}
