import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

#if os(iOS)
import MobileCoreServices
#endif

import CryptoKit

/// Pre-upload image normalisation. Three concerns, all done in one
/// re-encode pass (HEIC source → JPEG output is the common case;
/// downsize + EXIF strip ride along for free):
///
///   1. **HEIC → JPEG.** Most providers reject HEIC outright. iOS
///      cameras shoot HEIC by default; without conversion every
///      "take a photo" upload would 4xx at the upstream LLM.
///   2. **Downsize to ≤2048 px on the longest edge.** Vision models
///      charge per token / tile; sending a 4000×3000 phone photo
///      costs 4× what a 2048-max version costs at the same semantic
///      content. Bilinear-ish quality via `kCGInterpolationHigh`.
///   3. **Strip EXIF.** Default metadata includes GPS, capture
///      device, and lens info the user didn't volunteer. Dropping
///      it is a 1-line side effect of using `CGImageDestination`
///      without copying the source's metadata dictionary.
///
/// Output is always JPEG quality 0.9 — the perceptual quality vs.
/// byte-size sweet spot for downstream LLM vision. SHA-256 is
/// computed over the FINAL bytes so dedup keys to what's actually
/// stored, not what the user originally captured.
///
/// Same implementation on iOS and macOS (`ImageIO` is cross-
/// platform), so this lives in `PsmithKit` rather than a per-
/// platform shell.
public enum ImagePreprocess {
    public enum Failure: Error, LocalizedError {
        case decodeFailed
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .decodeFailed: return "Couldn't read that image. Try a different file."
            case .encodeFailed: return "Couldn't convert that image for upload."
            }
        }
    }

    /// Output of a preprocess pass.
    public struct Result: Sendable {
        public let data: Data
        public let mimeType: String   // always "image/jpeg" in v1
        public let sha256: String     // hex-encoded
        public let width: Int
        public let height: Int

        public init(data: Data, mimeType: String, sha256: String, width: Int, height: Int) {
            self.data = data
            self.mimeType = mimeType
            self.sha256 = sha256
            self.width = width
            self.height = height
        }
    }

    /// The longest-edge cap. 2048 is the sweet spot referenced in
    /// the multimodal plan; matches Anthropic / OpenAI / Google
    /// vision recommendations.
    public static let maxLongestEdge: CGFloat = 2048

    /// Re-encode `data` (whatever ImageIO can read — HEIC, PNG,
    /// JPEG, BMP, TIFF, …) into a JPEG with the constraints above.
    /// Idempotent on already-JPEG inputs that are already ≤ the cap
    /// (returns a fresh re-encoded copy — same semantic content,
    /// but stripped of EXIF and at a known quality).
    public static func process(_ data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw Failure.decodeFailed
        }

        // ImageIO's `kCGImageSourceCreateThumbnailFromImageAlways`
        // path bakes the downsize into the decode itself — much
        // less memory than decoding full-size then resizing. The
        // max pixel size is the longest edge we want.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongestEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw Failure.decodeFailed
        }

        // Encode without carrying over the original metadata
        // dictionary — that's how we drop EXIF / GPS / device id.
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.encodeFailed
        }
        let encodeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, cg, encodeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw Failure.encodeFailed
        }

        let outData = mutableData as Data
        let digest = SHA256.hash(data: outData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Result(
            data: outData,
            mimeType: "image/jpeg",
            sha256: hex,
            width: cg.width,
            height: cg.height
        )
    }
}
