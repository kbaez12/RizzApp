import SwiftUI

/// Phase 2 mock of the screenshot flow: shows a sample conversation as the
/// "selected screenshot", with Replace and Continue.
///
/// Phase 3 replaces the sample with a real PhotosPicker selection — only the
/// preview content and the `ConversationInput` payload change; navigation
/// and layout stay as-is.
struct ScreenshotPreviewView: View {
    @Environment(AppFlowModel.self) private var flow
    @State private var sampleIndex = 0

    private var conversation: MockConversation {
        MockConversation.samples[sampleIndex % MockConversation.samples.count]
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                ScrollView {
                    Card(padding: Spacing.lg) {
                        ConversationPreview(conversation: conversation)
                    }
                    .padding(.top, Spacing.md)

                    Text("Sample conversation — photo picker arrives in Phase 3")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, Spacing.sm)
                }
                .scrollIndicators(.hidden)

                VStack(spacing: Spacing.md) {
                    Button("Continue") {
                        // Empty data is a mock stand-in; Phase 3 passes real image data.
                        flow.continueToGoalSelection(with: .screenshot(imageData: Data()))
                    }
                    .buttonStyle(.primary)

                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            sampleIndex += 1
                        }
                    } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.bottom, Spacing.md)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .navigationTitle("Your Screenshot")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: sampleIndex)
    }
}

#Preview {
    NavigationStack {
        ScreenshotPreviewView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
