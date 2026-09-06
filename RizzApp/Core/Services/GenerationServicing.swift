import Foundation

/// Generates reply options for a conversation. ViewModels depend on this
/// protocol only — Phase 2 uses `MockGenerationService`; Phase 4 swaps in a
/// live implementation that calls our backend.
/// `requestID` is the idempotency key for the logical request: retries of
/// the SAME logical action must reuse the same ID (so the backend never
/// charges quota twice), while each new action gets a fresh one. Mock
/// implementations ignore it.
protocol GenerationServicing: AnyObject {
    /// Returns exactly 3 strategically different replies for the conversation.
    func generate(
        for input: ConversationInput,
        goal: ResponseGoal,
        requestID: UUID
    ) async throws -> [GeneratedResponse]

    /// Adjusts the current set of replies with a refinement action.
    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse],
        requestID: UUID
    ) async throws -> [GeneratedResponse]
}

/// Errors surfaced by generation. Views map these to friendly copy —
/// technical details are never shown to users.
enum GenerationError: Error {
    case failed
}
