import PsmithKit
import SwiftUI

/// Renders a plugin-contributed panel.
///
/// Deliberately knows nothing about any plugin. It fetches fragments, draws
/// them with the same `FragmentView` the transcript uses, and routes taps back
/// through `plugin:` actions. Adding a plugin with a panel requires no change
/// here and none in either app: the menu entry comes from the plugin
/// descriptor, the body comes from the server as fragments, and the action
/// vocabulary is fixed.
///
/// The trade is that a panel can only express what the fragment vocabulary can
/// express. That is intended. A plugin that needs something new is an argument
/// for growing the vocabulary — which every plugin then gets — rather than for
/// compiling a bespoke form into every client.
@MainActor
public struct PluginPanelSheet: View {
    private let pluginName: String
    private let panel: PsmithPluginPanel
    private let conversationID: String
    private let client: PsmithClient
    private let onCompose: ((String) -> Void)?

    @State private var fragments: [PsmithUIFragment] = []
    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        /// Held separately from `.ready` so a failed action does not blank a
        /// panel the user can still read.
        case failed(String)
    }

    public init(
        pluginName: String,
        panel: PsmithPluginPanel,
        conversationID: String,
        client: PsmithClient,
        onCompose: ((String) -> Void)? = nil
    ) {
        self.pluginName = pluginName
        self.panel = panel
        self.conversationID = conversationID
        self.client = client
        self.onCompose = onCompose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !panel.subtitle.isEmpty {
                        Text(panel.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if case .failed(let message) = phase {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    switch phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case .ready, .failed:
                        if fragments.isEmpty {
                            // A panel with nothing in it is a normal state —
                            // no packs configured, no items yet — not an error.
                            Text("Nothing here yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            // FragmentView takes the whole list: it owns the
                            // spacing and grouping between parts.
                            FragmentView(fragments: fragments, onAction: handle)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(panel.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            fragments = try await client.conversations.pluginPanel(
                conversationID: conversationID,
                pluginName: pluginName
            )
            phase = .ready
        } catch {
            phase = .failed(PsmithError.display(error))
        }
    }

    /// Routes a fragment action.
    ///
    /// `plugin:` actions go back to the plugin and replace the panel with what
    /// it returns. `compose:` is forwarded to the composer and dismisses,
    /// since a panel that stayed open over a filled composer would hide the
    /// thing the user is about to send. Everything else is a client-terminal
    /// verb the fragment renderer already handles.
    private func handle(_ action: FragmentAction) {
        switch action {
        case .compose(let text):
            onCompose?(text)
            dismiss()
        case .plugin(let name, let params):
            Task { await invoke(name, params) }
        default:
            break
        }
    }

    private func invoke(_ action: String, _ params: [String: String]) async {
        do {
            // The server returns the re-rendered panel, so state and view move
            // together instead of the view flashing stale between two calls.
            fragments = try await client.conversations.invokePluginAction(
                conversationID: conversationID,
                pluginName: pluginName,
                action: action,
                params: params
            )
            phase = .ready
        } catch {
            phase = .failed(PsmithError.display(error))
        }
    }
}
