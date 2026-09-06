import SwiftUI

/// Results: analyzing state → 3 strategy cards → refinement actions,
/// Generate 3 More, and Start Over. Quota logic lives in the ViewModel
/// and `UsageServicing`, never here.
struct ResultsView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(\.services) private var services
    @State private var model: ResultsViewModel?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model?.state == .analyzing)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Start Over") { flow.resetSession() }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .task {
            guard model == nil else { return }
            guard let input = flow.input, let goal = flow.goal else { return }
            let newModel = ResultsViewModel(
                input: input,
                goal: goal,
                generation: services.generation,
                usage: services.usage,
                onQuotaExhausted: { flow.isShowingPaywall = true }
            )
            model = newModel
            await newModel.generate()
        }
    }

    @ViewBuilder
    private var content: some View {
        if flow.input == nil || flow.goal == nil {
            // Defensive: session state missing (e.g. unreadable screenshot).
            errorState(message: "We couldn't read that conversation.", retryLabel: "Start Over") {
                flow.resetSession()
            }
        } else if let model {
            switch model.state {
            case .analyzing:
                AnalyzingView()
            case .failed:
                errorState(message: model.failureMessage, retryLabel: "Try Again") {
                    // Same logical request — reuses the idempotency key.
                    Task { await model.generate(isRetry: true) }
                }
            case .loaded:
                loadedContent(model)
            }
        } else {
            AnalyzingView()
        }
    }

    private func loadedContent(_ model: ResultsViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(model.responses) { response in
                    ResultCard(response: response)
                }

                if let error = model.inlineError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Spacing.xs)
                }

                refinementBar(model)
                    .padding(.top, Spacing.sm)

                Button("Generate 3 More") {
                    Task { await model.generate() }
                }
                .buttonStyle(.secondary)
                .disabled(model.isRefining)
                .padding(.top, Spacing.sm)

                Text(usageFootnote(model))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.vertical, Spacing.md)
        }
        .scrollIndicators(.hidden)
        .opacity(model.isRefining ? 0.5 : 1)
        .overlay {
            if model.isRefining {
                LoadingDots()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isRefining)
    }

    private func refinementBar(_ model: ResultsViewModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.sm) {
                ForEach(RefinementAction.allCases) { action in
                    Button(action.label) {
                        Task { await model.refine(action) }
                    }
                    .buttonStyle(.pill)
                    .disabled(model.isRefining)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func usageFootnote(_ model: ResultsViewModel) -> String {
        let remaining = model.remainingAnalyses
        return remaining == 1 ? "1 free analysis left" : "\(remaining) free analyses left"
    }

    private func errorState(
        message: String,
        retryLabel: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(Typography.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Button(retryLabel, action: retry)
                .buttonStyle(.secondary)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, Spacing.screenMargin)
    }
}

#Preview {
    NavigationStack {
        ResultsView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
