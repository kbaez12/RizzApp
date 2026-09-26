import SwiftUI

/// Light pastel palette. All colors are referenced through these tokens —
/// never use raw `Color` literals in feature views.
enum Theme {
    // MARK: Backgrounds
    /// Flat fallback behind the gradient (sheets, lists).
    static let background = Color(hex: 0xF3F0F7)
    /// Soft mint → lilac → pink wash used behind every tab.
    static let backgroundGradient = LinearGradient(
        colors: [Color(hex: 0xCFE8E5), Color(hex: 0xE4DEF3), Color(hex: 0xF3DCE6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// Cards, incoming bubbles.
    static let surface = Color.white
    /// Subtle fills inside cards (inputs, unselected states).
    static let surfaceElevated = Color(hex: 0xF2EFF7)
    /// Near-black used for primary buttons and the tab bar.
    static let ink = Color(hex: 0x111114)

    // MARK: Accent
    static let accent = Color(hex: 0x8B6CF0)
    static let accentMuted = Color(hex: 0x8B6CF0).opacity(0.14)
    /// Pink → lavender, used for the wordmark, outgoing bubbles, and
    /// primary button labels.
    static let brandPink = Color(hex: 0xF6B3CF)
    static let brandLavender = Color(hex: 0xB7B4FF)
    static let brandGradient = LinearGradient(
        colors: [brandPink, brandLavender],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Text
    static let textPrimary = Color(hex: 0x111114)
    static let textSecondary = Color(hex: 0x6C6878)
    static let textOnAccent = Color.white

    // MARK: Lines & feedback
    static let stroke = Color(hex: 0xE3DFEA)
    static let success = Color(hex: 0x2E9E66)
    static let danger = Color(hex: 0xD6456A)
    static let shadow = Color.black.opacity(0.07)
}

/// Full-bleed pastel background.
struct GradientBackground: View {
    var body: some View {
        Theme.backgroundGradient.ignoresSafeArea()
    }
}

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `Color(hex: 0xFF5A76)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
