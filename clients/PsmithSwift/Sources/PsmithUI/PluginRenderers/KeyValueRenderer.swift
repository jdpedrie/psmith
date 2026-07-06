import SwiftUI
import PsmithKit

/// Renderer for `component == "key_value"` — a definition-list of
/// stat-style key/value pairs. Useful for plugins that surface
/// structured factoids: weather summary, build status, profile
/// snapshot, system stats, etc.
///
/// Accepts either of two props shapes — the flat object is what
/// LLMs naturally emit when told "output as key-value pairs"; the
/// wrapped form is here for back-compat with the original spec.
///
/// Flat object (preferred — what models actually emit):
/// ```json
/// { "Location": "Brooklyn", "Temperature": "62°F" }
/// ```
///
/// Wrapped form (back-compat):
/// ```json
/// {
///   "pairs": [
///     {"key": "Location", "value": "Brooklyn"},
///     {"key": "Temperature", "value": "62°F"}
///   ]
/// }
/// ```
///
/// When the body is neither shape, the renderer emits an empty
/// definition list rather than crashing — keeps the bubble visible
/// while making the failure debuggable via the message inspector.
public struct KeyValueRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    /// Ordered (key, value) extracted from either props shape.
    /// `Hashable` for `ForEach` identity by content.
    private struct Pair: Hashable {
        let key: String
        let value: String
    }

    public var body: some View {
        let pairs = parsePairs(from: fragment.props)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pairs, id: \.self) { pair in
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

    /// Try wrapped form first (explicit `pairs` array), then fall
    /// back to the flat-object form. Either may produce an empty
    /// list — the view handles that gracefully.
    private func parsePairs(from data: Data) -> [Pair] {
        // Wrapped: `{"pairs": [{"key": "...", "value": "..."}, ...]}`.
        struct Wrapped: Decodable {
            struct Entry: Decodable { let key: String; let value: String }
            let pairs: [Entry]
        }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data) {
            return w.pairs.map { Pair(key: $0.key, value: $0.value) }
        }
        // Flat: `{"Location": "...", "Time": "..."}`. Decoded via
        // JSONSerialization since we need to preserve the source
        // order — JSONDecoder into [String: String] would alphabetize
        // and the model's key order is meaningful for a scene header.
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return [] }

        // JSONSerialization returns NSDictionary for objects; we read
        // its key/value pairs in encounter order. Foundation's
        // NSDictionary preserves insertion order on parse since the
        // underlying NSJSONReader walks the source linearly.
        if let dict = raw as? NSDictionary {
            var out: [Pair] = []
            out.reserveCapacity(dict.count)
            dict.enumerateKeysAndObjects { k, v, _ in
                guard let key = k as? String else { return }
                let value: String
                switch v {
                case let s as String:        value = s
                case let n as NSNumber:      value = n.stringValue
                case is NSNull:              value = ""
                default:
                    // Fall back to a JSON-serialised representation
                    // so nested objects / arrays surface as something
                    // (rather than vanishing into "").
                    if let bytes = try? JSONSerialization.data(withJSONObject: v, options: []),
                       let s = String(data: bytes, encoding: .utf8) {
                        value = s
                    } else {
                        value = "\(v)"
                    }
                }
                out.append(Pair(key: key, value: value))
            }
            return out
        }
        return []
    }
}
