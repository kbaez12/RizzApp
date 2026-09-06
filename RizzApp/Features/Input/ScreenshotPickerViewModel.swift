import SwiftUI
import PhotosUI
import Observation

/// Handles PhotosPicker selection → load → process for both the Home flow
/// and the preview's Replace flow.
///
/// This model owns only *transient* state (loading flag, error text, current
/// picker item). The canonical screenshot lives in `AppFlowModel.input` as
/// `ConversationInput.screenshot(imageData:)` — processed `Data` is handed
/// to the caller via the `onSuccess` closure, never stored here. Picking a
/// new image cancels any in-flight load.
@MainActor
@Observable
final class ScreenshotPickerViewModel {
    /// Bound to the PhotosPicker. Cleared after each handled selection so
    /// re-picking the same photo fires `onChange` again.
    var selectedItem: PhotosPickerItem?

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var loadTask: Task<Void, Never>?
    private let processor = ScreenshotProcessor()

    /// Call from `onChange(of: selectedItem)`. Cancelling the picker never
    /// reaches here (item stays nil), so cancel is silent by design.
    func handleSelection(_ item: PhotosPickerItem?, onSuccess: @escaping (Data) -> Void) {
        guard let item else { return }
        loadTask?.cancel()
        loadTask = Task { await load(item, onSuccess: onSuccess) }
    }

    private func load(_ item: PhotosPickerItem, onSuccess: @escaping (Data) -> Void) async {
        isLoading = true
        errorMessage = nil
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                throw ImageInputError.unableToLoad
            }
            try Task.checkCancellation()
            let processed = try await processor.process(rawData)
            try Task.checkCancellation()

            isLoading = false
            selectedItem = nil
            onSuccess(processed)
        } catch is CancellationError {
            // Superseded by a newer selection — that task owns the UI state.
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            selectedItem = nil
            let inputError = (error as? ImageInputError) ?? .unableToLoad
            errorMessage = inputError.displayMessage
        }
    }
}

/// Friendly, non-technical copy — the only place these errors become text.
extension ImageInputError {
    var displayMessage: String {
        switch self {
        case .unableToLoad, .invalidImage:
            "We couldn't read that screenshot. Try another one."
        case .processingFailed:
            "Something went wrong getting that ready. Try again."
        }
    }
}
