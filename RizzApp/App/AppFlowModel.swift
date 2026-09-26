import Observation

/// App-level navigation: which tab is selected and which app-wide sheets
/// are showing. Conversation state lives in `ChatViewModel` /
/// `AnalyzeViewModel`, not here.
@Observable
final class AppFlowModel {
    enum Tab: Hashable {
        case chat
        case analyze
        case settings
    }

    /// Actions chosen from the menu sheet, run after it finishes dismissing
    /// so two sheets never animate at once.
    enum MenuAction {
        case upgrade
        case settings
    }

    var selectedTab: Tab = .chat
    var isShowingPaywall = false
    var isShowingMenu = false
    private var pendingMenuAction: MenuAction?

    func choose(_ action: MenuAction) {
        pendingMenuAction = action
        isShowingMenu = false
    }

    func menuDidDismiss() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        switch action {
        case .upgrade: isShowingPaywall = true
        case .settings: selectedTab = .settings
        }
    }
}
