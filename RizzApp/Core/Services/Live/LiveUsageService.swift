import Foundation
import Observation

/// UsageServicing implementation backed by GET /usage plus usage snapshots
/// piggybacked on generation responses.
///
/// In live mode the BACKEND is authoritative. This class keeps an in-memory
/// display cache: optimistic local decrements give instant UI feedback, and
/// every server response overwrites the cache with the truth. Phase 4B adds
/// real server-side quota persistence.
@Observable
final class LiveUsageService: UsageServicing {
    /// No optimistic allowance: access remains closed until the authenticated
    /// backend returns a subscriber snapshot.
    private(set) var cached = UsageStatus(remaining: 0, limit: 0, tier: .free, refinementsRemaining: 0)
    private var hasFetched = false

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    var status: UsageStatus { cached }

    func canStartFullGeneration() -> Bool {
        cached.remaining > 0
    }

    func consumeFullGeneration() {
        // Intentionally a no-op in live mode (Phase 4B): the backend charges
        // atomically and every generate/refine response carries the
        // authoritative usage snapshot, applied via apply(_:). Optimistic
        // local decrements would double-count on top of it.
    }

    func canRefine() -> Bool {
        cached.refinementsRemaining > 0 || canStartFullGeneration()
    }

    func consumeRefinement() {
        // No-op — see consumeFullGeneration().
    }

    func refreshIfNeeded() async {
        guard !hasFetched else { return }
        do {
            let status: UsageStatus = try await client.send(.usage)
            apply(status)
            hasFetched = true
        } catch {
            // Keep the closed cache. Bootstrap surfaces verification errors;
            // generation calls remain protected by the backend.
        }
    }

    /// Accepts an authoritative server snapshot. May be called from a
    /// background continuation — hops to main for observed-state mutation.
    func apply(_ status: UsageStatus) {
        if Thread.isMainThread {
            cached = status
        } else {
            DispatchQueue.main.async { self.cached = status }
        }
    }
}
