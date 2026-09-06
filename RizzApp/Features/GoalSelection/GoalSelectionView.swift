import SwiftUI

/// "What's the move?" — single-select goal grid. Continue is disabled until
/// a goal is chosen. If the user is out of full analyses, attempting to
/// continue presents the paywall instead of navigating (backend will
/// re-enforce this in later phases).
struct GoalSelectionView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(\.services) private var services
    @State private var selectedGoal: ResponseGoal?

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.md),
        GridItem(.flexible(), spacing: Spacing.md),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("What's the move?")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, Spacing.md)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(ResponseGoal.allCases) { goal in
                            SelectableChip(
                                label: goal.label,
                                systemImage: goal.systemImage,
                                isSelected: selectedGoal == goal
                            ) {
                                selectedGoal = goal
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Button("Continue") {
                    guard let selectedGoal else { return }
                    if services.usage.canStartFullGeneration() {
                        flow.continueToResults(goal: selectedGoal)
                    } else {
                        flow.isShowingPaywall = true
                    }
                }
                .buttonStyle(.primary)
                .disabled(selectedGoal == nil)
                .opacity(selectedGoal == nil ? 0.4 : 1)
                .padding(.bottom, Spacing.md)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selectedGoal)
    }
}

#Preview {
    NavigationStack {
        GoalSelectionView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
