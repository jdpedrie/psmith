// Generates the per-theme app icons for iOS and macOS by recoloring the
// base icon's cool blue-gray elements (the jacket-shaped speech bubble and
// the bow tie) into each theme's accent hue. Shading is kept: lightness is
// untouched, only hue and saturation move. The cream ground, the head and
// the gray buttons are warm or neutral and fall outside the mask, so every
// variant stays recognizably the same icon.
//
//   swift scripts/recolor-app-icon.swift
//
// Writes clients/psmithd-ios/PsmithiOS/Assets.xcassets/AppIcon-<Theme>.appiconset
// (iOS alternate icons, opaque as iOS requires) and
// clients/psmithd-mac/AppBundle/AppIcon-<Theme>.png (the Mac's runtime Dock
// icons, keeping the base's transparent margins). Re-run after changing a
// base icon or a theme's accent; the hues below mirror the light-mode
// accents in PsmithUI/Composite/Theme.swift.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let themes: [(name: String, accent: String)] = [
    ("Sage", "#2C7550"),
    ("Clay", "#B04A22"),
    ("Slate", "#2C65A0"),
    ("Aubergine", "#7A3A8C"),
    ("Nordic", "#1C6F8E"),
]

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("clients/psmithd-ios/PsmithiOS/Assets.xcassets")
let base = catalog.appendingPathComponent("AppIcon.appiconset/AppIcon-1024.png")
let macBundle = root.appendingPathComponent("clients/psmithd-mac/AppBundle")
let macBase = macBundle.appendingPathComponent("AppIcon.png")

// MARK: - Color math

func hsl(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
    let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
    guard mx != mn else { return (0, 0, l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    return (h * 60, s, l)
}

func rgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    guard s > 0 else { return (l, l, l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func channel(_ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }
    let hh = h / 360
    return (channel(hh + 1 / 3), channel(hh), channel(hh - 1 / 3))
}

func hex(_ s: String) -> (Double, Double, Double) {
    var v: UInt64 = 0
    Scanner(string: String(s.dropFirst())).scanHexInt64(&v)
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// How much of a pixel belongs to the recolorable (cool) elements. The
/// base's blues sit at hue 198-223 with saturation 0.10-0.19; the warm
/// cream and gray parts are hue ~40 or saturation under 0.05.
func mask(h: Double, s: Double) -> Double {
    let satWeight = smoothstep(0.035, 0.08, s)
    let hueWeight = smoothstep(165, 185, h) * (1 - smoothstep(250, 270, h))
    return satWeight * hueWeight
}

// The base jacket's typical saturation. Scaling relative to it keeps the
// jacket a pastel and the bow tie (more saturated) the deepest note.
let baseJacketSaturation = 0.14

// MARK: - Recolor

/// Pixels as RGBA bytes. With `alpha` the bytes are premultiplied (what
/// CoreGraphics gives for images with transparency); without, the alpha
/// byte is ignored and the image is opaque.
func load(_ url: URL, alpha: Bool) -> (pixels: [UInt8], width: Int, height: Int) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("can't read \(url.path)")
    }
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buffer, w, h)
}

func recolor(_ pixels: [UInt8], accent: String, alpha: Bool) -> [UInt8] {
    let (ar, ag, ab) = hex(accent)
    let target = hsl(ar, ag, ab)
    var out = pixels
    for i in stride(from: 0, to: pixels.count, by: 4) {
        // Premultiplied input: divide out alpha first, or anti-aliased
        // edges read as darker, different-hued pixels.
        let a = alpha ? Double(pixels[i + 3]) / 255 : 1
        guard a > 0 else { continue }
        let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
        let p = hsl(r, g, b)
        let w = mask(h: p.h, s: p.s)
        guard w > 0 else { continue }
        let s = min(1, p.s / baseJacketSaturation * target.s * 0.55)
        let (nr, ng, nb) = rgb(target.h, s, p.l)
        out[i] = UInt8(min(1, r + (nr - r) * w) * a * 255 + 0.5)
        out[i + 1] = UInt8(min(1, g + (ng - g) * w) * a * 255 + 0.5)
        out[i + 2] = UInt8(min(1, b + (nb - b) * w) * a * 255 + 0.5)
    }
    return out
}

func write(_ pixels: [UInt8], width: Int, height: Int, alpha: Bool, to url: URL) {
    var buffer = pixels
    let ctx = CGContext(
        data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
    )!
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("can't write \(url.path)") }
}

let (pixels, width, height) = load(base, alpha: false)
let mac = load(macBase, alpha: true)
for theme in themes {
    let macFile = macBundle.appendingPathComponent("AppIcon-\(theme.name).png")
    write(recolor(mac.pixels, accent: theme.accent, alpha: true), width: mac.width, height: mac.height, alpha: true, to: macFile)
    print("wrote \(macFile.lastPathComponent)")

    let dir = catalog.appendingPathComponent("AppIcon-\(theme.name).appiconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = "AppIcon-\(theme.name)-1024.png"
    write(recolor(pixels, accent: theme.accent, alpha: false), width: width, height: height, alpha: false, to: dir.appendingPathComponent(file))
    let contents = """
    {
      "images" : [
        {
          "filename" : "\(file)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(dir.lastPathComponent)")
}
