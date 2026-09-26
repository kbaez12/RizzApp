import SwiftUI

/// Paste or type a conversation. Hands the trimmed text back and closes.
struct PasteTextSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isEditorFocused: Bool

    private static let maxLength = 4000

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.md)
                        .focused($isEditorFocused)

                    if text.isEmpty {
                        Text("them: had fun last night lol\nme: same honestly\nthem: we should do it again 👀")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            .padding(Spacing.md + 5)
                            .allowsHitTesting(false)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                .shadow(color: Theme.shadow, radius: 8, y: 3)
                .frame(maxHeight: 320)

                Text("Start their lines with \"them:\" and yours with \"me:\" if you can.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button("Send") {
                    onSubmit(trimmedText)
                    dismiss()
                }
                .buttonStyle(.primary)
                .disabled(trimmedText.isEmpty)
                .opacity(trimmedText.isEmpty ? 0.4 : 1)
            }
            .padding(Spacing.screenMargin)
            .background(GradientBackground())
            .navigationTitle("Paste the Convo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .onChange(of: text) { _, newValue in
                if newValue.count > Self.maxLength {
                    text = String(newValue.prefix(Self.maxLength))
                }
            }
            .onAppear { isEditorFocused = true }
        }
    }
}
