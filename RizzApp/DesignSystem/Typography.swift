import SwiftUI

/// Typography tokens. Headings use the rounded design for a warm feel; body
/// text stays on the default design for readability. All sizes are Dynamic
/// Type–relative so they scale with the user's settings.
enum Typography {
    /// App wordmark in the header.
    static let wordmark = Font.system(.title, design: .rounded).weight(.black).italic()
    /// Hero heading on empty states.
    static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
    /// Screen titles.
    static let title = Font.system(.title, design: .rounded).weight(.bold)
    /// Section headers and card labels.
    static let headline = Font.system(.headline, design: .rounded)
    /// Primary reading text (bubbles, descriptions).
    static let body = Font.system(.body)
    /// Secondary information under titles.
    static let subheadline = Font.system(.subheadline)
    /// Small labels — strategy tags, footers, usage counters.
    static let caption = Font.system(.caption).weight(.medium)
    /// Button labels.
    static let button = Font.system(.headline, design: .rounded)
}
