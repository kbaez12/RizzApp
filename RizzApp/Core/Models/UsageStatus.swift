import Foundation

/// Usage quota as reported by the backend. The client displays this but the
/// backend is the authoritative enforcer — never gate purely on this value.
struct UsageStatus: Codable, Equatable {
    enum Tier: String, Codable {
        case free
        case plus
    }

    /// Full analyses remaining in the current period (lifetime for free tier).
    let remaining: Int
    let limit: Int
    let tier: Tier
    /// Refinement actions left on the current analysis before another
    /// full analysis is consumed (free follow-up budget, default 2).
    let refinementsRemaining: Int
}
