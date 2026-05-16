import SwiftUI
import ReeveKit

/// Renderer for `component == "key_value"` — a definition-list of
/// stat-style key/value pairs. Useful for plugins that surface
/// structured factoids: weather summary, build status, profile
/// snapshot, system stats, etc.
///
/// Props schema:
/// ```json
/// {
///   "pairs": [
///     {"key": "Location", "value": "Brooklyn"},
///     {"key": "Temperature", "value": "62°F"}
///   ]
/// }
/// ```
public struct KeyValueRenderer: View {
    let fragment: ReeveUIFragment

    public init(fragment: ReeveUIFragment) {
        self.fragment = fragment
    }

    private struct Props: Decodable {
        struct Pair: Decodable, Hashable {
            let key: String
            let value: String
        }
        let pairs: [Pair]
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(props?.pairs ?? [], id: \.self) { pair in
                HStack(alignment: .firstTextBaseline) {
                    Text(pair.key)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 100, alignment: .leading)
                    Text(pair.value)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
