import Foundation

/// Which service implementations the app wires up. Views never read this —
/// selection happens once in `AppServices.current` (see AppServices.swift).
enum ServiceMode {
    case mock
    case liveDevelopment
}

/// Central app configuration. Live development is deliberately opt-in:
/// both `GREENSHOT_SERVICE_MODE=liveDevelopment` and
/// `SUPABASE_ENVIRONMENT=development` must be supplied through the Debug
/// scheme environment or generated Info.plist build settings.
enum AppConfig {
    static var serviceMode: ServiceMode {
        #if DEBUG
        guard configurationValue("GREENSHOT_SERVICE_MODE") == "liveDevelopment",
              configurationValue("SUPABASE_ENVIRONMENT") == "development",
              developmentAPI != nil else {
            return .mock
        }
        return .liveDevelopment
        #else
        return .mock
        #endif
    }

    /// Returns nil for missing, placeholder, non-development, or malformed
    /// settings. AppServices then keeps the existing offline mock behavior.
    static var developmentAPI: APIConfig? {
        #if DEBUG
        guard configurationValue("SUPABASE_ENVIRONMENT") == "development",
              let urlString = configurationValue("SUPABASE_DEV_URL"),
              let key = configurationValue("SUPABASE_DEV_PUBLISHABLE_KEY"),
              let url = URL(string: urlString) else {
            return nil
        }
        return APIConfig.development(
            baseURL: url,
            publishableKey: key,
            hostedProjectRef: configurationValue("SUPABASE_DEV_PROJECT_REF"),
            allowHosted: configurationValue("GREENSHOT_ALLOW_HOSTED_DEV") == "true"
        )
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Development-only backend error simulation. When set (e.g. "quota",
    /// "unauthorized", "rate_limit", "server_error", "invalid_request",
    /// "malformed"), APIClient sends it as an `x-debug-scenario` header.
    /// The server honors it ONLY when its DEV_ERROR_SIMULATION env var is
    /// "true" (never set in production). Remove this mechanism before ship.
    static var debugErrorScenario: String?
    #endif

    private static func configurationValue(_ name: String) -> String? {
        let environmentValue = ProcessInfo.processInfo.environment[name]
        let raw = environmentValue ?? Bundle.main.object(forInfoDictionaryKey: name) as? String
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$("),
              !value.localizedCaseInsensitiveContains("placeholder"),
              !value.localizedCaseInsensitiveContains("paste_") else {
            return nil
        }
        return value
    }
}

/// Supabase connection details.
///
/// SECURITY NOTES:
/// - The publishable key is a CLIENT-SAFE project identifier. It is fine to
///   ship in the app, but it is NOT app/device authentication — anyone can
///   extract it. App Attest / DeviceCheck + server-side rate limiting will
///   protect expensive endpoints later (Phase 8).
/// - Secret keys (Supabase service-role, OpenAI, RevenueCat secret) must
///   NEVER appear anywhere in this client.
struct APIConfig {
    let baseURL: URL
    let publishableKey: String
    /// RevenueCat **public** SDK key (safe in the client). The RevenueCat
    /// secret key must never appear here — it belongs only in RevenueCat's
    /// dashboard/webhook configuration.
    var revenueCatPublicKey: String = "appl_PASTE_REVENUECAT_PUBLIC_SDK_KEY"

    /// Accepts only loopback Supabase or HTTPS hosted Supabase targets.
    /// Combined with AppConfig's explicit development marker, this prevents
    /// a normal Debug launch from silently making live requests.
    static func development(
        baseURL: URL,
        publishableKey: String,
        hostedProjectRef: String? = nil,
        allowHosted: Bool = false
    ) -> APIConfig? {
        let host = baseURL.host?.lowercased()
        let isLoopback = baseURL.scheme == "http"
            && (host == "127.0.0.1" || host == "localhost")
        let expectedHostedHost = hostedProjectRef.map { "\($0.lowercased()).supabase.co" }
        let isHostedSupabase = allowHosted
            && baseURL.scheme == "https"
            && expectedHostedHost != nil
            && host == expectedHostedHost
        guard (isLoopback || isHostedSupabase),
              !publishableKey.isEmpty,
              publishableKey.hasPrefix("sb_publishable_") || isLoopback else {
            return nil
        }
        return APIConfig(baseURL: baseURL, publishableKey: publishableKey)
    }
}
