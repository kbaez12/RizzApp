import SwiftUI

/// Typography tokens. Headings use the rounded design for a warm, premium feel;
/// body text stays on the default design for readability.
enum Typography {
    /// Hero heading on Home ("What'd they say?").
    static let display = Font.system(size: 38, weight: .bold, design: .rounded)
    /// Screen titles ("What's the move?").
    static let title = Font.system(size: 28, weight: .bold, design: .rounded)
    /// Section headers and card labels.
    static let headline = Font.system(size: 19, weight: .semibold, design: .rounded)
    /// Primary reading text (generated responses, descriptions).
    static let body = Font.system(size: 17, weight: .regular)
    /// Secondary information under titles.
    static let subheadline = Font.system(size: 15, weight: .regular)
    /// Small labels — strategy tags, footers, usage counters.
    static let caption = Font.system(size: 13, weight: .medium)
    /// Button labels.
    static let button = Font.system(size: 17, weight: .semibold, design: .rounded)
}
