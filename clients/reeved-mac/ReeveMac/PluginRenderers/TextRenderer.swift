import SwiftUI
import ReeveKit
import ReeveUI

/// Renderer for `component == "text"` — literal text segments
/// inlined between structured components in the same message.
///
/// Props schema: `{"text": "..."}`. Renders as Markdown via the
/// app's existing `MarkdownText` so headings, lists, code blocks
/// in the segment look identical to the no-fragment fallback path.
struct TextRenderer: View {
    let fragment: ReeveUIFragment

    private struct Props: Decodable {
        let text: String
    }

    var body: some View {
        let props = try? JSONDecoder().decode(Props.self, from: fragment.props)
        if let text = props?.text, !text.isEmpty {
            MarkdownText(text)
        }
    }
}
