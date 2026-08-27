import XCTest
import CoreImage
import CoreGraphics
@testable import Sealshot

final class BarcodeRecognizerTests: XCTestCase {

    func test_openableURL_classifiesSchemes() {
        XCTAssertNotNil(BarcodeRecognizer.openableURL(for: "https://seal-shot.com"))
        XCTAssertNotNil(BarcodeRecognizer.openableURL(for: "http://x.com"))
        XCTAssertNotNil(BarcodeRecognizer.openableURL(for: "mailto:a@b.com"))
        XCTAssertNotNil(BarcodeRecognizer.openableURL(for: "tel:+15551234"))
        XCTAssertEqual(BarcodeRecognizer.openableURL(for: "www.example.com")?.absoluteString,
                       "https://www.example.com")
        XCTAssertNil(BarcodeRecognizer.openableURL(for: "just some text"))
        XCTAssertNil(BarcodeRecognizer.openableURL(for: ""))
    }

    func test_detectsGeneratedQR() async throws {
        let payload = "https://seal-shot.com"
        let img = try Self.makeQRImage(payload)
        let codes = await BarcodeRecognizer().recognize(img)
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes.first?.payload, payload)
        XCTAssertNotNil(codes.first?.openableURL)
        let box = try XCTUnwrap(codes.first?.box)
        XCTAssertTrue(box.minX >= 0 && box.maxX <= 1 && box.minY >= 0 && box.maxY <= 1,
                      "box should be normalized within [0,1]: \(box)")
    }

    /// Generate a QR on a white background with a quiet zone so Vision detects it.
    static func makeQRImage(_ payload: String, scale: CGFloat = 10) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(payload.data(using: .ascii), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qr = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quiet: CGFloat = 40
        let shifted = qr.transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
        let canvas = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0,
                                width: shifted.extent.maxX + quiet,
                                height: shifted.extent.maxY + quiet))
        let composited = shifted.composited(over: canvas)
        let ctx = CIContext()
        return try XCTUnwrap(ctx.createCGImage(composited, from: composited.extent))
    }
}
