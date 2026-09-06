import XCTest
import UIKit
@testable import RizzApp

/// Image pipeline tests. Deliberately not pixel-perfect — they verify
/// dimension constraints, decodability, and error behavior.
final class ScreenshotProcessorTests: XCTestCase {
    private let processor = ScreenshotProcessor()

    private func makeImageData(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            // Simple two-tone content so JPEG encoding has something to do.
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        return image.pngData()!
    }

    private func pixelSize(of data: Data) throws -> CGSize {
        let image = try XCTUnwrap(UIImage(data: data))
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }

    func testLargeImageIsDownscaledToMaxDimension() async throws {
        let input = makeImageData(width: 4096, height: 1000)
        let output = try await processor.process(input)

        let size = try pixelSize(of: output)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 2048)
        // Aspect ratio roughly preserved (4096:1000 ≈ 4.1).
        XCTAssertEqual(size.width / size.height, 4096 / 1000, accuracy: 0.1)
    }

    func testTallScreenshotRespectsMaxDimension() async throws {
        let input = makeImageData(width: 1179, height: 5000)
        let output = try await processor.process(input)

        let size = try pixelSize(of: output)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 2048)
    }

    func testSmallImagePassesThroughWithoutUpscaling() async throws {
        let input = makeImageData(width: 300, height: 200)
        let output = try await processor.process(input)

        let size = try pixelSize(of: output)
        XCTAssertEqual(size.width, 300, accuracy: 2)
        XCTAssertEqual(size.height, 200, accuracy: 2)
    }

    func testOutputIsDecodableJPEG() async throws {
        let input = makeImageData(width: 1200, height: 2400)
        let output = try await processor.process(input)

        XCTAssertFalse(output.isEmpty)
        XCTAssertNotNil(UIImage(data: output))
        // JPEG magic bytes: FF D8.
        XCTAssertEqual([UInt8](output.prefix(2)), [0xFF, 0xD8])
    }

    func testInvalidDataThrowsInvalidImage() async {
        let garbage = Data("definitely not an image".utf8)
        do {
            _ = try await processor.process(garbage)
            XCTFail("Expected invalidImage error")
        } catch {
            XCTAssertEqual(error as? ImageInputError, .invalidImage)
        }
    }

    func testEmptyDataThrowsInvalidImage() async {
        do {
            _ = try await processor.process(Data())
            XCTFail("Expected invalidImage error")
        } catch {
            XCTAssertEqual(error as? ImageInputError, .invalidImage)
        }
    }

    func testTinyImageRejected() async {
        let input = makeImageData(width: 10, height: 10)
        do {
            _ = try await processor.process(input)
            XCTFail("Expected invalidImage error for sub-minimum dimensions")
        } catch {
            XCTAssertEqual(error as? ImageInputError, .invalidImage)
        }
    }
}
