import SwiftUI
import Observation

/// Top-level iOS-side navigation state. iPhone has no tab bar — the
/// conversation list is the root and Settings is a sheet from the
/// account menu. This type carries the cross-screen one-shot signals
/// notification taps + sheet jumps need; it does not own the visible
/// chrome.
///
/// Usage:
///   - **Notification tap** (`iOSNotifier.userNotificationCenter`): set
///     `pendingConversationSelection = convID`. `ChatsRoot.onChange`
///     consumes the pending id by appending the matching conversation
///     onto its NavigationPath, then clears the pending value.
///   - **Open Profile in Settings** (from a sheet's profile-picker
///     callback): set `pendingProfileSelection = id`. ChatsRoot opens
///     the Settings sheet; `ProfilesListView` inside the sheet reads
///     + clears the value and pushes the profile.
///
/// Module-level shared instance lives at the bottom so module-scope
/// helpers (notifier construction in particular) can reach it without
/// threading it through every call site.
@Observable
@MainActor
final class iOSNavigator {
    /// One-shot signal — set by `iOSNotifier` when the user taps a
    /// "your reply is ready" notification. `ChatsRoot` consumes
    /// (clears) it by appending the matching conversation onto its
    /// NavigationPath. Paired set+clear so a stale value can't fire
    /// twice.
    var pendingConversationSelection: String?

    /// One-shot signal — set when a sheet wants to send the user into
    /// Settings → Profiles → a specific profile. Used by the "Open in
    /// Settings" affordance attached to `ProfilePickerRow` and
    /// similar. ChatsRoot opens the Settings sheet; `ProfilesListView`
    /// reads + clears the id and pushes.
    var pendingProfileSelection: String?
}

@MainActor
let sharedIOSNavigator = iOSNavigator()
