import Foundation
import SwiftUI
import Observation

/// Mac-side user preferences not tied to any single conversation /
/// profile / provider — the kind of stuff that lives in the app's
/// "General" pane. Backed by UserDefaults so the values persist across
/// launches without a server round-trip.
///
/// When iOS lands the iOS plan migrates the storage to a shared
/// (server-synced) preferences mechanism. For now this is the
/// single source of truth on the Mac.
@Observable
@MainActor
public final class AppPreferences {
    /// Discrete index into `dynamicTypeStops` — the slider in the
    /// General settings pane writes this; the root scene applies the
    /// matching `DynamicTypeSize` via `.dynamicTypeSize(_:)` so every
    /// SwiftUI semantic font (`.body`, `.callout`, `.caption2`, …)
    /// scales together. Fonts created with `.system(size: N)` don't
    /// scale (by SwiftUI design); the bulk of Reeve's typography uses
    /// semantic styles so the slider has near-app-wide effect.
    ///
    /// Default: 3 → `.large` (the SwiftUI default).
    public var fontScaleIndex: Int = 3 {
        didSet {
            let clamped = max(0, min(Self.dynamicTypeStops.count - 1, fontScaleIndex))
            if clamped != fontScaleIndex {
                fontScaleIndex = clamped
                return
            }
            UserDefaults.standard.set(fontScaleIndex, forKey: Self.keyFontScale)
        }
    }

    /// When true, generation-finished notifications fire while Reeve
    /// is unfocused. Suppressed when Reeve is the active app — the
    /// user is already looking at the result.
    public var notifyOnUnfocusedCompletion: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnUnfocusedCompletion, forKey: Self.keyNotifyUnfocused) }
    }

    public init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyFontScale) != nil {
            fontScaleIndex = d.integer(forKey: Self.keyFontScale)
        }
        if d.object(forKey: Self.keyNotifyUnfocused) != nil {
            notifyOnUnfocusedCompletion = d.bool(forKey: Self.keyNotifyUnfocused)
        }
    }

    /// Slider stops mapped to `DynamicTypeSize` cases. Skips the
    /// accessibility tier (1–5) — those are very large and would mess
    /// up multi-pane Mac layouts; users who need that scale should
    /// rely on system-wide accessibility settings instead.
    public static let dynamicTypeStops: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
    ]

    public var dynamicTypeSize: DynamicTypeSize {
        let i = max(0, min(Self.dynamicTypeStops.count - 1, fontScaleIndex))
        return Self.dynamicTypeStops[i]
    }

    /// Human label for the font-size slider stop (e.g. "Small (1/7)").
    public var fontScaleLabel: String {
        let names = ["XS", "S", "M", "L", "XL", "XXL", "XXXL"]
        let i = max(0, min(names.count - 1, fontScaleIndex))
        return "\(names[i]) (\(i + 1)/\(names.count))"
    }

    private static let keyFontScale = "reeve.appPrefs.fontScaleIndex"
    private static let keyNotifyUnfocused = "reeve.appPrefs.notifyOnUnfocusedCompletion"
}

/// Shared module-level instance — same pattern as sharedNavigator /
/// sharedThemeStore / sharedWindowState. Lets module-scope code (the
/// MacNotifier construction in ConversationView's .task closure) reach
/// the prefs without threading them through every call site.
@MainActor
let sharedAppPreferences = AppPreferences()
