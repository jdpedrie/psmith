import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A color palette applied app-wide. Each color carries both light and dark
/// variants — `Color.dynamic(light:dark:)` resolves them at draw time via
/// the platform's appearance trait, so views never have to inspect
/// `@Environment(\.colorScheme)` themselves.
///
/// Themes only contribute branded colors (accent + chrome + highlight). The
/// semantic state colors — `.orange` for errors, `.yellow` for warnings,
/// `.red` for delete — stay system-fixed so a stream failure looks like a
/// stream failure regardless of palette.
public struct Theme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let blurb: String

    /// Primary brand accent. Drives `.tint()`, button backgrounds, selection
    /// rings, etc. Bubbles and badges derive from this via opacity.
    public let accent: Color

    /// Background tint for the message-bubble user/assistant fill, applied
    /// as `accent.opacity(0.18)` at most call sites today; exposed as a
    /// distinct field so a future redesign can break the link.
    public let bubbleTint: Color

    /// Selection highlight — used by the conversation list active row and
    /// similar "you're here" affordances.
    public let highlight: Color

    /// Window/chrome tint. Used as a subtle shade behind glass; the bulk of
    /// chrome is still `.thinMaterial` so the system background bleeds
    /// through naturally.
    public let chrome: Color

    /// Colors for messages attributed to a named speaker, indexed by the
    /// server's palette slot. Used for the rail and monogram on a persona
    /// message, never for text or fills.
    ///
    /// Hand-picked per theme rather than derived from `accent`, because
    /// rotating one hue fails on exactly the themes that need help most: every
    /// derived color on Nordic Mist is another pale icy blue, and
    /// discriminability is the whole point.
    ///
    /// No set contains a red, orange or yellow. Those are reserved app-wide
    /// for error, warning and delete, and a speaker whose rail reads as an
    /// error is worse than a speaker with no color at all.
    public let personaColors: [Color]

    public init(
        id: String,
        name: String,
        blurb: String,
        accent: Color,
        bubbleTint: Color,
        highlight: Color,
        chrome: Color,
        personaColors: [Color] = []
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.accent = accent
        self.bubbleTint = bubbleTint
        self.highlight = highlight
        self.chrome = chrome
        self.personaColors = personaColors
    }

    /// The color for a palette slot, wrapping around when a council has more
    /// members than the theme has colors.
    ///
    /// Wrapping rather than failing because a roster is user-authored and a
    /// missing color would render an unlabelled message. Two members sharing a
    /// rail past the fifth is a legibility problem the roster cap already
    /// discourages; a blank one is a bug.
    public func personaColor(_ index: Int) -> Color {
        guard !personaColors.isEmpty, index >= 0 else { return .secondary }
        return personaColors[index % personaColors.count]
    }

    public static let system = Theme(
        id: "system",
        name: "System",
        blurb: "Platform default. Uses your system accent color and stock neutrals.",
        accent: .accentColor,
        bubbleTint: .accentColor,
        highlight: .accentColor,
        chrome: .systemChrome,
        personaColors: [
            .dynamic(light: .hex("#5B6B7A"), dark: .hex("#93A5B5")),
            .dynamic(light: .hex("#6E7F63"), dark: .hex("#A3B594")),
            .dynamic(light: .hex("#7A6A80"), dark: .hex("#AE9BB4")),
            .dynamic(light: .hex("#4F7A78"), dark: .hex("#85B0AD")),
            .dynamic(light: .hex("#7C7060"), dark: .hex("#B3A48D")),
        ]
    )

    // Chrome dark-mode values are bumped well above the original near-black
    // spec. The originals (e.g. Sage #14171A) sit so close to system dark
    // that they're indistinguishable from "no theme" once Liquid Glass
    // materials layer over them. The brighter values here are still dark,
    // but carry the palette's hue clearly enough to read across the whole
    // app surface.

    public static let sage = Theme(
        id: "sage",
        name: "Sage & Graphite",
        blurb: "Calm, premium, very un-default. Muted sage on deep forest graphite.",
        accent:    .dynamic(light: .hex("#5A8870"), dark: .hex("#7FA48A")),
        bubbleTint: .dynamic(light: .hex("#5A8870"), dark: .hex("#7FA48A")),
        highlight: .dynamic(light: .hex("#C5D8CB"), dark: .hex("#A8C5B2")),
        chrome:    .dynamic(light: .hex("#EAF0EC"), dark: .hex("#1F2A24")),
        personaColors: [
            .dynamic(light: .hex("#5A8870"), dark: .hex("#7FA48A")),
            .dynamic(light: .hex("#6F7F4E"), dark: .hex("#9DAE78")),
            .dynamic(light: .hex("#41756F"), dark: .hex("#74A39C")),
            .dynamic(light: .hex("#77705A"), dark: .hex("#ADA184")),
            .dynamic(light: .hex("#516B86"), dark: .hex("#8AA6BE")),
        ]
    )

    public static let clay = Theme(
        id: "clay",
        name: "Clay & Ink",
        blurb: "Warm, approachable. Terracotta on linen-paper neutrals.",
        accent:    .dynamic(light: .hex("#B25E33"), dark: .hex("#C77A4F")),
        bubbleTint: .dynamic(light: .hex("#B25E33"), dark: .hex("#C77A4F")),
        highlight: .dynamic(light: .hex("#DBA987"), dark: .hex("#E0A574")),
        chrome:    .dynamic(light: .hex("#F2E9DC"), dark: .hex("#2A211A")),
        personaColors: [
            .dynamic(light: .hex("#8A6A52"), dark: .hex("#BC9A7E")),
            .dynamic(light: .hex("#6B7358"), dark: .hex("#A0A981")),
            .dynamic(light: .hex("#7B5A63"), dark: .hex("#B08A93")),
            .dynamic(light: .hex("#4F6E74"), dark: .hex("#87A9AF")),
            .dynamic(light: .hex("#6E6480"), dark: .hex("#A198B5")),
        ]
    )

    public static let slate = Theme(
        id: "slate",
        name: "Slate Pro",
        blurb: "Apple Pro-app neutral. Desaturated steel blue, accent gets out of the way.",
        accent:    .dynamic(light: .hex("#4A6E8A"), dark: .hex("#6B8AA4")),
        bubbleTint: .dynamic(light: .hex("#4A6E8A"), dark: .hex("#6B8AA4")),
        highlight: .dynamic(light: .hex("#6B8AA4"), dark: .hex("#9DB6CC")),
        chrome:    .dynamic(light: .hex("#E8EEF4"), dark: .hex("#1C2530")),
        personaColors: [
            .dynamic(light: .hex("#4A6E8A"), dark: .hex("#6B8AA4")),
            .dynamic(light: .hex("#57786E"), dark: .hex("#87A99E")),
            .dynamic(light: .hex("#6A6480"), dark: .hex("#9992B0")),
            .dynamic(light: .hex("#7A6B5C"), dark: .hex("#ADA08F")),
            .dynamic(light: .hex("#3F7A85"), dark: .hex("#74AAB4")),
        ]
    )

    public static let aubergine = Theme(
        id: "aubergine",
        name: "Aubergine & Cream",
        blurb: "Distinctive without being loud. Muted plum on warm gray.",
        accent:    .dynamic(light: .hex("#6E5378"), dark: .hex("#8E6F94")),
        bubbleTint: .dynamic(light: .hex("#6E5378"), dark: .hex("#8E6F94")),
        highlight: .dynamic(light: .hex("#B8A296"), dark: .hex("#D9C8B5")),
        chrome:    .dynamic(light: .hex("#F1E8EE"), dark: .hex("#251D2C")),
        personaColors: [
            .dynamic(light: .hex("#6E5378"), dark: .hex("#8E6F94")),
            .dynamic(light: .hex("#5A6A85"), dark: .hex("#8698B4")),
            .dynamic(light: .hex("#6E6355"), dark: .hex("#A39581")),
            .dynamic(light: .hex("#4E7168"), dark: .hex("#83A79C")),
            .dynamic(light: .hex("#834F6B"), dark: .hex("#B07E96")),
        ]
    )

    public static let nordic = Theme(
        id: "nordic",
        name: "Nordic Mist",
        blurb: "Crisp, cold, low-stim. Pale icy blue on cool gray neutrals.",
        accent:    .dynamic(light: .hex("#4F8092"), dark: .hex("#88B0BF")),
        bubbleTint: .dynamic(light: .hex("#4F8092"), dark: .hex("#88B0BF")),
        highlight: .dynamic(light: .hex("#88B0BF"), dark: .hex("#B8CDD6")),
        chrome:    .dynamic(light: .hex("#E6EDF2"), dark: .hex("#1A242E")),
        personaColors: [
            .dynamic(light: .hex("#4F8092"), dark: .hex("#88B0BF")),
            .dynamic(light: .hex("#5C7385"), dark: .hex("#97A9B8")),
            .dynamic(light: .hex("#4A7A6E"), dark: .hex("#84AEA2")),
            .dynamic(light: .hex("#6A6D84"), dark: .hex("#9FA2B8")),
            .dynamic(light: .hex("#7A6E7E"), dark: .hex("#AFA1B2")),
        ]
    )

    public static let allThemes: [Theme] = [.system, .sage, .clay, .slate, .aubergine, .nordic]
}

