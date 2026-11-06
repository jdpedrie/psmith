import Foundation
import Observation

/// The signed-in user's synced preferences. Held on AppModel for the
/// session; screens read `preferences` and write through the setters.
@Observable
@MainActor
public final class PreferencesViewModel {
    private let client: PsmithClient

    /// Defaults until the first load lands, so readers never wait.
    public private(set) var preferences = PsmithUserPreferences.defaults
    public private(set) var hasLoaded = false
    public var error: String?

    public init(client: PsmithClient) {
        self.client = client
    }

    /// The last cached copy first (instant, and all there is offline),
    /// then the server's.
    public func load() async {
        if !hasLoaded, let cached = await client.preferences.cachedGet() {
            preferences = cached
        }
        do {
            preferences = try await client.preferences.get()
            hasLoaded = true
            error = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Optimistic: the screen shows the new value at once and rolls
    /// back if the write fails, since a settings control that snaps
    /// back after a round-trip reads as broken.
    public func setContextWarningTokens(_ tokens: Int32) async {
        let previous = preferences
        preferences.contextWarningTokens = tokens
        do {
            preferences = try await client.preferences.update(contextWarningTokens: tokens)
            error = nil
        } catch {
            preferences = previous
            self.error = PsmithError.display(error)
        }
    }
}

/// What the composer's context chip shows, if anything.
public enum ContextWarning: Equatable, Sendable {
    /// Past the user's threshold.
    case overThreshold(tokens: Int32)
    /// Near the model's own context window. Shown whatever the user's
    /// threshold, including when it's off: running out of window is a
    /// failure, not a preference.
    case nearWindow(tokens: Int32, window: Int32)

    /// Fraction of the model's window at which `nearWindow` starts.
    public static let windowFraction = 0.9

    /// `threshold` 0 means the user turned the warning off.
    public static func evaluate(tokens: Int32?, threshold: Int32, window: Int32?) -> ContextWarning? {
        guard let tokens, tokens > 0 else { return nil }
        if let window, window > 0, Double(tokens) >= Double(window) * windowFraction {
            return .nearWindow(tokens: tokens, window: window)
        }
        if threshold > 0, tokens >= threshold {
            return .overThreshold(tokens: tokens)
        }
        return nil
    }

    public var tokens: Int32 {
        switch self {
        case .overThreshold(let t), .nearWindow(let t, _): return t
        }
    }

    /// "82k", "1.2M": the chip's compact form.
    public static func compact(_ tokens: Int32) -> String {
        let n = Double(tokens)
        if n >= 1_000_000 {
            return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", n / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: n >= 10_000 ? "%.0fk" : "%.1fk", n / 1_000)
        }
        return "\(tokens)"
    }
}
