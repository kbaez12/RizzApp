import SwiftUI

/// Settings — deliberately small. Subscription status/actions, legal links,
/// support, version. Placeholder rows are clearly inert in development.
struct SettingsView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var showsPaywall = false
    @State private var showsNotConnectedAlert = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var statusText: String {
        let status = services.usage.status
        switch status.tier {
        case .plus:
            return "Plus"
        case .free:
            return "Free — \(status.remaining) of \(status.limit) analyses left"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(icon: "sparkles", title: "Subscription", value: statusText)
                    button(icon: "arrow.up.circle", title: "Upgrade to Plus") {
                        showsPaywall = true
                    }
                    button(icon: "arrow.clockwise", title: "Restore Purchases") {
                        showsNotConnectedAlert = true
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    button(icon: "hand.raised", title: "Privacy Policy") {}      // Placeholder URL
                    button(icon: "doc.text", title: "Terms of Use") {}           // Placeholder URL
                    button(icon: "envelope", title: "Contact Support") {}        // Placeholder
                }
                .listRowBackground(Theme.surface)

                Section {
                    row(icon: "info.circle", title: "Version", value: appVersion)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Typography.caption)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
        .alert("Subscriptions aren't connected yet", isPresented: $showsNotConnectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This is a development build. Purchases arrive with RevenueCat in a later phase.")
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func button(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
