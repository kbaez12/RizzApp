import SwiftUI

/// Selectable chip used for goal selection. Fills with muted accent when selected.
struct SelectableChip: View {
    let label: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(label)
                    .font(Typography.headline)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(
                isSelected ? Theme.accentMuted : Theme.surface,
                in: RoundedRectangle(cornerRadius: Radius.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: isSelected)
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        SelectableChip(label: "Flirty", systemImage: "flame", isSelected: true) {}
        SelectableChip(label: "Playful", systemImage: "face.smiling", isSelected: false) {}
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
