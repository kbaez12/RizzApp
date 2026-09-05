import SwiftUI

/// Full-width filled accent button for the single primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(Theme.textOnAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Radius.button))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Full-width outlined button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.button))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Compact pill button for inline actions (e.g. refinement actions on Results).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 2)
            .background(Theme.surfaceElevated, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}
