import Foundation

/// Produces an honest read of a conversation. Each analysis costs one full
/// analysis of quota (enforced by the backend in live mode).
protocol AnalysisServicing {
    func analyze(_ input: ConversationInput, requestID: UUID) async throws -> ChatAnalysis
}
