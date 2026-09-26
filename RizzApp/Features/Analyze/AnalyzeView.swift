import SwiftUI
import PhotosUI
import UIKit

/// Analyze tab. Empty state invites a screenshot; after that the read
/// arrives as incoming chat bubbles — same feel as Chat.
struct AnalyzeView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(AnalyzeViewModel.self) private var model

    @State private var picker = ScreenshotPickerViewModel()
    @State private var isPickerPresented = false
    @State private var isPasteSheetPresented = false
    @State private var isShowingFullScreenshot = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            AppHeader(
                onMenu: { flow.isShowingMenu = true },
                trailingSystemImage: model.hasConversation ? "plus" : nil,
                trailingLabel: "New analysis",
                onTrailing: { withAnimation { model.reset() } }
            )

            if model.hasConversation {
                conversation
            } else {
                emptyState
            }
        }
        .background(GradientBackground())
        .photosPicker(isPresented: $isPickerPresented, selection: $picker.selectedItem, matching: .images)
        .onChange(of: picker.selectedItem) { _, item in
            picker.handleSelection(item) { data in
                withAnimation { model.start(with: .screenshot(imageData: data)) }
            }
        }
        .sheet(isPresented: $isPasteSheetPresented) {
            PasteTextSheet { text in
                withAnimation { model.start(with: .pastedText(text)) }
            }
        }
        .sheet(isPresented: $model.showsPrivacyDisclosure) {
            PrivacyDisclosureView(
                onAcknowledge: { Task { await model.acknowledgePrivacy() } },
                onCancel: { model.declinePrivacy() }
            )
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $isShowingFullScreenshot) {
            FullScreenshotView(image: model.screenshotImage)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.md)

            HStack(spacing: Spacing.lg) {
                InterestRing(title: "You", value: 62)
                InterestRing(title: "Them", value: 81)
            }
            .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Upload a chat to\nget an analysis")
                    .font(Typography.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                Text("See who's more into it, the vibe, and your best next move.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
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
                    ForEach(model.messages) { message in
                        messageView(message)
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)
            }
            .onChange(of: model.messages.count) {
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: model.messages)
    }

    @ViewBuilder
    private func messageView(_ message: AnalyzeViewModel.Message) -> some View {
        let isActive = model.isActive(message)
        switch message.kind {
        case .userScreenshot:
            ScreenshotBubble(image: model.screenshotImage) { isShowingFullScreenshot = true }
        case .userText(let text):
            OutgoingBubble(text: text)
        case .typing:
            TypingBubble()
        case .assistantText(let text):
            IncomingTextBubble(text: text)
        case .interest(let you, let them):
            IncomingBubble {
                HStack {
                    Spacer()
                    InterestRing(title: "You", value: you)
                    Spacer()
                    InterestRing(title: "Them", value: them)
                    Spacer()
                }
                .padding(.vertical, Spacing.xs)
            }
        case .flags(let green, let red):
            IncomingBubble {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if !green.isEmpty {
                        flagBlock(title: "Green flags", tint: Theme.success, flags: green)
                    }
                    if !red.isEmpty {
                        flagBlock(title: "Red flags", tint: Theme.danger, flags: red)
                    }
                }
            }
        case .nextMove(let text):
            CopyableMoveBubble(text: text)
        case .followUp:
            OptionsBubble(title: "Want another read?", isActive: isActive) {
                Button {
                    withAnimation { model.reset() }
                } label: {
                    Label("Analyze Another", systemImage: "plus")
                }
                .buttonStyle(.pill)
            }
        case .error(let text):
            OptionsBubble(title: text, isActive: isActive) {
                Button {
                    Task { await model.retry() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.pill)
            }
        case .upgrade:
            OptionsBubble(
                title: "You've used your free analyses. Plus gives you 150 a month.",
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

    private func flagBlock(title: String, tint: Color, flags: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs + 2) {
            Text(title)
                .font(Typography.caption)
                .kerning(1.1)
                .foregroundStyle(tint)
            ForEach(flags, id: \.self) { flag in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text("•")
                    Text(flag).fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

/// Suggested next message — tap to copy, same as a reply bubble.
private struct CopyableMoveBubble: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            IncomingBubble {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("NEXT MOVE")
                            .font(Typography.caption)
                            .kerning(1.1)
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: Spacing.md)
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Typography.caption)
                            .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                    }
                    Text(text)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suggested next move: \(text)")
        .accessibilityHint(copied ? "Copied" : "Double tap to copy")
        .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
    }

    private func copy() {
        UIPasteboard.general.string = text
        withAnimation(.spring(duration: 0.25)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

/// Full-screen screenshot, same as Chat.
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
    AnalyzeView()
        .environment(AppFlowModel())
        .environment(AnalyzeViewModel.preview)
}
