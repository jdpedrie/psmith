import Foundation
import Observation

/// Top-level app state: holds the auth state and a configured ClarkClient.
/// Reusable across macOS / iOS — host apps inject the desired host URL and
/// token store via the explicit init, or use the convenience init that picks
/// sensible defaults (FileTokenStore + CLARK_HOST env override).
@Observable
@MainActor
public final class AppModel {
    public let authState: AuthState
    public let client: ClarkClient

    /// Settings-tab view models held eagerly so SettingsView never has to
    /// wait for them to materialise (which causes a visible layout flash).
    public let providers: ProvidersViewModel
    public let profiles: ProfilesViewModel

    public init(host: URL, tokenStore: TokenStore, authState: AuthState = .init()) {
        self.authState = authState
        let c = ClarkClient(host: host, tokenStore: tokenStore, authState: authState)
        self.client = c
        self.providers = ProvidersViewModel(client: c)
        self.profiles = ProfilesViewModel(client: c)
    }

    /// Default factory: reads `CLARK_HOST` from the environment (falling back
    /// to http://127.0.0.1:8080) and uses a FileTokenStore. Falls back to an
    /// in-memory token store if the file store can't be initialized.
    public convenience init() {
        let host = URL(string: ProcessInfo.processInfo.environment["CLARK_HOST"] ?? "http://127.0.0.1:8080")!
        let tokenStore: TokenStore
        do {
            tokenStore = try FileTokenStore()
        } catch {
            NSLog("FileTokenStore init failed: \(error). Falling back to in-memory.")
            tokenStore = InMemoryTokenStore()
        }
        self.init(host: host, tokenStore: tokenStore, authState: AuthState())
    }

    public func bootstrap() async {
        _ = await client.auth.restoreSession()
    }
}
