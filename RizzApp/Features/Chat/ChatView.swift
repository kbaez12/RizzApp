import SwiftUI
import PhotosUI

/// Chat tab. Empty state invites a screenshot or pasted text; after that the
/// whole flow happens as a conversation — options arrive as bubbles and the
/// user taps them.
struct ChatView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(ChatViewModel.self) private var chat

    @State private var picker = ScreenshotPickerViewModel()
    @State private var isPickerPresented = false
    @State private var isPasteSheetPresented = false
    @State private var isShowingFullScreenshot = false

    var body: some View {
        @Bindable var chat = chat

        VStack(spacing: 0) {
            AppHeader(
                onMenu: { flow.isShowingMenu = true },
                trailingSystemImage: chat.hasConversation ? "plus" : nil,
                trailingLabel: "New chat",
                onTrailing: { withAnimation { chat.reset() } }
            )

            if chat.hasConversation {
                conversation
            } else {
                emptyState
            }
        }
        .background(GradientBackground())
        .photosPicker(isPresented: $isPickerPresented, selection: $picker.selectedItem, matching: .images)
        .onChange(of: picker.selectedItem) { _, item in
            picker.handleSelection(item) { data in
                withAnimation { chat.start(with: .screenshot(imageData: data)) }
            }
        }
        .sheet(isPresented: $isPasteSheetPresented) {
            PasteTextSheet { text in
                withAnimation { chat.start(with: .pastedText(text)) }
            }
        }
        .sheet(isPresented: $chat.showsPrivacyDisclosure) {
            PrivacyDisclosureView(
                onAcknowledge: { Task { await chat.acknowledgePrivacy() } },
                onCancel: { chat.declinePrivacy() }
            )
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $isShowingFullScreenshot) {
            FullScreenshotView(image: chat.screenshotImage)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.md)

            SampleThread()

            VStack(spacing: Spacing.sm) {
                Text("Upload a screenshot\nof a chat")
                    .font(Typography.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                Text("Get 3 replies that actually sound like you.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Spacing.md)

            VStack(spacing: Spacing.md) {
                Button {
                    isPickerPresented = true
                } label: {
                    if picker.isLoading {
                        LoadingDots(color: .white, size: 8)
                    } else {
                        Label("Upload a Screenshot", systemImage: "photo.on.rectangle")
                    }
                }
                .buttonStyle(.primary)
                .disabled(picker.isLoading)

                Button {
                    isPasteSheetPresented = true
                } label: {
                    Label("Enter Text Manually", systemImage: "text.cursor")
                }
                .buttonStyle(.secondary)
                .disabled(picker.isLoading)

                if let errorMessage = picker.errorMessage {
                    Text(errorMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
        .padding(.horizontal, Spacing.screenMargin)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.sm + 2) {
                    ForEach(chat.messages) { message in
                        messageView(message)
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) {
                guard let last = chat.messages.last else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: chat.messages)
    }

    @ViewBuilder
    private func messageView(_ message: ChatViewModel.Message) -> some View {
        let isActive = chat.isActive(message)
        switch message.kind {
        case .userScreenshot:
            ScreenshotBubble(image: chat.screenshotImage) { isShowingFullScreenshot = true }
        case .userText(let text):
            OutgoingBubble(text: text)
        case .userChoice(let text):
            OutgoingBubble(text: text)
        case .assistantText(let text):
            IncomingTextBubble(text: text)
        case .typing:
            TypingBubble()
        case .reply(let response):
            ReplyBubble(response: response)
        case .goalOptions:
            OptionsBubble(isActive: isActive) {
                ForEach(ResponseGoal.allCases) { goal in
                    Button {
                        Task { await chat.selectGoal(goal) }
                    } label: {
                        Label(goal.label, systemImage: goal.systemImage)
                    }
                    .buttonStyle(.pill)
                }
            }
        case .followUpOptions:
            OptionsBubble(title: "Want to tweak them?", isActive: isActive) {
                ForEach(RefinementAction.allCases) { action in
                    Button(action.label) { Task { await chat.refine(action) } }
                        .buttonStyle(.pill)
                }
                Button {
                    Task { await chat.generateMore() }
                } label: {
                    Label("3 More", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.pill)
                Button {
                    withAnimation { chat.reset() }
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .buttonStyle(.pill)
            }
        case .error(let text):
            OptionsBubble(title: text, isActive: isActive) {
                Button {
                    Task { await chat.retry() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.pill)
            }
        case .upgrade:
            OptionsBubble(
                title: "You've used your free replies. Plus gives you 150 a month.",
                isActive: true
            ) {
                Button {
                    flow.isShowingPaywall = true
                } label: {
                    Label("See Plus", systemImage: "sparkles")
                }
                .buttonStyle(.pill)
            }
        }
    }
}

/// Decorative example thread on the empty state.
private struct SampleThread: View {
    var body: some View {
        VStack(spacing: Spacing.sm) {
            IncomingTextBubble(text: "so what do you do for fun")
            OutgoingBubble(text: "mostly lose at mini golf")
            IncomingTextBubble(text: "lol same. rematch?")
        }
        .frame(maxWidth: 320)
        .accessibilityHidden(true)
    }
}

private struct FullScreenshotView: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}

#Preview {
    ChatView()
        .environment(AppFlowModel())
        .environment(ChatViewModel.preview)
}
