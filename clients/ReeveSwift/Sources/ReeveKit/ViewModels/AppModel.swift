import Foundation
import Observation

/// Top-level app state: holds the auth state and a configured ReeveClient.
/// Reusable across macOS / iOS — host apps inject the desired host URL and
/// token store via the explicit init, or use the convenience init that picks
/// sensible defaults (FileTokenStore + REEVE_HOST env override).
@Observable
@MainActor
public final class AppModel {
    public let authState: AuthState
    public let client: ReeveClient
    /// The URL this AppModel's client was built against. Surfaced so the
    /// LoginView can show "logging into ${serverURL}" and so a "change
    /// server" affordance can compare against the persisted store.
    public let serverURL: URL

    /// Settings-tab view models held eagerly so SettingsView never has to
    /// wait for them to materialise (which causes a visible layout flash).
    public let providers: ProvidersViewModel
    public let profiles: ProfilesViewModel

    /// Tracks reachability of `serverURL`. Composer reads this to
    /// disable Send when the server is unreachable; banners read it
    /// to surface a "viewing cached data" notice.
    public let connectivity: ConnectivityMonitor

    public init(host: URL, tokenStore: TokenStore, authState: AuthState = .init()) {
        self.authState = authState
        self.serverURL = host
        // Cache is best-effort: if SwiftData can't bring up the
        // store (corrupt file, sandbox issue), the client falls
        // back to network-only — no offline reads, but the app
        // otherwise works. We log so the failure is debuggable.
        let cache: ReeveCache?
        do {
            cache = try ReeveCache()
        } catch {
            NSLog("ReeveCache init failed: \(error). Running without on-device cache.")
            cache = nil
        }
        let c = ReeveClient(host: host, tokenStore: tokenStore, authState: authState, cache: cache)
        self.client = c
        self.providers = ProvidersViewModel(client: c)
        self.profiles = ProfilesViewModel(client: c)
        self.connectivity = ConnectivityMonitor(host: host)
    }

    /// Default factory: pulls the URL from `ServerURLStore` (which falls
    /// through to REEVE_HOST env, then http://127.0.0.1:8080) and uses a
    /// FileTokenStore. Falls back to an in-memory token store if the
    /// file store can't be initialized.
    public convenience init() {
        let host = ServerURLStore.shared.current
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
        // `restoreSession()` flips phase to `.signedIn` on success and on
        // cached-restore under transport failure. The "no token" + "dead
        // token" paths leave it untouched, so we have to push the
        // transition to `.signedOut` ourselves — otherwise the
        // interstitial would persist forever for fresh installs.
        if authState.phase == .resolving {
            authState.clear()
        }
        connectivity.start()
    }
}
