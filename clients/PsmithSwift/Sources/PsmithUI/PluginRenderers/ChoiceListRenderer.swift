import SwiftUI
import PsmithKit

/// Renderer for `component == "choice_list"` — a vertical stack
/// of tappable buttons. Driven by `lettered_choices` (or any
/// future plugin that wants to offer pickable options inline).
///
/// Props schema:
/// ```json
/// {
///   "items": [
///     {"label": "Attack", "value": "A", "action": "compose:A"}
///   ]
/// }
/// ```
///
/// Each item's `action` is a string in the action vocabulary
/// (see `plugins/CONTENT_RENDERERS.md`). Items without an action
/// render as static text rows; items with an action become
/// buttons. When `onAction` is nil (display-only context),
/// everything renders as static rows.
public struct ChoiceListRenderer: View {
    let fragment: PsmithUIFragment
    let onAction: ((FragmentAction) -> Void)?

    public init(fragment: PsmithUIFragment, onAction: ((FragmentAction) -> Void)?) {
        self.fragment = fragment
        self.onAction = onAction
    }

    private struct Props: Decodable {
        struct Item: Decodable, Hashable {
            let label: String
            let value: String?
            let action: String?
        }
        let items: [Item]
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(props?.items ?? [], id: \.self) { item in
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Props.Item) -> some View {
        if let actionRaw = item.action,
           let parsed = FragmentActionParser.parse(actionRaw),
           let onAction {
            Button {
                onAction(parsed)
            } label: {
                Text(item.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        } else {
            Text(item.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
