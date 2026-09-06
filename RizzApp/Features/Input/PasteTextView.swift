import SwiftUI

/// Paste-a-conversation input. Minimal, consumer feel — an editor, a hint,
/// and Continue. No form chrome.
struct PasteTextView: View {
    @Environment(AppFlowModel.self) private var flow
    @State private var text = ""
    @FocusState private var isEditorFocused: Bool

    private static let maxLength = 4000

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.md)
                        .focused($isEditorFocused)

                    if text.isEmpty {
                        Text("them: had fun last night lol\nyou: same honestly\nthem: we should do it again 👀")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                            .padding(Spacing.md + 5)
                            .allowsHitTesting(false)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card)
                        .strokeBorder(
                            isEditorFocused ? Theme.accent.opacity(0.5) : Theme.stroke,
                            lineWidth: 1
                        )
                )
                .frame(maxHeight: 320)
                .padding(.top, Spacing.md)

                Spacer()

                Button("Continue") {
                    flow.continueToGoalSelection(with: .pastedText(trimmedText))
                }
                .buttonStyle(.primary)
                .disabled(trimmedText.isEmpty)
                .opacity(trimmedText.isEmpty ? 0.4 : 1)
                .padding(.bottom, Spacing.md)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .navigationTitle("Paste the Convo")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: text) { _, newValue in
            if newValue.count > Self.maxLength {
                text = String(newValue.prefix(Self.maxLength))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditorFocused = false }
                    .font(Typography.caption)
            }
        }
        .onAppear { isEditorFocused = true }
    }
}

#Preview {
    NavigationStack {
        PasteTextView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
