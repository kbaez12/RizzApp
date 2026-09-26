import Foundation
import Observation
import UIKit

/// Drives Analyze as a chat: the screenshot goes out on the right, and the
/// read comes back as incoming bubbles the user can act on.
///
/// Same rules as Chat: privacy consent first, quota via `UsageServicing`,
/// charged only on success, retries reuse the request ID.
@MainActor
@Observable
final class AnalyzeViewModel {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
    }

    enum Kind: Equatable {
        case userScreenshot
        case userText(String)
        case typing
        case assistantText(String)
        case interest(you: Int, them: Int)
        case flags(green: [String], red: [String])
        case nextMove(String)
        case followUp
        case error(String)
        case upgrade
    }

    private(set) var messages: [Message] = []
    private(set) var screenshotImage: UIImage?
    private(set) var isBusy = false
    var showsPrivacyDisclosure = false

    var hasConversation: Bool { input != nil }

    private var input: ConversationInput?
    private var requestID = UUID()
    private var sessionID = UUID()

    private let analysis: any AnalysisServicing
    private let usage: any UsageServicing
    private let consent: PrivacyConsentStore
    private let onQuotaExhausted: () -> Void

    init(
        analysis: any AnalysisServicing,
        usage: any UsageServicing,
        consent: PrivacyConsentStore,
        onQuotaExhausted: @escaping () -> Void
    ) {
        self.analysis = analysis
        self.usage = usage
        self.consent = consent
        self.onQuotaExhausted = onQuotaExhausted
    }

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
        append(.assistantText("Okay, I'll read the room."))
        guard consent.hasAcknowledged else {
            showsPrivacyDisclosure = true
            return
        }
        Task { await run(isRetry: false) }
    }

    func acknowledgePrivacy() async {
        consent.acknowledge()
        showsPrivacyDisclosure = false
        await run(isRetry: false)
    }

    func declinePrivacy() {
        showsPrivacyDisclosure = false
        reset()
    }

    func retry() async {
        if case .error(_)? = messages.last?.kind {
            messages.removeLast()
        }
        await run(isRetry: true)
    }

    func reset() {
        sessionID = UUID()
        messages = []
        input = nil
        screenshotImage = nil
        isBusy = false
        showsPrivacyDisclosure = false
    }

    func isActive(_ message: Message) -> Bool {
        !isBusy && message.id == messages.last?.id
    }

    private func run(isRetry: Bool) async {
        guard let input, !isBusy else { return }
        guard usage.canStartFullGeneration() else {
            showUpgrade()
            return
        }
        if !isRetry {
            requestID = UUID()
        }
        isBusy = true
        append(.typing)
        let session = sessionID
        do {
            let result = try await analysis.analyze(input, requestID: requestID)
            guard session == sessionID else { return }
            usage.consumeFullGeneration()
            removeTyping()
            append(.interest(you: result.yourInterest, them: result.theirInterest))
            append(.assistantText(result.vibe))
            if !result.greenFlags.isEmpty || !result.redFlags.isEmpty {
                append(.flags(green: result.greenFlags, red: result.redFlags))
            }
            append(.assistantText("If I were you, I'd send this:"))
            append(.nextMove(result.nextMove))
            append(.followUp)
            isBusy = false
        } catch {
            guard session == sessionID else { return }
            removeTyping()
            isBusy = false
            switch error {
            case APIError.quotaExceeded:
                showUpgrade()
            case APIError.offline:
                append(.error(ChatViewModel.offlineMessage))
            case APIError.timeout:
                append(.error(ChatViewModel.timeoutMessage))
            default:
                append(.error("Couldn't analyze that one. Try again."))
            }
        }
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

extension AnalyzeViewModel {
    static var preview: AnalyzeViewModel {
        AnalyzeViewModel(
            analysis: MockAnalysisService(),
            usage: MockUsageStore(),
            consent: PrivacyConsentStore(),
            onQuotaExhausted: {}
        )
    }
}
