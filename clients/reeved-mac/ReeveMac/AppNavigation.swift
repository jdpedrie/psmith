import SwiftUI

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

/// Standardised height for every pane's bottom footer band so the three
/// column footers (categories | list | detail) line up across the whole
/// settings shell.
let paneFooterHeight: CGFloat = 40
let paneHeaderHeight: CGFloat = 36

/// Footer band used at the bottom of every settings pane. Always renders
/// the divider + a fixed-height row, even when there's no content to show
/// (so adjacent columns line up vertically).
struct PaneFooter<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .frame(height: paneFooterHeight, alignment: .center)
                .background(.thinMaterial)
        }
    }
}

/// Notes-style header strip at the top of a settings pane. Title + optional
/// count subtitle on the left, trailing-aligned glass action buttons on the
/// right. Mirrors `PaneFooter` for column alignment across panes.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 14)
            .frame(height: paneHeaderHeight)
            .background(.thinMaterial)
            Divider()
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Tight, restrained empty-state used everywhere in ReeveMac. The platform's
/// `ContentUnavailableView` is too jumbo for our panes — it dominates the
/// layout. This version is small icon + callout title + caption description,
/// fills its container, and supports markdown in the description.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let description: LocalizedStringKey?

    init(_ title: String, systemImage: String, description: LocalizedStringKey? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}

enum SettingsCategory: Hashable, CaseIterable, Identifiable {
    case providers
    case profiles
    case plugins
    case appearance
    case general

    var label: String {
        switch self {
        case .providers:  return "Providers"
        case .profiles:   return "Profiles"
        case .plugins:    return "Plugins"
        case .appearance: return "Appearance"
        case .general:    return "General"
        }
    }

    var systemImage: String {
        switch self {
        case .providers:  return "cpu"
        case .profiles:   return "person.crop.rectangle"
        case .plugins:    return "puzzlepiece.extension"
        case .appearance: return "paintpalette"
        case .general:    return "gearshape"
        }
    }

    var id: Self { self }
}
