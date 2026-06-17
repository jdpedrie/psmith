import Foundation

/// User-tunable cache settings, persisted to UserDefaults so they
/// survive app launches without round-tripping the server. The
/// settings UI binds against these via @AppStorage / direct reads.
///
/// Cap is in bytes (UserDefaults stores it as Int) so the slider can
/// step in megabyte increments without losing the underlying unit.
public enum CachePreferences {
    /// Default cache cap: 100 MB. Picked as the agreed-upon "feels
    /// roomy enough for a year of casual chat history without
    /// noticeable disk pressure" baseline. The user can lower or
    /// raise via General settings.
    public static let defaultCapBytes: Int = 100 * 1024 * 1024

    /// Bounds on the cap slider. The settings UI clamps user input
    /// to this range. 25 MB lower bound is enough to keep one busy
    /// conversation cached; 1 GB upper bound covers the long tail
    /// before "you should be using a real database" applies.
    public static let minCapBytes: Int = 25 * 1024 * 1024
    public static let maxCapBytes: Int = 1024 * 1024 * 1024

    private static let capKey = "spalt.cache.capBytes"

    /// Resolved cache cap. Reads the user-set value if present;
    /// otherwise the default. Always returns a value in range
    /// [minCapBytes, maxCapBytes] (a corrupt UserDefaults entry
    /// from an older build clamps cleanly).
    public static var capBytes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: capKey)
            if stored == 0 { return defaultCapBytes }
            return min(max(stored, minCapBytes), maxCapBytes)
        }
        set {
            let clamped = min(max(newValue, minCapBytes), maxCapBytes)
            UserDefaults.standard.set(clamped, forKey: capKey)
        }
    }
}
