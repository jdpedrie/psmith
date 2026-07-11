import SwiftUI
import PsmithKit

/// Renderer for `component == "raw_json"` — the explicit fallback
/// for "I have structured data and no dedicated component yet."
/// Renders as a pretty-printed JSON code block.
///
/// Props schema: any JSON value. The renderer pretty-prints it
/// directly.
public struct RawJSONRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    public var body: some View {
        let pretty = prettyJSON(fragment.props) ?? String(data: fragment.props, encoding: .utf8) ?? ""
        ScrollView(.horizontal) {
            Text(pretty)
                .scaledFont(.callout, design: .monospaced)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }
}

/// Fallback for an unknown component name. Surfaces SOMETHING in
/// the bubble so a server running ahead of the client doesn't
/// produce silent gaps in conversations.
public struct UnknownComponentRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unknown component: \(fragment.component)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            RawJSONRenderer(fragment: fragment)
        }
    }
}
