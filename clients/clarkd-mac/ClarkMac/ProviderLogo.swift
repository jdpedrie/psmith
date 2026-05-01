import SwiftUI
import AppKit

/// SwiftUI view that renders a provider logo by slug, falling back to a
/// generic icon when the slug is empty or the asset is missing.
///
/// The slug names a SVG file under ClarkMac/Logos/ (bundled via
/// Package.swift `resources: [.copy("Logos")]`). LobeHub authoring
/// convention: monochrome icons use `fill="currentColor"` so they tint
/// to the surrounding foreground style; colored variants (qwen-color)
/// render at their authored palette regardless of foregroundStyle.
///
/// macOS 14+ NSImage decodes SVG natively, so we load the resource URL
/// and hand the bytes through. Failures (missing file, decode error)
/// fall back silently to the generic icon — there is no error state
/// worth showing to the user for a logo lookup.
struct ProviderLogo: View {
    let slug: String?
    var size: CGFloat = 24

    var body: some View {
        if let img = Self.image(for: slug) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
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

    /// Cache: bundle resource lookups + NSImage decode are not free, and
    /// the picker re-renders on every pill mouseover. Keyed by slug; the
    /// values live for the process lifetime (13 entries max — bounded).
    private static let cache = NSCache<NSString, NSImage>()

    private static func image(for slug: String?) -> NSImage? {
        guard let slug, !slug.isEmpty else { return nil }
        let key = slug as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Resources declared via Package.swift `resources: [.copy("Logos")]`
        // land in the SPM-generated module bundle, not Bundle.main. The
        // `Bundle.module` accessor is auto-generated per target.
        guard let url = Bundle.module.url(forResource: slug, withExtension: "svg", subdirectory: "Logos") else {
            return nil
        }
        guard let img = NSImage(contentsOf: url) else { return nil }

        // Light/dark adaptation: monochrome SVGs (which LobeHub authors
        // with `fill="currentColor"`) need NSImage.isTemplate=true so
        // SwiftUI's foregroundStyle actually tints them — without it
        // AppKit renders the SVG's currentColor fallback (typically
        // black) regardless of color scheme. Color variants
        // (qwen-color, anything else ending `-color`) keep their
        // authored palette.
        let isColorVariant = slug.hasSuffix("-color")
        img.isTemplate = !isColorVariant

        cache.setObject(img, forKey: key)
        return img
    }
}
