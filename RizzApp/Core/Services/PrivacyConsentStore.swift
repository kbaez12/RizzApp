import Foundation

/// First-use AI privacy disclosure. Shown once, before the first real
/// generation. Stored as a boolean in UserDefaults — this is a consent
/// flag, not conversation content, and is the only exception to the
/// "do not persist conversation data" rule.
///
/// The copy is intentionally accurate: we send the selected conversation
/// to a third-party AI provider to generate replies, and we do not
/// permanently store it as part of the generation flow. We do NOT claim
/// "nothing leaves your phone" or "OpenAI stores nothing."
final class PrivacyConsentStore {
    private static let key = "rizzapp.hasAcknowledgedAIPrivacy"

    var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: Self.key)
    }

    func acknowledge() {
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    /// Test/dev helper. Not exposed in the UI.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Environment-injected so views/tests can swap it.
private struct PrivacyConsentStoreKey: EnvironmentKey {
    static let defaultValue = PrivacyConsentStore()
}

import SwiftUI

extension EnvironmentValues {
    var privacyConsent: PrivacyConsentStore {
        get { self[PrivacyConsentStoreKey.self] }
        set { self[PrivacyConsentStoreKey.self] = newValue }
    }
}
