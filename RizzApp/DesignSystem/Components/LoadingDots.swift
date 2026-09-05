import SwiftUI

/// Three softly pulsing dots — the app's standard inline loading indicator.
struct LoadingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 10, height: 10)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityLabel("Loading")
    }
}

#Preview {
    LoadingDots()
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
