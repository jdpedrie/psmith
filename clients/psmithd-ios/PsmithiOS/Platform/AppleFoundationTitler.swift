import Foundation
import PsmithKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// iOS twin of `PsmithMac/AppleFoundationTitler`. Same `LocalTitler`
/// implementation, same prompt shape, same sanitiser — diverges only
/// where the framework requires a per-platform `@available` annotation
/// and where the iOS deployment target enters the picture.
///
/// Apple Intelligence on iOS requires an iPhone 15 Pro / iPad with
/// M-series chip running iOS 26+. On any other device the
/// `AppleFoundation.availability` check returns `.unavailable` and
/// the trigger logic in ConversationViewModel skips this titler.
struct AppleFoundationTitler: LocalTitler {
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

    private static let maxTitleLength = 80

    var isAvailable: Bool {
        AppleFoundation.isAvailable
    }

    func generateTitle(transcript: String, guide: String?) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw LocalTitlerError.unavailable(reason: String(describing: reason))
            }

            let instructions = Self.buildInstructions(guide: guide)
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 32)
            let response = try await session.respond(
                to: Self.buildPrompt(transcript: transcript),
                options: options
            )
            let trimmed = Self.sanitize(response.content)
            guard !trimmed.isEmpty else { throw LocalTitlerError.emptyResult }
            return trimmed
        } else {
            throw LocalTitlerError.unavailable(reason: "iOS < 26")
        }
        #else
        throw LocalTitlerError.unavailable(reason: "FoundationModels framework not available")
        #endif
    }

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

    /// Trim, strip wrapping quotes, collapse whitespace, cap length —
    /// matches the Mac twin character-for-character so a title
    /// generated on iPhone reads identically to one from a Mac
    /// session with the same transcript.
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 {
            let first = s.first
            let last = s.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = collapsed
        if s.count > maxTitleLength {
            s = String(s.prefix(maxTitleLength))
            if let lastSpace = s.lastIndex(of: " "),
               s.distance(from: s.startIndex, to: lastSpace) > maxTitleLength / 2 {
                s = String(s[..<lastSpace])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
