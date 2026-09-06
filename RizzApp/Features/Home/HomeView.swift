import SwiftUI
import PhotosUI

/// Home — minimal and premium. One heading, two actions, settings access.
/// "Upload Screenshot" presents the native PhotosPicker (single image,
/// images only, no library permission needed); navigation to the preview
/// happens only after the image loads and processes successfully.
struct HomeView: View {
    @Environment(AppFlowModel.self) private var flow
    @State private var picker = ScreenshotPickerViewModel()
    @State private var isPickerPresented = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("What'd they say?")
                        .font(Typography.display)
                        .foregroundStyle(Theme.textPrimary)

                    Text("Drop the conversation. Get the reply.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                VStack(spacing: Spacing.md) {
                    Button {
                        isPickerPresented = true
                    } label: {
                        if picker.isLoading {
                            HStack(spacing: Spacing.sm) {
                                LoadingDots()
                                Text("Getting that ready…")
                            }
                        } else {
                            Label("Upload Screenshot", systemImage: "photo.on.rectangle")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(picker.isLoading)

                    Button {
                        flow.startPasteTextFlow()
                    } label: {
                        Label("Paste Text", systemImage: "text.bubble")
                    }
                    .buttonStyle(.secondary)
                    .disabled(picker.isLoading)

                    if let errorMessage = picker.errorMessage {
                        Text(errorMessage)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, Spacing.lg)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .photosPicker(
            isPresented: $isPickerPresented,
            selection: $picker.selectedItem,
            matching: .images
        )
        .onChange(of: picker.selectedItem) { _, item in
            picker.handleSelection(item) { data in
                flow.presentScreenshotPreview(imageData: data)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    flow.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Settings")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppFlowModel())
    .preferredColorScheme(.dark)
}
