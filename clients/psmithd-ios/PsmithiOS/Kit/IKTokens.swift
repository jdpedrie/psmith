import SwiftUI
import UIKit
import PsmithUI

// The redesign's tokens (the Themes board on the "Psmith iOS redesign"
// canvas, and docs/clients/ios-redesign/plan.md). A theme supplies accent,
// chrome and highlight per appearance; every other surface derives from those
// here, so a new theme needs no per-screen work. Ink, Settings grounds and the
// state colors are fixed per appearance and don't follow the theme.

enum IK {
    // MARK: Ink

    static let text = Color.dynamic(light: .hex("#17202A"), dark: .hex("#E6EAEE"))
    /// Body-adjacent secondary: action icons, pill labels, emphasized detail.
    static let strong = Color.dynamic(light: .hex("#2E3A46"), dark: .hex("#C9D2DB"))
    static let secondary = Color.dynamic(light: .hex("#525E6A"), dark: .hex("#9AA6B2"))
    static let tertiary = Color.dynamic(light: .hex("#5C6773"), dark: .hex("#7F8B97"))
    /// Disclosure chevrons in Settings rows.
    static let chevron = Color.dynamic(light: .hex("#8A949E"), dark: .hex("#6E7A86"))

    // MARK: States

    static let red = Color.dynamic(light: .hex("#BF3A2F"), dark: .hex("#F08A80"))
    static let destructiveFill = Color.dynamic(light: .hex("#D93D32"), dark: .hex("#D9544A"))
    static let orange = Color.dynamic(light: .hex("#A85808"), dark: .hex("#F2A65A"))
    static let green = Color.dynamic(light: .hex("#237A4B"), dark: .hex("#7FD3A2"))

    // MARK: Settings (neutral, not themed)

    static let settingsGround = Color.dynamic(light: .hex("#F2F2F7"), dark: .hex("#1B2027"))
    static let settingsGroup = Color.dynamic(light: .hex("#FFFFFF"), dark: .hex("#20262E"))

    // MARK: Overlays

    /// The boards' white-on-dark washes; on light they become ink at the
    /// same alpha. `wash(0.07)` is the chip fill, `0.04` a themed group.
    static func wash(_ alpha: Double) -> Color {
        Color.dynamic(light: Color(red: 16 / 255, green: 26 / 255, blue: 38 / 255).opacity(alpha),
                      dark: Color.white.opacity(alpha))
    }

    /// A hairline ring; the dark boards draw it white, the light ones ink.
    static func ring(_ alpha: Double) -> Color { wash(alpha) }

    static let shadow = Color.dynamic(light: Color(red: 16 / 255, green: 32 / 255, blue: 52 / 255).opacity(0.14),
                                      dark: Color.black.opacity(0.35))

    // MARK: Type

    static let mono = "ui-monospace"
}

extension Theme {
    /// The list's ground: chrome under 24% black in dark, over 50% white in light.
    var well: Color { chrome.ikBlend(dark: (.black, 0.24), light: (.white, 0.5)) }

    /// The user's message bubble: chrome tinted by the accent.
    var bubble: Color { chrome.ikBlend(dark: (accent, 0.24), light: (accent, 0.16)) }

    /// Accent as text and icons on a wash of it.
    var accentInk: Color { accent.ikBlend(dark: (.white, 0.45), light: (.white, 0)) }

    /// The "you're here" fill: selected chips and rows. Every branded theme
    /// supplies a pale highlight for this; System's highlight is the solid
    /// platform accent, which would hide accent-colored text on it.
    var selection: Color { id == "system" ? accent.opacity(0.22) : highlight }

    /// The tint under Liquid Glass on themed screens.
    var glassTint: Color {
        chrome.ikBlend(dark: (.white, 0.10), light: (.white, 1)).ikOpacity(dark: 0.55, light: 0.62)
    }
}

extension Color {
    /// Mixes toward a per-appearance target, resolved at draw time.
    func ikBlend(dark: (Color, Double), light: (Color, Double)) -> Color {
        let base = self
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let (target, t) = isDark ? dark : light
            let a = UIColor(base).resolvedColor(with: traits).ikRGBA
            let b = UIColor(target).resolvedColor(with: traits).ikRGBA
            return UIColor(red: a.r + (b.r - a.r) * t,
                           green: a.g + (b.g - a.g) * t,
                           blue: a.b + (b.b - a.b) * t,
                           alpha: a.a)
        })
    }

    /// Per-appearance opacity.
    func ikOpacity(dark: Double, light: Double) -> Color {
        let base = self
        return Color(uiColor: UIColor { traits in
            UIColor(base).resolvedColor(with: traits)
                .withAlphaComponent(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    var ikRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}

/// A profile's dot color, stable per profile id. None of these is red,
/// orange or yellow: those are reserved for errors, warnings and delete.
enum ProfileColor {
    static let palette: [Color] = [
        .dynamic(light: .hex("#2C65A0"), dark: .hex("#4C96D9")),
        .dynamic(light: .hex("#2E8F86"), dark: .hex("#4FB3A9")),
        .dynamic(light: .hex("#7A5CC7"), dark: .hex("#B49AF0")),
        .dynamic(light: .hex("#B8538E"), dark: .hex("#E59AC8")),
        .dynamic(light: .hex("#4B63C2"), dark: .hex("#8FA8F5")),
        .dynamic(light: .hex("#4F7A22"), dark: .hex("#9CCB6A")),
    ]

    static func index(for id: String) -> Int {
        // FNV-1a: stable across launches, unlike hashValue.
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(palette.count))
    }

    static func color(for id: String, theme: Theme) -> Color { palette[index(for: id)] }
}
