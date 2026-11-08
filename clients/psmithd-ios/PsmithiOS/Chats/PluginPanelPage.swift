import SwiftUI
import PsmithKit
import PsmithUI

/// A plugin's panel as a pushed page (the tray lists one tile per
/// panel). The panel is fragments the server renders; the page lists
/// them and routes their actions: compose drops text into the composer
/// and comes back, a plugin action re-renders the panel.
struct PluginPanelPage: View {
    let pluginName: String
    let panel: PsmithPluginPanel
    let conversationID: String
    let client: PsmithClient
    let onCompose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var fragments: [PsmithUIFragment] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !panel.subtitle.isEmpty {
                    Text(panel.subtitle).font(.system(size: 15)).foregroundStyle(IK.secondary)
                }
                if let error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error)
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if fragments.isEmpty {
                    Text("Nothing here yet.").font(.system(size: 15)).foregroundStyle(IK.secondary)
                } else {
                    FragmentView(fragments: fragments, onAction: handle)
                }
            }
            .padding(16)
        }
        .background(theme.chrome.ignoresSafeArea())
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle(panel.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            fragments = try await client.conversations.pluginPanel(conversationID: conversationID, pluginName: pluginName)
        } catch {
            self.error = PsmithError.display(error)
        }
        loading = false
    }

    private func handle(_ action: FragmentAction) {
        switch action {
        case .compose(let text):
            onCompose(text)
            dismiss()
        case .plugin(let name, let params):
            Task {
                do {
                    fragments = try await client.conversations.invokePluginAction(
                        conversationID: conversationID, pluginName: pluginName, action: name, params: params)
                    error = nil
                } catch {
                    self.error = PsmithError.display(error)
                }
            }
        default:
            break
        }
    }
}
