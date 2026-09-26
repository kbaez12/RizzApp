import SwiftUI
import UIKit

/// Right-aligned bubble for what the user sent or chose.
struct OutgoingBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.body.weight(.medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 4)
            .background(Theme.brandGradient, in: BubbleShape(isIncoming: false))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Spacing.xxl)
    }
}

/// Left-aligned white bubble from the app. Holds text, chips, or both.
struct IncomingBubble<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 4)
            .background(Theme.surface, in: BubbleShape(isIncoming: true))
            .shadow(color: Theme.shadow, radius: 6, y: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, Spacing.xl)
    }
}

/// Incoming bubble with plain text.
struct IncomingTextBubble: View {
    let text: String

    var body: some View {
        IncomingBubble {
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One generated reply. Tapping copies it — nothing is stored.
struct ReplyBubble: View {
    let response: GeneratedResponse
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            IncomingBubble {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text(response.label.uppercased())
                            .font(Typography.caption)
                            .kerning(1.1)
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: Spacing.md)
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Typography.caption)
                            .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                    }
                    Text(response.text)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(response.label): \(response.text)")
        .accessibilityHint(copied ? "Copied" : "Double tap to copy")
        .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
    }

    private func copy() {
        UIPasteboard.general.string = response.text
        withAnimation(.spring(duration: 0.25)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

/// "Typing…" bubble shown while the AI works.
struct TypingBubble: View {
    private static let phrases = [
        "Reading the vibe…",
        "Checking your texting style…",
        "Writing a few options…",
    ]
    @State private var phraseIndex = 0

    var body: some View {
        IncomingBubble {
            HStack(spacing: Spacing.md) {
                LoadingDots(color: Theme.textSecondary, size: 7)
                Text(Self.phrases[phraseIndex])
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.opacity)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation { phraseIndex = (phraseIndex + 1) % Self.phrases.count }
            }
        }
        .accessibilityLabel("Writing replies")
    }
}

/// Screenshot the user sent, shown as a right-aligned thumbnail.
struct ScreenshotBubble: View {
    let image: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.surfaceElevated
                        .overlay(Image(systemName: "photo").foregroundStyle(Theme.textSecondary))
                }
            }
            .frame(width: 150, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.white, lineWidth: 3))
            .shadow(color: Theme.shadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("Your screenshot")
        .accessibilityHint("Double tap to view full screen")
    }
}

/// Incoming bubble with an optional line of text and wrapping chips.
/// Chips dim once the conversation has moved past them.
struct OptionsBubble<Chips: View>: View {
    var title: String?
    var isActive: Bool = true
    @ViewBuilder var chips: Chips

    var body: some View {
        IncomingBubble {
            VStack(alignment: .leading, spacing: Spacing.sm + 2) {
                if let title {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout {
                    chips
                }
                .disabled(!isActive)
                .opacity(isActive ? 1 : 0.45)
            }
        }
    }
}

/// iMessage-style bubble: rounded everywhere except a tighter corner on the
/// sender's side at the bottom.
struct BubbleShape: Shape {
    let isIncoming: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 20
        let small: CGFloat = 6
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: isIncoming ? small : big,
            bottomTrailingRadius: isIncoming ? big : small,
            topTrailingRadius: big
        )
        .path(in: rect)
    }
}
