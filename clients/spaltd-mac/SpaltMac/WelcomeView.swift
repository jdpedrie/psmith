import SwiftUI
import SpaltKit
import SpaltUI

/// Detail-pane home shown when nothing is selected. Mirrors the layout
/// shape of `EmptyStateView` (the original placeholder) so it doesn't
/// disrupt the parent NavigationSplitView's size negotiation, but adds
/// a prominent "New Conversation" button.
struct WelcomeView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ConversationsModel.self) private var convos

    private var canCreateConversation: Bool {
        convos.profiles.contains(where: { !$0.parentOnly })
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Welcome to Spalt")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(canCreateConversation
                 ? "Start a new conversation, or pick one from the sidebar."
                 : "Add a profile in Settings to start your first conversation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                navigator.composingNewConversation = true
            } label: {
                Label("New Conversation", systemImage: "plus.bubble")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .disabled(!canCreateConversation)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}