// MARK: - Color helpers

public extension Color {
    /// Light/dark dynamic color. Resolves to `light` or `dark` based on the
    /// effective platform appearance at draw time. Avoids the
    /// `@Environment(\.colorScheme)` dance at every call site.
    static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return light
        #endif
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

    /// Per-platform "system chrome" — the surface tint for window/scene
    /// backgrounds. Mac uses `windowBackgroundColor`; iOS uses
    /// `systemBackground`.
    static var systemChrome: Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color.gray
        #endif
    }
}

// MARK: - ThemeStore

/// Owns the active Theme and persists the choice across launches via
/// UserDefaults. One instance per platform shell — Mac and iOS each
/// instantiate a singleton and inject it via @Environment so the picker
/// and every themed view see the same state.
@MainActor
@Observable
public final class ThemeStore {
    private static let defaultsKey = "psmith.theme.id"

    public var current: Theme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: Self.defaultsKey)
        }
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Theme.system.id
        self.current = Theme.allThemes.first(where: { $0.id == saved }) ?? .system
    }
}

// MARK: - Environment plumbing

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .system
}

public extension EnvironmentValues {
    /// The active palette. Read this in any view that uses branded colors
    /// (accent, bubble tint, highlight, chrome). The shared ThemeStore is
    /// what writes to it via the platform shell.
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
