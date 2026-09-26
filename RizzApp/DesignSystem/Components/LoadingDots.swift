import SwiftUI

/// Three softly pulsing dots — the app's standard inline loading indicator.
struct LoadingDots: View {
    var color: Color = Theme.accent
    var size: CGFloat = 10
    @State private var animating = false

    var body: some View {
        HStack(spacing: size * 0.8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
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
        .background(GradientBackground())
}
