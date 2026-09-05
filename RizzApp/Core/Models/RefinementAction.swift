import Foundation

/// Follow-up adjustments the user can apply to the current set of responses.
enum RefinementAction: String, Codable, CaseIterable, Identifiable {
    case shorter
    case bolder
    case moreLikeMe = "more_like_me"
    case lessCringe = "less_cringe"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shorter: "Shorter"
        case .bolder: "Bolder"
        case .moreLikeMe: "More Like Me"
        case .lessCringe: "Less Cringe"
        }
    }
}
