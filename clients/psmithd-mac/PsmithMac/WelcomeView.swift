import SwiftUI
import PsmithKit
import PsmithUI

/// The reading pane with nothing open (board AppWelcome).
struct WelcomeView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ConversationsModel.self) private var convos

    private var canCreateConversation: Bool {
        convos.profiles.contains(where: { !$0.parentOnly })
    }

    var body: some View {
        VStack(spacing: 0) {
            MKDetailHeader(title: "", divider: false)
            VStack(spacing: 0) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(SK.tertiary)
                    .frame(height: 40)
                Text("Nothing open").sk(15, SK.secondary, weight: .semibold).padding(.top, 12)
                Text(canCreateConversation
                     ? "Pick a conversation, or start a new one."
                     : "Add a profile in Settings to start your first conversation.")
                    .sk(12.5, SK.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                if canCreateConversation {
                    Button {
                        navigator.startNewConversation()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.bubble").font(.system(size: 11.5, weight: .medium))
                            Text("New Conversation")
                        }
                    }
                    .skButton(.primary)
                    .padding(.top, 16)
                    Text("⌘N").sk(11.5, SK.tertiary).padding(.top, 12)
                } else {
                    Button("Open Profiles Settings") { navigator.showSettings(.profiles) }
                        .skButton(.primary)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 52)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
