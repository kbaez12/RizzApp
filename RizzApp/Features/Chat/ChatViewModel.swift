import Foundation
import Observation
import UIKit

/// Drives the Chat tab as a message thread: the user's screenshot/text goes
/// out on the right, and goal options, replies and refinements come back as
/// bubbles on the left.
///
/// Quota decisions go through `UsageServicing` and are charged only on
/// success, so retries never double-charge. Messages live in memory only;
/// nothing is persisted and a new chat discards everything.
@MainActor
@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
    }

    enum Kind: Equatable {
        case userScreenshot
        case userText(String)
        case userChoice(String)
        case assistantText(String)
        case goalOptions
        case typing
        case reply(GeneratedResponse)
        case followUpOptions
        case error(String)
        case upgrade
    }

    private enum RetryAction {
        case generate(requestID: UUID)
        case refine(RefinementAction, requestID: UUID)
    }

    private(set) var messages: [Message] = []
    /// Decoded once for the thumbnail bubble; released on reset.
    private(set) var screenshotImage: UIImage?
    private(set) var isBusy = false
    var showsPrivacyDisclosure = false

    var hasConversation: Bool { input != nil }

    private var input: ConversationInput?
    private var goal: ResponseGoal?
    private var latestReplies: [GeneratedResponse] = []
    private var pendingGoal: ResponseGoal?
    private var retryAction: RetryAction?
    /// Changes on every reset so a late response from an abandoned chat is
    /// dropped instead of landing in the new one.
    private var sessionID = UUID()

    static let offlineMessage = "No internet connection. Check your network and try again."
    static let timeoutMessage = "That took too long. Give it another try."
    static let genericFailureMessage = "Couldn't come up with anything. Try again."

    private let generation: any GenerationServicing
    private let usage: any UsageServicing
    private let consent: PrivacyConsentStore
    private let onQuotaExhausted: () -> Void

    init(
        generation: any GenerationServicing,
        usage: any UsageServicing,
        consent: PrivacyConsentStore,
        onQuotaExhausted: @escaping () -> Void
    ) {
        self.generation = generation
        self.usage = usage
        self.consent = consent
        self.onQuotaExhausted = onQuotaExhausted
    }

    // MARK: - User actions

    func start(with input: ConversationInput) {
        reset()
        self.input = input
        switch input {
        case .screenshot(let data):
            screenshotImage = UIImage(data: data)
            append(.userScreenshot)
        case .pastedText(let text):
            append(.userText(text))
        }
        append(.assistantText("Got it 👀 What are you going for?"))
        append(.goalOptions)
    }

    func selectGoal(_ goal: ResponseGoal) async {
        guard !isBusy, input != nil else { return }
        guard consent.hasAcknowledged else {
            pendingGoal = goal
            showsPrivacyDisclosure = true
            return
        }
        guard usage.canStartFullGeneration() else {
            showUpgrade()
            return
        }
        self.goal = goal
        append(.userChoice(goal.label))
        await runGenerate(requestID: UUID())
    }

    func acknowledgePrivacy() async {
        consent.acknowledge()
        showsPrivacyDisclosure = false
        guard let goal = pendingGoal else { return }
        pendingGoal = nil
        await selectGoal(goal)
    }

    func declinePrivacy() {
        pendingGoal = nil
        showsPrivacyDisclosure = false
    }

    /// "Give me 3 more" — a new logical request, so a fresh request ID.
    func generateMore() async {
        guard !isBusy, goal != nil else { return }
        guard usage.canStartFullGeneration() else {
            showUpgrade()
            return
        }
        append(.userChoice("Give me 3 more"))
        await runGenerate(requestID: UUID())
    }

    func refine(_ action: RefinementAction) async {
        guard !isBusy, !latestReplies.isEmpty else { return }
        guard usage.canRefine() else {
            showUpgrade()
            return
        }
        append(.userChoice(action.label))
        await runRefine(action, requestID: UUID())
    }

    /// Retries the failed request with the SAME request ID, so the backend
    /// never charges twice for one logical request.
    func retry() async {
        guard !isBusy, let action = retryAction else { return }
        if case .error(_)? = messages.last?.kind {
            messages.removeLast()
        }
        switch action {
        case .generate(let requestID):
            await runGenerate(requestID: requestID)
        case .refine(let refinement, let requestID):
            await runRefine(refinement, requestID: requestID)
        }
    }

    func reset() {
        sessionID = UUID()
        messages = []
        screenshotImage = nil
        input = nil
        goal = nil
        latestReplies = []
        pendingGoal = nil
        retryAction = nil
        isBusy = false
        showsPrivacyDisclosure = false
    }

    /// Chips in a bubble are tappable only while it's the newest message.
    func isActive(_ message: Message) -> Bool {
        !isBusy && message.id == messages.last?.id
    }

    // MARK: - Requests

    private func runGenerate(requestID: UUID) async {
        guard let input, let goal else { return }
        let session = beginRequest()
        do {
            let replies = try await generation.generate(for: input, goal: goal, requestID: requestID)
            guard session == sessionID else { return }
            usage.consumeFullGeneration()
            show(replies, intro: "Here are 3 options. Tap one to copy it.")
        } catch {
            guard session == sessionID else { return }
            handleFailure(error, retry: .generate(requestID: requestID))
        }
    }

    private func runRefine(_ action: RefinementAction, requestID: UUID) async {
        guard let input, let goal else { return }
        let session = beginRequest()
        do {
            let replies = try await generation.refine(
                action, input: input, goal: goal, previous: latestReplies, requestID: requestID
            )
            guard session == sessionID else { return }
            usage.consumeRefinement()
            show(replies, intro: "Okay, try these:")
        } catch {
            guard session == sessionID else { return }
            handleFailure(error, retry: .refine(action, requestID: requestID))
        }
    }

    private func beginRequest() -> UUID {
        isBusy = true
        retryAction = nil
        append(.typing)
        return sessionID
    }

    private func show(_ replies: [GeneratedResponse], intro: String) {
        removeTyping()
        latestReplies = replies
        append(.assistantText(intro))
        replies.forEach { append(.reply($0)) }
        append(.followUpOptions)
        isBusy = false
    }

    /// Error → friendly bubble mapping happens here. Raw backend/system
    /// errors never reach views.
    private func handleFailure(_ error: Error, retry: RetryAction) {
        removeTyping()
        isBusy = false
        switch error {
        case APIError.quotaExceeded:
            showUpgrade()
        case APIError.offline:
            fail(Self.offlineMessage, retry: retry)
        case APIError.timeout:
            fail(Self.timeoutMessage, retry: retry)
        default:
            fail(Self.genericFailureMessage, retry: retry)
        }
    }

    private func fail(_ message: String, retry: RetryAction) {
        retryAction = retry
        append(.error(message))
    }

    private func showUpgrade() {
        if messages.last?.kind != .upgrade {
            append(.upgrade)
        }
        onQuotaExhausted()
    }

    private func append(_ kind: Kind) {
        messages.append(Message(kind: kind))
    }

    private func removeTyping() {
        messages.removeAll { $0.kind == .typing }
    }
}

extension ChatViewModel {
    static var preview: ChatViewModel {
        ChatViewModel(
            generation: MockGenerationService(),
            usage: MockUsageStore(),
            consent: PrivacyConsentStore(),
            onQuotaExhausted: {}
        )
    }
}
