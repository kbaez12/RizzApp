import Foundation

/// A fake conversation used by the Phase 2 screenshot-preview mock.
/// Replaced by real selected images in Phase 3 (PhotosPicker).
struct MockMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isFromUser: Bool
}

struct MockConversation: Equatable {
    let messages: [MockMessage]

    /// Sample conversations the mock preview can cycle through via "Replace".
    static let samples: [MockConversation] = [
        MockConversation(messages: [
            MockMessage(text: "ok that concert story actually made me laugh out loud", isFromUser: false),
            MockMessage(text: "i have better ones but i ration them", isFromUser: true),
            MockMessage(text: "oh so you're withholding content from me now 😭", isFromUser: false),
        ]),
        MockConversation(messages: [
            MockMessage(text: "sorry i've been so slow replying, this week has been insane", isFromUser: false),
            MockMessage(text: "all good", isFromUser: true),
            MockMessage(text: "you're too nice to me lol", isFromUser: false),
        ]),
    ]
}
