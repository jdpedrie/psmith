import SwiftUI
import PsmithKit

/// Renderer for `component == "error"` — a typed inline error
/// callout. Plugins that produce structured failures (a search
/// API returning 429, a malformed tool result) emit one of these
/// instead of dropping a raw error string into the message body.
///
/// Props schema:
/// ```json
/// {
///   "message": "Brave Search rate limit exceeded.",
///   "code": "429",                  // optional
///   "retry": "compose:retry search" // optional FragmentAction
/// }
/// ```
public struct ErrorRenderer: View {
    let fragment: PsmithUIFragment

    public init(fragment: PsmithUIFragment) {
        self.fragment = fragment
    }

    private struct Props: Decodable {
        let message: String
        let code: String?
        let retry: String?
    }

    public var body: some View {
        let props = (try? JSONDecoder().decode(Props.self, from: fragment.props))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(props?.message ?? "Plugin reported an error.")
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let code = props?.code, !code.isEmpty {
                    Text(code)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
