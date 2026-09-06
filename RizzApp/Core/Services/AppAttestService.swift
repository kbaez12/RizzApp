import Foundation

/// App Attest is structured but not required for TestFlight.
///
/// Why this is a scaffold, not a full implementation:
/// - Apple App Attest needs an App ID capability, a generated key, a
///   server-side assertion verification against Apple's servers, and a
///   challenge/response handshake. That is a real security project, not
///   an afternoon.
/// - TestFlight testers on the same team do not need this. It becomes
///   important before *broad public* scaling, once the OpenAI bill is
///   exposed to anyone who extracted the publishable key.
///
/// What is in place today:
/// - `X-Installation-ID` identifies the install (not authentication).
/// - Publishable-key validation on every function.
/// - Atomic server-side quota.
/// - Per-install rate limiting (12/min).
/// - Request-size and input validation.
///
/// What to finish before public scale (see LAUNCH.md):
/// 1. Enable App Attest capability in the Apple Developer portal.
/// 2. Generate a key + attestation on first launch; persist the key ID
///    in the Keychain (this file's eventual job).
/// 3. Have the backend issue a one-time challenge and verify the
///    assertion with Apple's App Attest API (or a library such as
///    `AppAttest` on the server) before calling OpenAI.
/// 4. Fail closed on production; fail open in DEBUG so local development
///    still works on the simulator (App Attest is device-only).
///
/// The header name is reserved so a later implementation can drop in
/// without a client API redesign.
enum AppAttestHeaders {
    static let assertion = "X-App-Attest-Assertion"
    static let keyID = "X-App-Attest-Key-ID"
}

/// No-op provider used today. A future `DeviceAppAttestService` can
/// replace this at the `AppServices` wiring point.
protocol AppAttestProviding: AnyObject {
    /// Extra headers to attach to a generate request. Empty until App
    /// Attest is actually implemented.
    func assertionHeaders() async -> [String: String]
}

final class DisabledAppAttestService: AppAttestProviding {
    func assertionHeaders() async -> [String: String] { [:] }
}
