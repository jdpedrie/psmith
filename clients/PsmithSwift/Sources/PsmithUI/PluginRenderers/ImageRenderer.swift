import SwiftUI
import PsmithKit

/// Renderer for `component == "image"` — a single inline image,
/// loaded from a URL. Used by plugins that surface server-hosted
/// or web-fetched media without going through the file-attachment
/// pipeline (e.g. an inline preview for a cited image).
///
/// Props schema:
/// ```json
/// {
///   "url": "https://…",
///   "alt": "optional alt text",
///   "caption": "optional below-image caption"
///  }
/// ```
public struct ImageRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    public struct Props: Decodable {
        let url: String
        let alt: String?
        let caption: String?
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        if let urlString = props?.url, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 80)
                    case .success(let img):
                        img.resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    case .failure:
                        Text(props?.alt ?? "Image failed to load")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
                .accessibilityLabel(props?.alt ?? "")
                if let caption = props?.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Renderer for `component == "image_grid"` — multiple inline
/// images in an adaptive grid. Same per-item shape as `ImageRenderer`.
public struct ImageGridRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    struct Props: Decodable {
        let items: [ImageRenderer.Props]
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        let items = props?.items ?? []
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 6)],
            spacing: 6
        ) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                AsyncImage(url: URL(string: item.url)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 160)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    default:
                        Color.gray.opacity(0.1)
                            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 160)
                            .overlay(ProgressView())
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .accessibilityLabel(item.alt ?? "")
            }
        }
    }
}
