import Foundation
import SwiftUI
import Observation

/// Cross-platform user preferences not tied to any single conversation
/// / profile / provider. UserDefaults-backed so values persist across
/// launches without a server round-trip. Shared between Mac and iOS;
/// the iOS plan eventually migrates this to server-synced storage,
/// but the per-device fallback stays useful for offline edits.
@Observable
@MainActor
public final class AppPreferences {
    /// When true, generation-finished notifications fire while Psmith
    /// is unfocused. Suppressed when Psmith is the active app — the
    /// user is already looking at the result.
    public var notifyOnUnfocusedCompletion: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnUnfocusedCompletion, forKey: Self.keyNotifyUnfocused) }
    }

    /// App-wide text scale, 1.0 = platform default. Driven by the
    /// Appearance pane's slider and the ⌘+/⌘−/⌘0 menu commands on
    /// the Mac; iOS leaves it alone (Dynamic Type covers it there).
    /// Clamped so nobody sliders themselves into an unusable UI.
    public var fontScale: Double = 1.0 {
        didSet {
            let clamped = min(max(fontScale, Self.minFontScale), Self.maxFontScale)
            if clamped != fontScale { fontScale = clamped; return }
            UserDefaults.standard.set(fontScale, forKey: Self.keyFontScale)
        }
    }

    /// Shows every turn's metadata inline: role labels, the model on
    /// every reply, token counts and timestamps. Off by default, where
    /// the transcript keeps only signals (a model change, a poor cache
    /// on a large prompt) and the details sit one tap away in the
    /// usage sheet.
    public var showTurnDetails: Bool = false {
        didSet { UserDefaults.standard.set(showTurnDetails, forKey: Self.keyShowTurnDetails) }
    }

    public static let minFontScale: Double = 0.8
    public static let maxFontScale: Double = 1.6
    public static let fontScaleStep: Double = 0.1

    public init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyNotifyUnfocused) != nil {
            notifyOnUnfocusedCompletion = d.bool(forKey: Self.keyNotifyUnfocused)
        }
        if d.object(forKey: Self.keyFontScale) != nil {
            fontScale = d.double(forKey: Self.keyFontScale)
        }
        showTurnDetails = d.bool(forKey: Self.keyShowTurnDetails)
    }

    private static let keyNotifyUnfocused = "psmith.appPrefs.notifyOnUnfocusedCompletion"
    private static let keyFontScale = "psmith.appPrefs.fontScale"
    private static let keyShowTurnDetails = "psmith.appPrefs.showTurnDetails"
}

/// Shared module-level instance — module-scope helpers (Mac's
/// MacNotifier construction, iOS app shell) reach through this rather
/// than threading prefs through every call site.
@MainActor
public let sharedAppPreferences = AppPreferences()
