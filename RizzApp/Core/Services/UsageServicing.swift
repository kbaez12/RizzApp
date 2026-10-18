import Foundation

/// Tracks and charges generation quota.
///
/// IMPORTANT: any client-side implementation is display/UX convenience only.
/// The backend is the authoritative quota enforcer (Phase 6). Never treat
/// this as production enforcement.
protocol UsageServicing: AnyObject {
    var status: UsageStatus { get }

    /// Whether a subscriber has monthly allowance for a full analysis.
    func canStartFullGeneration() -> Bool

    /// Charges one full analysis and resets the refinement budget.
    func consumeFullGeneration()

    /// Whether a refinement can run: an included refinement remains on the current
    /// analysis, or a full generation can be consumed instead.
    func canRefine() -> Bool

    /// Charges a refinement: uses the included budget first (2 per analysis),
    /// then falls back to consuming a full generation.
    func consumeRefinement()

    /// Fetches fresh usage from the backend when applicable. Mock/offline
    /// implementations use the default no-op.
    func refreshIfNeeded() async

    /// Marks cached usage stale so the next refresh re-fetches — used after
    /// a purchase, when the backend allowance has changed.
    func invalidate()
}

extension UsageServicing {
    func refreshIfNeeded() async {}
    func invalidate() {}
}
