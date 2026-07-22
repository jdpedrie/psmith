import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `LocalTitler` backed by Apple's on-device `FoundationModels` framework
/// (macOS 26+ / iOS 26+, requires Apple Intelligence to be enabled). Free,
/// fast (typically sub-second for a 4-word title), private — the transcript
/// never leaves the device. Lives in PsmithKit so the Mac and iOS shells
/// inject the SAME implementation.
///
/// The whole type is gated on `canImport(FoundationModels)` so the package
/// still compiles on older SDKs / non-Apple-Intelligence-capable machines.
/// On those builds `isAvailable` returns false and `generateTitle` throws,
/// which the trigger logic in `ConversationViewModel` treats as a no-op.
public struct AppleFoundationTitler: LocalTitler {
    /// Errors specific to the local titler. The trigger path logs and drops
    /// these silently — we never surface a popup or banner.
    enum LocalTitlerError: Error, CustomStringConvertible {
        case unavailable(reason: String)
        case emptyResult

        var description: String {
            switch self {
            case .unavailable(let reason): return "Apple Foundation Models unavailable: \(reason)"
            case .emptyResult:              return "Apple Foundation Models returned no usable text"
            }
        }
    }

    /// Cap on the title we'll persist. Matches the server-side
    /// `sanitizeTitle` ceiling so the Mac and cloud paths feel identical.
    private static let maxTitleLength = 80

    /// Fired by the view-model trigger to gate the rest of the work.
    /// Delegates to the shared `AppleFoundation.isAvailable` check in
    /// PsmithKit so the Mac titler, the iOS titler, and the settings
    /// pickers in both shells answer this question identically.
    public init() {}

    public var isAvailable: Bool {
        AppleFoundation.isAvailable
    }

    /// Run the on-device model on a tiny prompt and return a sanitized
    /// title. The prompt mirrors the server-side title path so the local
    /// model produces consistent style. Cap output via the session's
    /// generation options to avoid the model wandering into a paragraph.
    public func generateTitle(transcript: String, guide: String?) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw LocalTitlerError.unavailable(reason: String(describing: reason))
            }

            let instructions = Self.buildInstructions(guide: guide)
            let session = LanguageModelSession(instructions: instructions)
            // Keep the response short: titles are 2–5 words. Sampling at a
            // low temperature pushes the model toward the expected shape;
            // greedy would also be fine here.
            let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 32)
            let response = try await session.respond(
                to: Self.buildPrompt(transcript: transcript),
                options: options
            )
            let trimmed = Self.sanitize(response.content)
            guard !trimmed.isEmpty else { throw LocalTitlerError.emptyResult }
            return trimmed
        } else {
            throw LocalTitlerError.unavailable(reason: "OS < 26")
        }
        #else
        throw LocalTitlerError.unavailable(reason: "FoundationModels framework not available")
        #endif
    }

    // MARK: - Prompt construction

    /// System-style instruction sent once on session init. Mirrors the
    /// server's `defaultTitleGuide` plus the optional user-supplied guide.
    private static func buildInstructions(guide: String?) -> String {
        var pieces: [String] = [
            "You write very short titles for chat conversations.",
            "Reply with only the title — 2 to 5 words, no quotes, no punctuation, no preamble.",
        ]
        if let guide, !guide.isEmpty {
            pieces.append("Additional guidance from the user: \(guide)")
        }
        return pieces.joined(separator: " ")
    }

    private static func buildPrompt(transcript: String) -> String {
        "Write a 2–5 word title for the following exchange:\n\n\(transcript)"
    }

    // MARK: - Sanitization

    /// Trim, strip wrapping quotes, collapse whitespace, cap length. Same
    /// shape as the server-side `sanitizeTitle` so cloud and on-device
    /// titles feel identical in the sidebar.
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single layer of wrapping quotes the model may add.
        if s.count >= 2 {
            let first = s.first
            let last = s.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Collapse internal whitespace runs.
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = collapsed
        if s.count > maxTitleLength {
            s = String(s.prefix(maxTitleLength))
            // Trim back to the last space if it lands past the halfway mark.
            if let lastSpace = s.lastIndex(of: " "),
               s.distance(from: s.startIndex, to: lastSpace) > maxTitleLength / 2 {
                s = String(s[..<lastSpace])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
