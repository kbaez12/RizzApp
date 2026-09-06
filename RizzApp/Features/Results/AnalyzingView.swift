import SwiftUI

/// The AI-analysis loading experience: pulsing dots plus rotating status
/// copy. Advances through the phrases and holds on the last one.
struct AnalyzingView: View {
    private static let phrases = [
        "Reading the room…",
        "Catching the vibe…",
        "Finding your angle…",
        "Making it sound like you…",
        "Almost there…",
    ]

    @State private var phraseIndex = 0

    var body: some View {
        VStack(spacing: Spacing.lg) {
            LoadingDots()

            Text(Self.phrases[phraseIndex])
                .font(Typography.headline)
                .foregroundStyle(Theme.textSecondary)
                .id(phraseIndex)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while phraseIndex < Self.phrases.count - 1 {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    phraseIndex += 1
                }
            }
        }
    }
}

#Preview {
    AnalyzingView()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
