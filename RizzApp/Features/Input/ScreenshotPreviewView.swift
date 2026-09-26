import SwiftUI
import PhotosUI

/// Shows the user's actual selected screenshot with Replace and Continue.
/// The canonical image lives in `AppFlowModel.input`; this view only derives
/// a `UIImage` for display. Replace reopens PhotosPicker in place — the
/// current screenshot is kept until a new one successfully processes.
struct ScreenshotPreviewView: View {
    @Environment(AppFlowModel.self) private var flow
    @State private var picker = ScreenshotPickerViewModel()
    @State private var isPickerPresented = false
    @State private var previewImage: UIImage?

    private var screenshotData: Data? {
        if case .screenshot(let imageData) = flow.input {
            return imageData
        }
        return nil
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let previewImage {
                screenshotContent(previewImage)
            } else {
                missingScreenshotState
            }
        }
        .navigationTitle("Your Screenshot")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(
            isPresented: $isPickerPresented,
            selection: $picker.selectedItem,
            matching: .images
        )
        .onChange(of: picker.selectedItem) { _, item in
            picker.handleSelection(item) { data in
                flow.replaceScreenshot(imageData: data)
            }
        }
        .task(id: screenshotData) {
            previewImage = screenshotData.flatMap(UIImage.init(data:))
        }
    }

    private func screenshotContent(_ image: UIImage) -> some View {
        VStack(spacing: Spacing.lg) {
            ScrollView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    )
                    .padding(.top, Spacing.md)
                    .accessibilityLabel("Selected conversation screenshot")
            }
            .scrollIndicators(.hidden)

            VStack(spacing: Spacing.md) {
                if let errorMessage = picker.errorMessage {
                    Text(errorMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                }

                Button("Continue") {
                    guard let screenshotData else { return }
                    flow.continueToGoalSelection(with: .screenshot(imageData: screenshotData))
                }
                .buttonStyle(.primary)
                .disabled(picker.isLoading)

                Button {
                    isPickerPresented = true
                } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.secondary)
                .disabled(picker.isLoading)
            }
            .padding(.bottom, Spacing.md)
        }
        .padding(.horizontal, Spacing.screenMargin)
        .overlay {
            if picker.isLoading {
                loadingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: picker.isLoading)
    }

    private var loadingOverlay: some View {
        ZStack {
            Theme.background.opacity(0.75).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                LoadingDots()
                Text("Getting that ready…")
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Defensive state — reachable only if session state was lost.
    private var missingScreenshotState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("We couldn't read that screenshot. Try another one.")
                .font(Typography.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Button("Choose a Screenshot") {
                isPickerPresented = true
            }
            .buttonStyle(.secondary)
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, Spacing.screenMargin)
    }
}

#Preview {
    let flow = AppFlowModel()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let sampleImage = UIGraphicsImageRenderer(
        size: CGSize(width: 390, height: 700), format: format
    ).image { context in
        UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 390, height: 700))
    }
    flow.presentScreenshotPreview(imageData: sampleImage.pngData() ?? Data())

    NavigationStack {
        ScreenshotPreviewView()
    }
    .environment(flow)
    .preferredColorScheme(.dark)
}
