import Foundation
import Observation

/// Persists the chosen psmithd server URL across app launches via
/// UserDefaults. Mirrors the ThemeStore pattern: process-wide shared
/// instance, idempotent set, simple read.
///
/// The URL the app actually uses on a given launch is resolved by:
///   1. Persisted value here, if set.
///   2. PSMITH_HOST environment variable (kept for parity with the
///      previous AppModel default — useful for dev runs that need to
///      override without touching the prefs).
///   3. http://127.0.0.1:8080 (the local-dev default).
///
/// `@Observable` so the App layer can `.onChange(of:)` the current URL
/// and rebuild AppModel when the user picks a new server.
@Observable
@MainActor
public final class ServerURLStore {
    public static let shared = ServerURLStore()

    private static let defaultsKey = "psmith.server.url"

    /// Currently-active server URL. Setting it persists immediately to
    /// UserDefaults so the next launch starts there. Owners that need
    /// to react to the change should call `AppModel(host:)` and swap
    /// instances — this store doesn't notify observers.
    public var current: URL {
        didSet {
            UserDefaults.standard.set(current.absoluteString, forKey: Self.defaultsKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let url = URL(string: saved) {
            self.current = url
        } else if let env = ProcessInfo.processInfo.environment["PSMITH_HOST"],
                  let url = URL(string: env) {
            self.current = url
        } else {
            self.current = URL(string: "http://127.0.0.1:8080")!
        }
    }

    /// Forget any persisted URL. The next launch will fall back through
    /// the resolution chain (env → default). Used by "Change server"
    /// flows that want to start from a clean slate.
    public func reset() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        // Reload from the resolution chain.
        if let env = ProcessInfo.processInfo.environment["PSMITH_HOST"],
           let url = URL(string: env) {
            self.current = url
        } else {
            self.current = URL(string: "http://127.0.0.1:8080")!
        }
    }
}
