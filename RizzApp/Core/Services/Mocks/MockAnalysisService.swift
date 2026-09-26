import Foundation

/// Fake analysis with simulated latency, for mock mode and previews.
final class MockAnalysisService: AnalysisServicing {
    func analyze(_ input: ConversationInput, requestID: UUID) async throws -> ChatAnalysis {
        try await Task.sleep(for: .seconds(1.6))
        return ChatAnalysis(
            yourInterest: 68,
            theirInterest: 74,
            vibe: "Playful and easy. They're teasing you and asking questions back, which usually means they're into it.",
            greenFlags: ["Asks questions back", "Keeps the joke going", "Replies quickly"],
            redFlags: ["Hasn't suggested meeting yet"],
            nextMove: "ok but you still owe me that coffee. thursday?"
        )
    }
}
