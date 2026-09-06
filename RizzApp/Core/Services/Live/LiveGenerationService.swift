import Foundation

/// GenerationServicing implementation backed by our Supabase backend.
/// Phase 4A: the backend returns canned data (no AI yet) — this service
/// proves the client/server contract.
///
/// Privacy: the base64 image string exists only inside the transient
/// `GenerationRequest` value; it is never persisted, cached, or logged.
final class LiveGenerationService: GenerationServicing {
    private let client: APIClient
    /// Pushes server usage snapshots to the usage service so displayed
    /// quota tracks the backend.
    private let onUsageUpdate: (UsageStatus) -> Void

    init(client: APIClient, onUsageUpdate: @escaping (UsageStatus) -> Void = { _ in }) {
        self.client = client
        self.onUsageUpdate = onUsageUpdate
    }

    func generate(
        for input: ConversationInput,
        goal: ResponseGoal,
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        try await send(GenerationRequest(input: input, goal: goal, requestID: requestID))
    }

    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse],
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        try await send(GenerationRequest(
            input: input,
            goal: goal,
            requestID: requestID,
            refinement: action,
            previousResponses: previous
        ))
    }

    private func send(_ request: GenerationRequest) async throws -> [GeneratedResponse] {
        do {
            let result: GenerationResult = try await client.send(try .generate(request))
            onUsageUpdate(result.usage)
            return result.responses
        } catch APIError.quotaExceeded(let usage) {
            // Keep displayed quota in sync even on refusal.
            if let usage {
                onUsageUpdate(usage)
            }
            throw APIError.quotaExceeded(usage)
        }
    }
}
