import SwiftUI

/// Dark-first color palette. All colors are referenced through these tokens —
/// never use raw `Color` literals in feature views.
enum Theme {
    // MARK: Backgrounds
    /// App background — near-black with a hint of warmth.
    static let background = Color(hex: 0x0C0C10)
    /// Cards and grouped surfaces.
    static let surface = Color(hex: 0x17171D)
    /// Elevated surfaces (sheets, popovers, selected states' base).
    static let surfaceElevated = Color(hex: 0x202028)

    // MARK: Accent
    /// Primary brand accent — warm rose, used sparingly for primary actions.
    static let accent = Color(hex: 0xFF5A76)
    /// Muted accent for selected chip fills and highlights.
    static let accentMuted = Color(hex: 0xFF5A76).opacity(0.16)

    // MARK: Text
    static let textPrimary = Color(hex: 0xF5F4F7)
    static let textSecondary = Color(hex: 0x9A99A6)
    static let textOnAccent = Color(hex: 0xFFFFFF)

    // MARK: Lines & feedback
    /// Hairline strokes around cards and secondary buttons.
    static let stroke = Color(hex: 0x2B2B35)
    static let success = Color(hex: 0x4CD964)
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
