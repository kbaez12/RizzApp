import SwiftUI
import Observation

/// Screens reachable by push navigation. Paywall and Settings are presented
/// as sheets (see `RootView`), not routes.
enum Route: Hashable {
    case screenshotPreview
    case pasteText
    case goalSelection
    case results
}

/// Owns cross-screen session state and the navigation path.
/// Conversation content lives only in memory and is cleared on reset.
@MainActor
@Observable
final class AppFlowModel {
    var path: [Route] = []

    // MARK: Session state
    var input: ConversationInput?
    var goal: ResponseGoal?
    var result: GenerationResult?

    // MARK: Sheets
    var isShowingSettings = false
    var isShowingPaywall = false

    // MARK: Flow actions

    /// Called after a screenshot has been successfully loaded and processed.
    /// Navigation to the preview only happens with a valid image in hand.
    func presentScreenshotPreview(imageData: Data) {
        input = .screenshot(imageData: imageData)
        path.append(.screenshotPreview)
    }

    /// Swaps the current screenshot (Replace flow). The previous image data
    /// is released as soon as the enum payload is overwritten.
    func replaceScreenshot(imageData: Data) {
        input = .screenshot(imageData: imageData)
    }

    func startPasteTextFlow() {
        path.append(.pasteText)
    }

    func continueToGoalSelection(with input: ConversationInput) {
        self.input = input
        path.append(.goalSelection)
    }

    func continueToResults(goal: ResponseGoal) {
        self.goal = goal
        path.append(.results)
    }

    /// Pops to Home and discards all conversation content.
    func resetSession() {
        path.removeAll()
        input = nil
        goal = nil
        result = nil
    }
}
