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
    /// Friendly copy for the full-screen failed state.
    private(set) var failureMessage = ResultsViewModel.genericFailureMessage

    static let genericFailureMessage = "Couldn't come up with anything. Try again."
    private static let offlineMessage = "No internet connection. Check your network and try again."
    private static let timeoutMessage = "That took too long. Give it another try."

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

    /// Idempotency key for the current logical generation. A retry of a
    /// failed/timed-out generation reuses it (the backend then never
    /// double-charges); a genuinely new generation (initial load,
    /// Generate 3 More) mints a fresh one.
    private var generationRequestID = UUID()

    /// Full generation. `isRetry: true` = retrying the same logical request
    /// (Try Again); keeps the same request ID.
    func generate(isRetry: Bool = false) async {
        guard usage.canStartFullGeneration() else {
            onQuotaExhausted()
            return
        }
        if !isRetry {
            generationRequestID = UUID()
        }
        state = .analyzing
        inlineError = nil
        do {
            responses = try await generation.generate(
                for: input, goal: goal, requestID: generationRequestID
            )
            usage.consumeFullGeneration()
            state = .loaded
        } catch {
            handleGenerateFailure(error)
        }
    }

    /// Error → friendly UI state mapping happens here, at the ViewModel
    /// boundary. Raw backend/system errors never reach views.
    private func handleGenerateFailure(_ error: Error) {
        if case APIError.quotaExceeded = error {
            // Server-side refusal is authoritative — present the paywall.
            // Restore previous results if we had any (e.g. Generate 3 More).
            state = responses.isEmpty ? .failed : .loaded
            failureMessage = Self.genericFailureMessage
            onQuotaExhausted()
            return
        }
        failureMessage = friendlyMessage(for: error)
        state = .failed
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case APIError.offline: Self.offlineMessage
        case APIError.timeout: Self.timeoutMessage
        default: Self.genericFailureMessage
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
            // Each refinement tap is a new logical request → fresh ID.
            responses = try await generation.refine(
                action, input: input, goal: goal, previous: responses,
                requestID: UUID()
            )
            usage.consumeRefinement()
        } catch {
            if case APIError.quotaExceeded = error {
                onQuotaExhausted()
            } else if case APIError.offline = error {
                inlineError = Self.offlineMessage
            } else {
                inlineError = "That didn't work. Give it another try."
            }
        }
        isRefining = false
    }
}
