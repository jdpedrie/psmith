import SwiftUI
import ReeveUI

enum AppMode: Hashable {
    case chats
    case settings
}

/// Top-level navigation state shared between HomeView and the menu/Commands
/// layer. Exposing this via @Environment lets the Cmd+, menu item flip into
/// settings mode without having to reach into HomeView's @State.
@Observable
@MainActor
final class Navigator {
    var mode: AppMode = .chats

    /// While true, the chats shell's detail pane shows `NewConversationView`
    /// instead of the regular conversation. Replaces the old popover.
    var composingNewConversation: Bool = false

    /// One-shot signal: when set, the settings shell should switch to the
    /// Profiles category and select the named profile. Cleared by whoever
    /// reads it to keep the request idempotent.
    var pendingProfileSelection: String?

    /// One-shot signal: when set, HomeView should switch to chats mode
    /// and select the named conversation. Set by MacNotifier when the
    /// user clicks a "reply ready" notification. Cleared by HomeView
    /// after consumption.
    var pendingConversationSelection: String?

    /// Called by ProfileCard's gear button. Switches mode to settings and
    /// stashes the profile ID for SettingsView to consume on appear.
    func openProfileSettings(id: String) {
        pendingProfileSelection = id
        mode = .settings
    }
}

/// Shared instance used by both the SwiftUI environment and the menu
/// Commands modifier (which can't read a view-local @State).
@MainActor
let sharedNavigator = Navigator()

enum SettingsCategory: Hashable, CaseIterable, Identifiable {
    case providers
    case profiles
    case plugins
    case appearance
    case notifications
    case langfuse

    var label: String {
        switch self {
        case .providers:     return "Providers"
        case .profiles:      return "Profiles"
        case .plugins:       return "Plugins"
        case .appearance:    return "Appearance"
        case .notifications: return "Notifications"
        case .langfuse:      return "Langfuse"
        }
    }

    var systemImage: String {
        switch self {
        case .providers:     return "cpu"
        case .profiles:      return "person.crop.rectangle"
        case .plugins:       return "puzzlepiece.extension"
        case .appearance:    return "paintpalette"
        case .notifications: return "bell"
        case .langfuse:      return "chart.line.uptrend.xyaxis"
        }
    }

    /// Ordering categories into top-level "data" entries (the user's
    /// configured providers / profiles / plugins they actually USE) vs
    /// app-level "settings" entries (preferences about the app itself).
    /// The sidebar renders the data ones first, then a SETTINGS header,
    /// then the settings ones — gives the visual hierarchy without
    /// needing a tree-style sidebar widget.
    var isAppSettings: Bool {
        switch self {
        case .appearance, .notifications, .langfuse: return true
        default: return false
        }
    }

    var id: Self { self }
}

/// Sub-section selectors for the app-settings categories. The Settings
/// shell's middle pane lists these for the active category; the detail
/// pane shows the selected one's content. Lets us actually USE the
/// middle pane on Appearance / Notifications instead of leaving it
/// empty.
enum AppearanceSection: Hashable, CaseIterable, Identifiable {
    case theme

    var label: String {
        switch self {
        case .theme: return "Theme"
        }
    }
    var systemImage: String {
        switch self {
        case .theme: return "paintpalette"
        }
    }
    var id: Self { self }
}

enum NotificationsSection: Hashable, CaseIterable, Identifiable {
    case generationFinished

    var label: String {
        switch self {
        case .generationFinished: return "Generation finished"
        }
    }
    var systemImage: String {
        switch self {
        case .generationFinished: return "bell.badge"
        }
    }
    var id: Self { self }
}
