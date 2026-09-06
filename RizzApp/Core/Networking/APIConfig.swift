import Foundation

/// Which service implementations the app wires up. Views never read this —
/// selection happens once in `AppServices.current` (see AppServices.swift).
enum ServiceMode {
    case mock
    case liveDevelopment
}

/// Central app configuration. The single place to flip mock/live and point
/// at a Supabase environment.
enum AppConfig {
    /// THE switch. `.mock` = fully offline UI development.
    /// `.liveDevelopment` = real HTTP against the Supabase functions below.
    static let serviceMode: ServiceMode = .mock

    /// Active API target when in `.liveDevelopment`.
    static let api = APIConfig.localDevelopment

    #if DEBUG
    /// Development-only backend error simulation. When set (e.g. "quota",
    /// "unauthorized", "rate_limit", "server_error", "invalid_request",
    /// "malformed"), APIClient sends it as an `x-debug-scenario` header.
    /// The server honors it ONLY when its DEV_ERROR_SIMULATION env var is
    /// "true" (never set in production). Remove this mechanism before ship.
    static var debugErrorScenario: String?
    #endif
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

    /// Local Supabase stack via CLI (`supabase start` + `functions serve`).
    /// Loopback traffic is exempt from ATS, so plain http works here —
    /// but only from the iOS *simulator* on the same machine.
    static let localDevelopment = APIConfig(
        baseURL: URL(string: "http://127.0.0.1:54321")!,
        publishableKey: "PASTE_LOCAL_PUBLISHABLE_KEY_HERE"
    )

    /// Hosted dev project — fill in after `supabase link` + deploy.
    static let remoteDevelopment = APIConfig(
        baseURL: URL(string: "https://YOUR-PROJECT-REF.supabase.co")!,
        publishableKey: "sb_publishable_PLACEHOLDER"
    )
}
