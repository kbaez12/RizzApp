import UIKit

/// Errors from loading/processing a selected screenshot. Friendly display
/// text is mapped at the UI boundary (see `ScreenshotPickerViewModel`).
enum ImageInputError: Error, Equatable {
    case unableToLoad
    case invalidImage
    case processingFailed
}

/// Prepares a user-selected screenshot for upload, entirely in memory.
///
/// Strategy (bounded and predictable — no uncontrolled recompression loops):
/// 1. Decode and validate (reject undecodable data or images smaller than
///    32px on either side).
/// 2. Downscale so the longest side is at most 2048px. Screenshots are
///    text-heavy, so we favor resolution over aggressive size reduction —
///    a 3x iPhone screenshot (e.g. 1179×2556) becomes ~944×2048, which
///    keeps message text readable for a vision model.
/// 3. Re-render via UIGraphicsImageRenderer. This also normalizes EXIF
///    orientation and strips all metadata (location, capture info) —
///    a privacy win before anything leaves the device.
/// 4. Encode JPEG at quality 0.7. If the result exceeds ~1 MB, make exactly
///    one retry at quality 0.5 and keep the smaller output. We accept
///    slightly-over-target files rather than degrade text legibility.
///
/// The declared-async method runs off the main actor (non-isolated async),
/// so processing never blocks the UI. Output `Data` is what we'll later
/// send to the backend. Nothing is ever written to disk.
struct ScreenshotProcessor {
    var maxPixelDimension: CGFloat = 2048
    var minPixelDimension: CGFloat = 32
    var baseQuality: CGFloat = 0.7
    var retryQuality: CGFloat = 0.5
    var targetByteCount: Int = 1_000_000

    func process(_ rawData: Data) async throws -> Data {
        guard !rawData.isEmpty, let image = UIImage(data: rawData) else {
            throw ImageInputError.invalidImage
        }
        try Task.checkCancellation()

        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard pixelSize.width >= minPixelDimension, pixelSize.height >= minPixelDimension else {
            throw ImageInputError.invalidImage
        }

        let scaleFactor = min(1, maxPixelDimension / max(pixelSize.width, pixelSize.height))
        let targetSize = CGSize(
            width: max(1, (pixelSize.width * scaleFactor).rounded(.down)),
            height: max(1, (pixelSize.height * scaleFactor).rounded(.down))
        )

        let normalized = render(image, at: targetSize)
        try Task.checkCancellation()

        guard let jpeg = normalized.jpegData(compressionQuality: baseQuality), !jpeg.isEmpty else {
            throw ImageInputError.processingFailed
        }
        if jpeg.count <= targetByteCount {
            return jpeg
        }

        // Single bounded retry at lower quality; keep whichever is smaller.
        try Task.checkCancellation()
        guard let smaller = normalized.jpegData(compressionQuality: retryQuality), !smaller.isEmpty else {
            return jpeg
        }
        return smaller.count < jpeg.count ? smaller : jpeg
    }

    /// Redraws at the target pixel size (scale 1). Normalizes orientation
    /// and drops metadata as a side effect of re-rendering.
    private func render(_ image: UIImage, at size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
