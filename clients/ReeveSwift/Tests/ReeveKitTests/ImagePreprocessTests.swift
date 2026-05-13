import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import ReeveKit

/// `ImagePreprocess.process` invariants: always JPEG out, downsized
/// to ≤ maxLongestEdge, EXIF removed, deterministic SHA-256 for
/// identical input.
@Suite("ImagePreprocess")
struct ImagePreprocessTests {

    /// Build a solid-colour test image of an arbitrary size + format.
    private func makeTestImage(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!
        let mutable = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutable, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return mutable as Data
    }

    @Test
    func emitsJPEGRegardlessOfInputFormat() throws {
        let png = makeTestImage(width: 200, height: 200, type: .png)
        let out = try ImagePreprocess.process(png)
        #expect(out.mimeType == "image/jpeg")
        // Verify the produced bytes round-trip through ImageIO as a
        // JPEG specifically.
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        let type = CGImageSourceGetType(src)
        #expect(String(type! as String) == UTType.jpeg.identifier)
    }

    @Test
    func downsizesOversizedImages() throws {
        let huge = makeTestImage(width: 4000, height: 3000, type: .png)
        let out = try ImagePreprocess.process(huge)
        let maxEdge = Int(ImagePreprocess.maxLongestEdge)
        #expect(out.width <= maxEdge)
        #expect(out.height <= maxEdge)
        // Aspect ratio preserved within 1px rounding.
        let originalAspect = 4000.0 / 3000.0
        let newAspect = Double(out.width) / Double(out.height)
        #expect(abs(originalAspect - newAspect) < 0.02)
    }

    @Test
    func leavesAlreadySmallImagesUnscaledOrSmaller() throws {
        let small = makeTestImage(width: 800, height: 600, type: .png)
        let out = try ImagePreprocess.process(small)
        let maxEdge = Int(ImagePreprocess.maxLongestEdge)
        // Doesn't BLOW UP small images — they should come out at the
        // same dimensions (or smaller after JPEG's natural alignment;
        // never larger than the cap).
        #expect(out.width <= maxEdge)
        #expect(out.height <= maxEdge)
        #expect(out.width <= 800)
        #expect(out.height <= 600)
    }

    @Test
    func deterministicSHA256ForIdenticalInput() throws {
        let img = makeTestImage(width: 256, height: 256, type: .png)
        let a = try ImagePreprocess.process(img)
        let b = try ImagePreprocess.process(img)
        #expect(a.sha256 == b.sha256)
        #expect(a.data == b.data)
    }

    @Test
    func differentInputsProduceDifferentSHA() throws {
        let a = try ImagePreprocess.process(makeTestImage(width: 200, height: 200, type: .png))
        let b = try ImagePreprocess.process(makeTestImage(width: 300, height: 200, type: .png))
        #expect(a.sha256 != b.sha256)
    }

    @Test
    func rejectsNonImageBytes() {
        #expect(throws: ImagePreprocess.Failure.self) {
            try ImagePreprocess.process(Data("not an image".utf8))
        }
    }
}
