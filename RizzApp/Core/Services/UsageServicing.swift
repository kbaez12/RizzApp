import Foundation

/// Tracks and charges generation quota.
///
/// IMPORTANT: any client-side implementation is display/UX convenience only.
/// The backend is the authoritative quota enforcer (Phase 6). Never treat
/// this as production enforcement.
protocol UsageServicing: AnyObject {
    var status: UsageStatus { get }

    /// Whether a full analysis can start (free lifetime or Plus monthly allowance).
    func canStartFullGeneration() -> Bool

    /// Charges one full analysis and resets the refinement budget.
    func consumeFullGeneration()

    /// Whether a refinement can run: a free refinement remains on the current
    /// analysis, or a full generation can be consumed instead.
    func canRefine() -> Bool

    /// Charges a refinement: uses the free budget first (2 per analysis),
    /// then falls back to consuming a full generation.
    func consumeRefinement()
}
