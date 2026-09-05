import Foundation

/// What the user wants their reply to accomplish.
enum ResponseGoal: String, CaseIterable, Codable, Identifiable {
    case playful
    case flirty
    case funny
    case keepItGoing = "keep_it_going"
    case makeAMove = "make_a_move"
    case recoverThis = "recover_this"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playful: "Playful"
        case .flirty: "Flirty"
        case .funny: "Funny"
        case .keepItGoing: "Keep It Going"
        case .makeAMove: "Make A Move"
        case .recoverThis: "Recover This"
        }
    }

    var systemImage: String {
        switch self {
        case .playful: "face.smiling"
        case .flirty: "flame"
        case .funny: "theatermasks"
        case .keepItGoing: "bubble.left.and.bubble.right"
        case .makeAMove: "arrow.up.heart"
        case .recoverThis: "bandage"
        }
    }
}
