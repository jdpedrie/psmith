import SwiftUI
import PsmithKit

/// Renderer for `component == "card_list"` — a vertical stack of
/// content cards. The motivating use case is search results
/// (Brave Search, future RAG retrievals) where a flat markdown
/// list buries the title + URL + snippet in a wall of text.
///
/// Props schema:
/// ```json
/// {
///   "items": [
///     {
///       "title": "…",
///       "description": "optional summary",
///       "url": "https://…",       // optional; renders as an external link
///       "image": "https://…",     // optional thumbnail
///       "badges": ["news", "2026"], // optional pill labels
///       "action": "plugin:arm?id=x"  // optional; makes the whole row tappable
///     }
///   ]
/// }
/// ```
public struct CardListRenderer: View {
    let fragment: PsmithUIFragment
    let onAction: ((FragmentAction) -> Void)?

    public init(fragment: PsmithUIFragment, onAction: ((FragmentAction) -> Void)?) {
        self.fragment = fragment
        self.onAction = onAction
    }

    private struct Props: Decodable {
        struct Item: Decodable, Hashable {
            let title: String
            let description: String?
            let url: String?
            let image: String?
            let badges: [String]?
            /// Optional action fired by tapping the whole card. Distinct from
            /// `url`, which is a link affordance in the corner: this makes the
            /// row itself the control, which is what a card_list used as a
            /// picker needs.
            let action: String?
        }
        let items: [Item]
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(props?.items ?? [], id: \.self) { item in
                if let raw = item.action, let parsed = FragmentActionParser.parse(raw) {
                    Button {
                        onAction?(parsed)
                    } label: {
                        card(item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                } else {
                    // No action: a static row, which is also how a card
                    // signals "nothing left to do here" without the renderer
                    // needing to know what that means.
                    card(item)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ item: Props.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .scaledFont(.callout, weight: .semibold)
                    .lineLimit(2)
                Spacer()
                if let urlString = item.url, let url = URL(string: urlString) {
                    Button {
                        onAction?(.external(url))
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(urlString)
                }
            }
            if let badges = item.badges, !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .scaledFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
