import Foundation

/// Usage quota as reported by the backend. The client displays this but the
/// backend is the authoritative enforcer — never gate purely on this value.
struct UsageStatus: Codable, Equatable {
    enum Tier: String, Codable {
        case free
        case plus
    }

    /// Full analyses remaining in the active subscriber's billing period.
    let remaining: Int
    let limit: Int
    let tier: Tier
    /// Refinement actions left on the current analysis before another
    /// full analysis is consumed (included follow-up budget, default 2).
    let refinementsRemaining: Int

    private enum CodingKeys: String, CodingKey {
        case remaining
        case limit
        case tier
        case subscribed
        case refinementsRemaining
    }

    init(remaining: Int, limit: Int, tier: Tier, refinementsRemaining: Int) {
        self.remaining = remaining
        self.limit = limit
        self.tier = tier
        self.refinementsRemaining = refinementsRemaining
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try container.decode(Int.self, forKey: .remaining)
        limit = try container.decode(Int.self, forKey: .limit)
        refinementsRemaining = try container.decode(Int.self, forKey: .refinementsRemaining)
        if let tier = try container.decodeIfPresent(Tier.self, forKey: .tier) {
            self.tier = tier
        } else {
            self.tier = try container.decode(Bool.self, forKey: .subscribed) ? .plus : .free
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remaining, forKey: .remaining)
        try container.encode(limit, forKey: .limit)
        try container.encode(tier, forKey: .tier)
        try container.encode(tier == .plus, forKey: .subscribed)
        try container.encode(refinementsRemaining, forKey: .refinementsRemaining)
    }
}
