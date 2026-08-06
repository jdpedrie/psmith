import SwiftUI
import PsmithKit

/// Top-level dispatcher for a message's `[PsmithUIFragment]` list.
/// Iterates the fragments in order and routes each one to its
/// per-component renderer in this directory. Used by `MessageRow`
/// and friends in place of the markdown body when the server
/// supplied any fragments.
///
/// New components plug in by:
///   1. Adding a SwiftUI view in this directory.
///   2. Adding a case to the switch in `bodyFor`.
///   3. Documenting the Props schema in
///      `plugins/CONTENT_RENDERERS.md`.
///
/// Unknown components fall back to a small `RawJSONRenderer` so
/// a server running ahead of the client surfaces SOMETHING in
/// the bubble rather than a silent gap.
public struct FragmentView: View {
    let fragments: [PsmithUIFragment]
    /// Action handler for interactive components. nil disables
    /// every action — interactive renderers (`choice_list`)
    /// then render in display-only mode.
    let onAction: ((FragmentAction) -> Void)?

    public init(
        fragments: [PsmithUIFragment],
        onAction: ((FragmentAction) -> Void)? = nil
    ) {
        self.fragments = fragments
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(fragments.enumerated()), id: \.offset) { _, fragment in
                bodyFor(fragment)
            }
        }
    }

    @ViewBuilder
    private func bodyFor(_ fragment: PsmithUIFragment) -> some View {
        switch fragment.component {
        case "text":
            TextRenderer(fragment: fragment)
        case "card_list":
            CardListRenderer(fragment: fragment, onAction: onAction)
        case "choice_list":
            ChoiceListRenderer(fragment: fragment, onAction: onAction)
        case "key_value":
            KeyValueRenderer(fragment: fragment)
        case "image":
            ImageRenderer(fragment: fragment)
        case "image_grid":
            ImageGridRenderer(fragment: fragment)
        case "error":
            ErrorRenderer(fragment: fragment)
        case "raw_json":
            RawJSONRenderer(fragment: fragment)
        default:
            // Server is ahead of the client: surface the raw
            // payload as a code block so the user sees content
            // (not silence) and can report what's missing.
            UnknownComponentRenderer(fragment: fragment)
        }
    }
}

/// Decoded action that an interactive component can fire. The
/// `onAction` handler is responsible for routing each case to the
/// right place — usually the active `ConversationViewModel`.
public enum FragmentAction: Sendable, Hashable {
    /// Drop a string into the composer for the user to send.
    case compose(String)
    /// Drop a string into the composer AND immediately submit it
    /// as a user message. Used by `choice_list` so tapping a button
    /// resolves the decision in one click instead of two (tap →
    /// edit-if-needed → press Send).
    case send(String)
    /// Open a URL externally (link-safety check applies on the
    /// host's side before dispatch).
    case external(URL)
    /// Send an action back to the plugin that rendered the fragment.
    ///
    /// The other cases all terminate in the client, which meant nothing
    /// could carry intent back to the plugin that drew the UI — a panel
    /// could show state but never change it. The host routes this to
    /// InvokePluginAction against the owning plugin.
    case plugin(action: String, params: [String: String])
    // Future: nav(conversationID), etc.
    // Add new cases as renderer components grow new actions.
}

/// Parses the action grammar documented in
/// `plugins/CONTENT_RENDERERS.md` into a `FragmentAction`.
/// Returns nil for malformed or unrecognised actions; callers
/// silently ignore those so a renderer can't fire something the
/// client doesn't understand.
///
/// Recognised forms:
///   - `compose:<text>`     — drop `<text>` into the composer
///   - `send:<text>`        — drop into composer + auto-submit
///   - `external:<url>`     — open `<url>` externally
///   - `plugin:<action>?<k>=<v>` — dispatch back to the rendering plugin
public enum FragmentActionParser {
    public static func parse(_ raw: String) -> FragmentAction? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let scheme = String(raw[..<colon])
        let value = String(raw[raw.index(after: colon)...])
        switch scheme {
        case "compose":
            return .compose(value)
        case "send":
            return .send(value)
        case "external":
            guard let url = URL(string: value) else { return nil }
            return .external(url)
        case "plugin":
            // `<action>?<k>=<v>&…`. The action name is the load-bearing
            // half; a malformed query yields no params rather than
            // discarding the action, so the plugin reports a clear error
            // instead of the tap doing nothing.
            let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            var params: [String: String] = [:]
            if parts.count == 2,
               var comps = URLComponents(string: "?" + parts[1]) {
                comps.scheme = nil
                for item in comps.queryItems ?? [] {
                    params[item.name] = item.value ?? ""
                }
            }
            return .plugin(action: String(name), params: params)
        default:
            return nil
        }
    }
}
