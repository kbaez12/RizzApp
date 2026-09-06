import Foundation

/// Generates reply options for a conversation. ViewModels depend on this
/// protocol only — Phase 2 uses `MockGenerationService`; Phase 4 swaps in a
/// live implementation that calls our backend.
protocol GenerationServicing: AnyObject {
    /// Returns exactly 3 strategically different replies for the conversation.
    func generate(
        for input: ConversationInput,
        goal: ResponseGoal
    ) async throws -> [GeneratedResponse]

    /// Adjusts the current set of replies with a refinement action.
    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse]
    ) async throws -> [GeneratedResponse]
}

/// Errors surfaced by generation. Views map these to friendly copy —
/// technical details are never shown to users.
enum GenerationError: Error {
    case failed
}
