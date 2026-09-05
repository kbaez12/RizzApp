import SwiftUI

/// Home — minimal and premium. One heading, two actions, settings access.
struct HomeView: View {
    @Environment(AppFlowModel.self) private var flow

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("What'd they say?")
                        .font(Typography.display)
                        .foregroundStyle(Theme.textPrimary)

                    Text("Drop the conversation. Get the reply.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                VStack(spacing: Spacing.md) {
                    Button {
                        flow.startScreenshotFlow()
                    } label: {
                        Label("Upload Screenshot", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.primary)

                    Button {
                        flow.startPasteTextFlow()
                    } label: {
                        Label("Paste Text", systemImage: "text.bubble")
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.bottom, Spacing.lg)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    flow.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Settings")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
