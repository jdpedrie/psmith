import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// App-wide text scale. 1.0 = platform default sizes. The Mac app
/// drives this from Appearance settings (plus ⌘+/⌘−); iOS leaves it
/// at 1.0 and relies on system Dynamic Type instead.
///
/// Why this exists: on macOS, `dynamicTypeSize` is a no-op for
/// semantic fonts, so "make all the text bigger" has no system lever.
/// Every text-bearing view routes through `.scaledFont(...)` instead
/// of `.font(...)`; at scale 1.0 the modifier reproduces the semantic
/// font exactly (identical rendering on iOS), at any other scale it
/// swaps in a sized font derived from the platform's own base size
/// for that style.
public struct FontScaleKey: EnvironmentKey {
    public static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// The platform's base point size for a semantic text style — what
/// `.font(.callout)` renders at when nothing scales it. Resolved from
/// the system font tables at runtime so the numbers stay honest
/// across OS versions.
public func baseSize(for style: Font.TextStyle) -> CGFloat {
    #if canImport(AppKit)
    return NSFont.preferredFont(forTextStyle: nsTextStyle(style)).pointSize
    #else
    return UIFont.preferredFont(forTextStyle: uiTextStyle(style)).pointSize
    #endif
}

#if canImport(AppKit)
private func nsTextStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
    switch style {
    case .largeTitle:  return .largeTitle
    case .title:       return .title1
    case .title2:      return .title2
    case .title3:      return .title3
    case .headline:    return .headline
    case .subheadline: return .subheadline
    case .body:        return .body
    case .callout:     return .callout
    case .footnote:    return .footnote
    case .caption:     return .caption1
    case .caption2:    return .caption2
    @unknown default:  return .body
    }
}
#else
private func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
    switch style {
    case .largeTitle:  return .largeTitle
    case .title:       return .title1
    case .title2:      return .title2
    case .title3:      return .title3
    case .headline:    return .headline
    case .subheadline: return .subheadline
    case .body:        return .body
    case .callout:     return .callout
    case .footnote:    return .footnote
    case .caption:     return .caption1
    case .caption2:    return .caption2
    @unknown default:  return .body
    }
}
#endif

private struct ScaledSemanticFont: ViewModifier {
    let style: Font.TextStyle
    var weight: Font.Weight?
    var design: Font.Design?
    var monospacedDigit: Bool
    @Environment(\.fontScale) private var scale

    func body(content: Content) -> some View {
        content.font(resolved)
    }

    private var resolved: Font {
        var f: Font
        if scale == 1.0 {
            // Exactly the semantic font — keeps iOS Dynamic Type
            // behavior and byte-identical Mac rendering at 100%.
            f = Font.system(style, design: design ?? .default)
        } else {
            f = Font.system(size: baseSize(for: style) * scale, design: design ?? .default)
            if style == .headline, weight == nil {
                // .headline carries an implicit semibold the sized
                // constructor loses.
                f = f.weight(.semibold)
            }
        }
        if let weight { f = f.weight(weight) }
        if monospacedDigit { f = f.monospacedDigit() }
        return f
    }
}

private struct ScaledSizedFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight?
    var design: Font.Design?
    var monospacedDigit: Bool
    @Environment(\.fontScale) private var scale

    func body(content: Content) -> some View {
        var f = Font.system(size: size * scale, design: design ?? .default)
        if let weight { f = f.weight(weight) }
        if monospacedDigit { f = f.monospacedDigit() }
        return content.font(f)
    }
}

public extension View {
    /// Drop-in replacement for `.font(.<style>)` (and its `.weight` /
    /// `.monospaced` / `.monospacedDigit` chains) that honors the
    /// app-wide `fontScale`.
    func scaledFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledSemanticFont(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// Drop-in replacement for `.font(.system(size:weight:design:))`
    /// that honors the app-wide `fontScale`.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledSizedFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}
