import SwiftUI
import SpaltKit

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
///       "badges": ["news", "2026"] // optional pill labels
///     }
///   ]
/// }
/// ```
public struct CardListRenderer: View {
    let fragment: SpaltUIFragment
    let onAction: ((FragmentAction) -> Void)?

    public init(fragment: SpaltUIFragment, onAction: ((FragmentAction) -> Void)?) {
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
        }
        let items: [Item]
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(props?.items ?? [], id: \.self) { item in
                card(item)
            }
        }
    }

    @ViewBuilder
    private func card(_ item: Props.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if let urlString = item.url, let url = URL(string: urlString) {
                    Button {
                        onAction?(.external(url))
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(urlString)
                }
            }
            if let badges = item.badges, !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
