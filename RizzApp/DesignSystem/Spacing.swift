import SwiftUI

/// Spacing scale. Use these instead of magic numbers in layout code.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// Default horizontal screen margin.
    static let screenMargin: CGFloat = 24
}

/// Corner radius scale.
enum Radius {
    static let chip: CGFloat = 14
    static let button: CGFloat = 18
    static let card: CGFloat = 22
}
