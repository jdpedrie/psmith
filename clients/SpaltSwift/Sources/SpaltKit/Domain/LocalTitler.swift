import Foundation

/// Strategy for generating a conversation title without round-tripping
/// through a cloud LLM. Implementations live in platform-specific targets
/// (e.g. `SpaltMac` wraps Apple's `FoundationModels` framework on macOS 26+);
/// shared trigger logic in `ConversationsModel` calls through this protocol
/// so iOS — when it ships its own on-device implementation — can plug in
/// without touching the view-model path.
public protocol LocalTitler: Sendable {
    /// Snapshot read every time the trigger fires. Implementations should
    /// reflect runtime conditions (Apple Intelligence enabled, model
    /// downloaded, region permits use, etc.). When false, the trigger
    /// silently skips — the conversation stays untitled until the next
    /// open with availability restored, or until the user renames manually.
    var isAvailable: Bool { get }

    /// Produce a short title for the supplied transcript. `guide` is the
    /// resolved profile's `title_guide` string; implementations may fold
    /// it into the prompt or ignore it. Returns the trimmed, ready-to-store
    /// title (no wrapping quotes, no trailing whitespace, ≤ a sensible
    /// length cap — 80 chars matches the server-side `sanitizeTitle` ceiling).
    /// Throws if the local model is unavailable, errors out, or returns
    /// nothing usable; callers log + drop.
    func generateTitle(transcript: String, guide: String?) async throws -> String
}
