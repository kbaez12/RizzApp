import Foundation

/// Fake generation backend for Phase 2. Simulates latency and returns
/// curated responses from `MockResponseCatalog`.
final class MockGenerationService: GenerationServicing {
    /// Dev hook: probability (0...1) that a request fails, for testing
    /// error states. Set to 1.0 in code to force failures.
    var failureRate: Double = 0

    /// Tracks which round each goal is on so "Generate 3 More" varies.
    private var roundIndex: [ResponseGoal: Int] = [:]

    func generate(
        for input: ConversationInput,
        goal: ResponseGoal,
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        try await Task.sleep(for: .seconds(1.8))
        try simulateFailureIfNeeded()

        let rounds = MockResponseCatalog.rounds[goal] ?? []
        guard !rounds.isEmpty else { throw GenerationError.failed }

        let index = roundIndex[goal, default: 0]
        roundIndex[goal] = index + 1
        return rounds[index % rounds.count]
    }

    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse],
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        try await Task.sleep(for: .seconds(1.4))
        try simulateFailureIfNeeded()

        guard let refined = MockResponseCatalog.refined[action] else {
            throw GenerationError.failed
        }
        return refined
    }

    private func simulateFailureIfNeeded() throws {
        if failureRate > 0, Double.random(in: 0..<1) < failureRate {
            throw GenerationError.failed
        }
    }
}
