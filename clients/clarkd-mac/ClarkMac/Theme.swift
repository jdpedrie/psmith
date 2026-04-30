import SwiftUI
import AppKit

/// A color palette applied app-wide. Each color carries both light and dark
/// variants — `Color.dynamic(light:dark:)` resolves them at draw time via the
/// NSAppearance attached to the NSColor's dynamic provider, so views never
/// have to inspect `@Environment(\.colorScheme)` themselves.
///
/// Themes only contribute branded colors (accent + chrome + highlight). The
/// semantic state colors — `.orange` for errors, `.yellow` for warnings,
/// `.red` for delete — stay system-fixed so a stream failure looks like a
/// stream failure regardless of palette.
struct Theme: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let blurb: String

    /// Primary brand accent. Drives `.tint()`, button backgrounds, selection
    /// rings, etc. Bubbles and badges derive from this via opacity.
    let accent: Color

    /// Background tint for the message-bubble user/assistant fill, applied
    /// as `accent.opacity(0.18)` at most call sites today; exposed as a
    /// distinct field so a future redesign can break the link.
    let bubbleTint: Color

    /// Selection highlight — used by the conversation list active row and
    /// similar "you're here" affordances.
    let highlight: Color

    /// Window/chrome tint. Used as a subtle shade behind glass; the bulk of
    /// chrome is still `.thinMaterial` so the macOS desktop wallpaper bleeds
    /// through naturally.
    let chrome: Color

    static let system = Theme(
        id: "system",
        name: "System",
        blurb: "macOS default. Uses your system accent color and stock neutrals.",
        accent: .accentColor,
        bubbleTint: .accentColor,
        highlight: .accentColor,
        chrome: Color(nsColor: .windowBackgroundColor)
    )

    // Chrome dark-mode values are bumped well above the original near-black
    // spec. The originals (e.g. Sage #14171A) sit so close to system dark
    // that they're indistinguishable from "no theme" once Liquid Glass
    // materials layer over them. The brighter values here are still dark,
    // but carry the palette's hue clearly enough to read across the whole
    // app surface.

    static let sage = Theme(
        id: "sage",
        name: "Sage & Graphite",
        blurb: "Calm, premium, very un-default. Muted sage on deep forest graphite.",
        accent:    .dynamic(light: .hex("#5A8870"), dark: .hex("#7FA48A")),
        bubbleTint: .dynamic(light: .hex("#5A8870"), dark: .hex("#7FA48A")),
        highlight: .dynamic(light: .hex("#C5D8CB"), dark: .hex("#A8C5B2")),
        chrome:    .dynamic(light: .hex("#EAF0EC"), dark: .hex("#1F2A24"))
    )

    static let clay = Theme(
        id: "clay",
        name: "Clay & Ink",
        blurb: "Warm, approachable. Terracotta on linen-paper neutrals.",
        accent:    .dynamic(light: .hex("#B25E33"), dark: .hex("#C77A4F")),
        bubbleTint: .dynamic(light: .hex("#B25E33"), dark: .hex("#C77A4F")),
        highlight: .dynamic(light: .hex("#DBA987"), dark: .hex("#E0A574")),
        chrome:    .dynamic(light: .hex("#F2E9DC"), dark: .hex("#2A211A"))
    )

    static let slate = Theme(
        id: "slate",
        name: "Slate Pro",
        blurb: "Apple Pro-app neutral. Desaturated steel blue, accent gets out of the way.",
        accent:    .dynamic(light: .hex("#4A6E8A"), dark: .hex("#6B8AA4")),
        bubbleTint: .dynamic(light: .hex("#4A6E8A"), dark: .hex("#6B8AA4")),
        highlight: .dynamic(light: .hex("#6B8AA4"), dark: .hex("#9DB6CC")),
        chrome:    .dynamic(light: .hex("#E8EEF4"), dark: .hex("#1C2530"))
    )

    static let aubergine = Theme(
        id: "aubergine",
        name: "Aubergine & Cream",
        blurb: "Distinctive without being loud. Muted plum on warm gray.",
        accent:    .dynamic(light: .hex("#6E5378"), dark: .hex("#8E6F94")),
        bubbleTint: .dynamic(light: .hex("#6E5378"), dark: .hex("#8E6F94")),
        highlight: .dynamic(light: .hex("#B8A296"), dark: .hex("#D9C8B5")),
        chrome:    .dynamic(light: .hex("#F1E8EE"), dark: .hex("#251D2C"))
    )

    static let nordic = Theme(
        id: "nordic",
        name: "Nordic Mist",
        blurb: "Crisp, cold, low-stim. Pale icy blue on cool gray neutrals.",
        accent:    .dynamic(light: .hex("#4F8092"), dark: .hex("#88B0BF")),
        bubbleTint: .dynamic(light: .hex("#4F8092"), dark: .hex("#88B0BF")),
        highlight: .dynamic(light: .hex("#88B0BF"), dark: .hex("#B8CDD6")),
        chrome:    .dynamic(light: .hex("#E6EDF2"), dark: .hex("#1A242E"))
    )

    static let allThemes: [Theme] = [.system, .sage, .clay, .slate, .aubergine, .nordic]
}

// MARK: - Color helpers

extension Color {
    /// Light/dark dynamic color. Resolves to `light` or `dark` based on the
    /// effective NSAppearance at draw time. Avoids the @Environment(\.colorScheme)
    /// dance at every call site.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }

    /// Hex literal -> Color. Accepts "#RRGGBB" or "RRGGBB". Bad input renders
    /// black — it's a programmer-input function, not user input.
    static func hex(_ s: String) -> Color {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        return Color(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >>  8) & 0xFF) / 255.0,
            blue:  Double((rgb >>  0) & 0xFF) / 255.0
        )
    }
}

// MARK: - ThemeStore

/// Owns the active Theme and persists the choice across launches via
/// UserDefaults. Single instance lives in `ClarkMacApp` and is injected
/// via @Environment so the picker and every themed view see the same state.
@MainActor
@Observable
final class ThemeStore {
    private static let defaultsKey = "clark.theme.id"

    var current: Theme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: Self.defaultsKey)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Theme.system.id
        self.current = Theme.allThemes.first(where: { $0.id == saved }) ?? .system
    }
}

/// Shared instance, parallel to `sharedNavigator`. AppDelegate (driven by
/// AppKit notifications, can't read SwiftUI environment) needs the active
/// chrome color to set NSWindow.backgroundColor; without a global, the only
/// path is to plumb the env all the way into AppKit, which doesn't work.
@MainActor
let sharedThemeStore = ThemeStore()

// MARK: - Environment plumbing

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .system
}

extension EnvironmentValues {
    /// The active palette. Read this in any view that uses branded colors
    /// (accent, bubble tint, highlight, chrome). The shared ThemeStore is
    /// what writes to it via ClarkMacApp.
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
