import Foundation
import Observation

/// Coordinates generation, refinements, and quota for the Results screen.
/// All quota decisions go through `UsageServicing` — no arithmetic here or
/// in views. Quota is charged only on success, so retries never double-charge.
@MainActor
@Observable
final class ResultsViewModel {
    enum LoadState: Equatable {
        case analyzing
        case loaded
        case failed
    }

    private(set) var state: LoadState = .analyzing
    private(set) var responses: [GeneratedResponse] = []
    private(set) var isRefining = false
    /// Friendly, non-technical message for refinement failures
    /// (previous results stay visible).
    private(set) var inlineError: String?

    var remainingAnalyses: Int { usage.status.remaining }

    private let input: ConversationInput
    private let goal: ResponseGoal
    private let generation: any GenerationServicing
    private let usage: any UsageServicing
    /// Invoked when an action needs quota that isn't there — presents the paywall.
    private let onQuotaExhausted: () -> Void

    init(
        input: ConversationInput,
        goal: ResponseGoal,
        generation: any GenerationServicing,
        usage: any UsageServicing,
        onQuotaExhausted: @escaping () -> Void
    ) {
        self.input = input
        self.goal = goal
        self.generation = generation
        self.usage = usage
        self.onQuotaExhausted = onQuotaExhausted
    }

    /// Initial generation (also used by retry and Generate 3 More).
    func generate() async {
        guard usage.canStartFullGeneration() else {
            onQuotaExhausted()
            return
        }
        state = .analyzing
        inlineError = nil
        do {
            responses = try await generation.generate(for: input, goal: goal)
            usage.consumeFullGeneration()
            state = .loaded
        } catch {
            state = .failed
        }
    }

    func refine(_ action: RefinementAction) async {
        guard !isRefining else { return }
        guard usage.canRefine() else {
            onQuotaExhausted()
            return
        }
        isRefining = true
        inlineError = nil
        do {
            responses = try await generation.refine(
                action, input: input, goal: goal, previous: responses
            )
            usage.consumeRefinement()
        } catch {
            inlineError = "That didn't work. Give it another try."
        }
        isRefining = false
    }
}
