import Foundation

/// The conversation the user wants help replying to.
///
/// Screenshots are held in memory only and never persisted by the app.
/// This abstraction is deliberate: V1 sends the image to a vision-capable
/// backend model, but a future version can OCR locally (Apple Vision) and
/// submit `.pastedText` instead — with no changes elsewhere in the app.
enum ConversationInput: Equatable {
    case screenshot(imageData: Data)
    case pastedText(String)
}
