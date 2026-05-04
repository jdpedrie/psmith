import SwiftUI

/// Width of the conversation pane (the message ScrollView's outer
/// frame), measured by a `GeometryReader` at the chat shell level and
/// injected into the env so individual bubbles can constrain their
/// width as a fraction of it without each row re-measuring.
///
/// Default `0` means "no measurement available yet" — bubble
/// implementations fall back to a hard cap (~720pt) when this is 0,
/// so the first frame doesn't render edge-to-edge before the
/// GeometryReader settles.
private struct ChatPaneWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var chatPaneWidth: CGFloat {
        get { self[ChatPaneWidthKey.self] }
        set { self[ChatPaneWidthKey.self] = newValue }
    }
}
