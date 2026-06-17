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
    /// When true, generation-finished notifications fire while Spalt
    /// is unfocused. Suppressed when Spalt is the active app — the
    /// user is already looking at the result.
    public var notifyOnUnfocusedCompletion: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnUnfocusedCompletion, forKey: Self.keyNotifyUnfocused) }
    }

    public init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyNotifyUnfocused) != nil {
            notifyOnUnfocusedCompletion = d.bool(forKey: Self.keyNotifyUnfocused)
        }
    }

    private static let keyNotifyUnfocused = "spalt.appPrefs.notifyOnUnfocusedCompletion"
}

/// Shared module-level instance — module-scope helpers (Mac's
/// MacNotifier construction, iOS app shell) reach through this rather
/// than threading prefs through every call site.
@MainActor
public let sharedAppPreferences = AppPreferences()
