import Foundation

/// Legal/support destinations.
///
/// ⚠️ ALL THREE URLs ARE PLACEHOLDERS and must be replaced with real hosted
/// pages before App Store submission (App Review rejects unreachable
/// privacy/terms links, and the privacy policy URL is required in App Store
/// Connect). Support can be a mailto: or a web page.
enum LegalLinks {
    static let privacy = URL(string: "https://rizzapp.example.com/privacy")!
    static let terms = URL(string: "https://rizzapp.example.com/terms")!
    static let support = URL(string: "mailto:support@rizzapp.example.com")!

    /// True while the values above are still the examples — surfaces a
    /// visible dev warning in Settings so we cannot ship them by accident.
    static var arePlaceholders: Bool {
        privacy.absoluteString.contains("example.com")
    }
}
