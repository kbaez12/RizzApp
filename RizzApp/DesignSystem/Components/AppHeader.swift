import SwiftUI

enum AppBrand {
    static let displayName = "RizzApp"
    static let wordmark = "RIZZAPP"
}

/// Top bar shared by all tabs: menu (three lines) on the left, wordmark in
/// the middle, optional action on the right.
struct AppHeader: View {
    let onMenu: () -> Void
    var trailingSystemImage: String?
    var trailingLabel: String = ""
    var onTrailing: (() -> Void)?

    var body: some View {
        HStack {
            iconButton("line.3.horizontal", label: "Menu", action: onMenu)

            Spacer()

            Text(AppBrand.wordmark)
                .font(Typography.wordmark)
                .foregroundStyle(Theme.brandGradient)
                .shadow(color: Theme.ink, radius: 0, x: 2, y: 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(AppBrand.displayName)

            Spacer()

            if let trailingSystemImage, let onTrailing {
                iconButton(trailingSystemImage, label: trailingLabel, action: onTrailing)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.xs)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

#Preview {
    AppHeader(onMenu: {}, trailingSystemImage: "plus", trailingLabel: "New chat", onTrailing: {})
        .background(GradientBackground())
}
