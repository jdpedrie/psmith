import SwiftUI
import ReeveKit

/// Root shell that decides between the regular RootView (when
/// there's an active account) and the unified `LoginView` (when
/// there isn't — fresh install or last account was removed).
///
/// Injects the active AppModel into the env so existing views
/// keep reading `@Environment(AppModel.self) private var app`
/// without changes. Identifying the AppModel by id forces SwiftUI
/// to rebuild the entire tree when the active account swaps —
/// which is what we want, because every per-account VM (providers,
/// profiles, streamHub) is owned by the AppModel and shouldn't
/// leak across identity boundaries.
struct AppShell: View {
    @Bindable var accountManager: AccountManager

    var body: some View {
        if let app = accountManager.active {
            RootView()
                .environment(app)
                .id(app.accountID ?? UUID())
        } else {
            // Cold start (or last account just removed): no active
            // account. LoginView with no preselected host walks the
            // user through server probe + credentials and calls
            // `accountManager.addAccount`, which becomes the first
            // persisted account and makes itself active.
            LoginView()
        }
    }
}
