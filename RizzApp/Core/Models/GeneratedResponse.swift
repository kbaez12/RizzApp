import Foundation

/// One AI-generated reply option. Matches the backend API contract —
/// the UI never sees OpenAI-specific formats.
struct GeneratedResponse: Codable, Identifiable, Equatable {
    /// The strategic route this reply takes.
    enum Strategy: String, Codable {
        case natural
        case bold
        case advance
    }

    var id = UUID()
    let type: Strategy
    /// Server-provided display label, e.g. "Natural", "Bolder", "Make a Move".
    let label: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case type, label, text
    }
}

/// A full generation result: exactly three strategically different replies,
/// plus the caller's updated usage status.
struct GenerationResult: Codable, Equatable {
    let responses: [GeneratedResponse]
    let usage: UsageStatus
}
