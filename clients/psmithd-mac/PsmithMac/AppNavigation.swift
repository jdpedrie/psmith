import SwiftUI
import PsmithUI

enum InspectorTab: String, CaseIterable, Identifiable, Hashable {
    case context = "Context"
    case settings = "Settings"
    case plugins = "Plugins"
    var id: Self { self }
}

/// What the reading column can show instead of the transcript. Pages
/// replace the sheets the window used to open: a breadcrumb leads back.
enum ConversationPage: Equatable {
    case models
    case callSettings
    case fullText(title: String, markdown: String)
    case image(messageID: String, fileID: String, filename: String)
}

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

    /// The Settings pane on screen, kept across visits.
    var settingsCategory: SettingsCategory = .models
    /// The tab a profile opens on in the Profiles pane.
    var settingsProfileTab: SettingsProfileTab = .general
    /// The tab a provider opens on in the Models pane.
    var settingsProviderTab: SettingsProviderTab = .models
    /// Which integration the Integrations pane shows.
    var settingsIntegration: SettingsIntegration = .langfuse

    /// The conversation inspector, open or not and on which tab. Here,
    /// not per conversation, so it stays put while the user moves between
    /// conversations.
    var inspectorShown = false
    var inspectorTab: InspectorTab = .context

    /// A page open in the reading column in place of the transcript
    /// (all models, call settings, a long reply, an image). Cleared when
    /// another conversation opens.
    var page: ConversationPage?

    /// The conversation list column. Here so the View menu command and
    /// the toolbar buttons drive one value.
    var listShown = true

    /// The new conversation on screen, if any. It exists only on this
    /// Mac until its first send creates it on the server; `createdID`
    /// is set then, and the same screen carries on as that conversation.
    var draft: DraftRoute?

    struct DraftRoute: Equatable {
        let key = UUID()
        var createdID: String?
    }

    /// "+", ⌘N, and the welcome screen's button all land here.
    func startNewConversation() {
        mode = .chats
        draft = DraftRoute()
    }

    /// One-shot signal: when set, the settings shell should switch to the
    /// Profiles category and select the named profile. Cleared by whoever
    /// reads it to keep the request idempotent.
    var pendingProfileSelection: String?

    /// One-shot signal: when set, HomeView should switch to chats mode
    /// and select the named conversation. Set by MacNotifier when the
    /// user clicks a "reply ready" notification. Cleared by HomeView
    /// after consumption.
    var pendingConversationSelection: String?

    /// Opens the Settings window. Set by HomeView from SwiftUI's
    /// `openSettings` action, which only views can read.
    var openSettingsWindow: (() -> Void)?

    /// Set by the main window's "Add Account…": Settings opens Accounts
    /// already adding one. The Accounts pane clears it when it takes it.
    var settingsAddingAccount = false

    func showAddAccount() {
        settingsAddingAccount = true
        showSettings(.accounts)
    }

    /// Settings, on a category.
    func showSettings(_ category: SettingsCategory) {
        settingsCategory = category
        openSettingsWindow?()
    }

    /// Called by ProfileCard's gear button: Settings, on that profile.
    func openProfileSettings(id: String) {
        pendingProfileSelection = id
        showSettings(.profiles)
    }
}

/// Shared instance used by both the SwiftUI environment and the menu
/// Commands modifier (which can't read a view-local @State).
@MainActor
let sharedNavigator = Navigator()

/// The Settings window's panes, in toolbar order.
enum SettingsCategory: Hashable, CaseIterable, Identifiable {
    case general
    case appearance
    case accounts
    case models
    case profiles
    case plugins
    case servers
    case usage
    case integrations

    var label: String {
        switch self {
        case .general:      return "General"
        case .appearance:   return "Appearance"
        case .accounts:     return "Accounts"
        case .models:       return "Models"
        case .profiles:     return "Profiles"
        case .plugins:      return "Plugins"
        case .servers:      return "Servers"
        case .usage:        return "Usage"
        case .integrations: return "Integrations"
        }
    }

    var systemImage: String {
        switch self {
        case .general:      return "gearshape"
        case .appearance:   return "circle.lefthalf.filled"
        case .accounts:     return "person.2"
        case .models:       return "cpu"
        case .profiles:     return "person.crop.circle"
        case .plugins:      return "puzzlepiece.extension"
        case .servers:      return "server.rack"
        case .usage:        return "chart.bar"
        case .integrations: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var id: Self { self }
}

enum SettingsProviderTab: Hashable { case models, connection, defaults }

enum SettingsProfileTab: Hashable { case general, prompt, model, plugins, automation }

/// The Integrations pane's list: services Psmith talks to beyond the
/// chat providers.
enum SettingsIntegration: Hashable, CaseIterable, Identifiable {
    case langfuse
    case embedder
    case speech
    case deviceTools

    var label: String {
        switch self {
        case .langfuse:    return "Langfuse"
        case .embedder:    return "Embedder"
        case .speech:      return "Speech"
        case .deviceTools: return "Device tools"
        }
    }

    var detail: String {
        switch self {
        case .langfuse:    return "Tracing and cost"
        case .embedder:    return "Memory search"
        case .speech:      return "Read replies aloud"
        case .deviceTools: return "Calendar, reminders, notes"
        }
    }

    var systemImage: String {
        switch self {
        case .langfuse:    return "chart.line.uptrend.xyaxis"
        case .embedder:    return "point.3.connected.trianglepath.dotted"
        case .speech:      return "speaker.wave.2"
        case .deviceTools: return "wrench.and.screwdriver"
        }
    }

    var id: Self { self }
}
