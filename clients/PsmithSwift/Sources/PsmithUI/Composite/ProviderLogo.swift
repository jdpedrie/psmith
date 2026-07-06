import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias PsmithPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PsmithPlatformImage = UIImage
#endif

/// SwiftUI view that renders a provider logo by slug, falling back to a
/// generic icon when the slug is empty or the asset is missing.
///
/// The slug names a SVG file under `PsmithUI/Resources/Logos/`. LobeHub
/// authoring convention: monochrome icons use `fill="currentColor"` so
/// they tint to the surrounding foreground style; colored variants
/// (`qwen-color`) render at their authored palette regardless of
/// `foregroundStyle`.
///
/// macOS 14+ NSImage + iOS 13+ UIImage decode SVG natively, so we load
/// the resource URL and hand the bytes through. Failures (missing file,
/// decode error) fall back silently to the generic icon — there is no
/// error state worth showing to the user for a logo lookup.
public struct ProviderLogo: View {
    let slug: String?
    var size: CGFloat = 24

    public init(slug: String?, size: CGFloat = 24) {
        self.slug = slug
        self.size = size
    }

    public var body: some View {
        if let img = Self.image(for: slug) {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
            #elseif canImport(UIKit)
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
            #endif
        } else {
            // Fallback: SF Symbols globe — neutral placeholder used by
            // the "Custom" template tile and any preset whose slug
            // didn't resolve to a bundled SVG.
            Image(systemName: "globe")
                .font(.system(size: size * 0.7, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    /// Cache: bundle resource lookups + image decode are not free, and
    /// the picker re-renders on every pill mouseover. Keyed by slug; the
    /// values live for the process lifetime (13 entries max — bounded).
    private static let cache = NSCache<NSString, PsmithPlatformImage>()

    private static func image(for slug: String?) -> PsmithPlatformImage? {
        guard let slug, !slug.isEmpty else { return nil }
        let key = slug as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let isColorVariant = slug.hasSuffix("-color")

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Mac: NSImage decodes SVG natively.
        guard let url = Bundle.module.url(forResource: slug, withExtension: "svg") else {
            return nil
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = !isColorVariant
        cache.setObject(img, forKey: key)
        return img

        #elseif canImport(UIKit)
        // iOS: UIImage can't decode raw SVG bytes from arbitrary file
        // URLs (asset catalogs only). The SwiftPM resource bundle has a
        // `<slug>.png` alongside each `<slug>.svg` (built by
        // `scripts/convert-svgs-to-pngs.sh`); load that via
        // contentsOfFile, which handles PNG natively.
        guard let url = Bundle.module.url(forResource: slug, withExtension: "png"),
              let img = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        // Color variants render as authored; monochrome variants tint
        // to the inherited `foregroundStyle` via `.alwaysTemplate`.
        let rendered = img.withRenderingMode(isColorVariant ? .alwaysOriginal : .alwaysTemplate)
        cache.setObject(rendered, forKey: key)
        return rendered

        #else
        return nil
        #endif
    }
}
