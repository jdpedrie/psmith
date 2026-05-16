import SwiftUI

/// Progressively reveals a string with a fast fake-stream animation.
/// Used for the profile-welcome message — it's a real persisted
/// assistant turn, but on first render in an app session we play a
/// token-chunk reveal so the user sees the assistant "say hello"
/// rather than appearing with prepared text.
///
/// The reveal runs exactly once per view instance via SwiftUI's
/// `.task` lifecycle. Callers gate "once per app session" by checking
/// a played-set in their view model and only constructing this view
/// when not played; mark-as-played via `onComplete` so subsequent
/// renders of the same message show the static `MarkdownText`.
///
/// Chunking is by whitespace-bounded tokens — feels more like an LLM
/// stream than character-by-character, which reads as too mechanical
/// for short greetings.
public struct WelcomeReveal: View {
    let text: String
    /// Tokens-per-second target. ~30 tps reads as quick-but-readable
    /// for typical 10-30 token welcomes; faster than a real LLM but
    /// not so fast it feels instant.
    let tokensPerSecond: Double
    let onComplete: () -> Void

    @State private var revealed: String = ""
    @State private var started = false

    public init(text: String, tokensPerSecond: Double = 30, onComplete: @escaping () -> Void = {}) {
        self.text = text
        self.tokensPerSecond = tokensPerSecond
        self.onComplete = onComplete
    }

    public var body: some View {
        // Match MarkdownText's rendering so the reveal smoothly hands
        // off to the static markdown view post-animation (no font /
        // size jump). Plain Text uses the same defaults; markdown
        // formatting in welcomes is uncommon but renders correctly via
        // MarkdownText when the parent swaps in.
        MarkdownText(revealed.isEmpty ? " " : revealed)
            .task {
                guard !started else { return }
                started = true
                await runReveal()
                onComplete()
            }
    }

    private func runReveal() async {
        // Split into reveal chunks at every whitespace transition.
        // Each chunk is one word + the whitespace that followed it
        // (so the trailing space appears with the word — feels more
        // natural than revealing the space separately).
        let chunks = tokenize(text)
        let delayNs = UInt64(max(1.0 / tokensPerSecond, 0.005) * 1_000_000_000)
        var built = ""
        for chunk in chunks {
            if Task.isCancelled { return }
            built.append(chunk)
            revealed = built
            try? await Task.sleep(nanoseconds: delayNs)
        }
    }

    /// Splits `s` into reveal-sized chunks. Each chunk is a sequence
    /// of non-whitespace characters followed by any whitespace
    /// (including newlines) that immediately follows. Preserves
    /// every original character — concatenating the chunks
    /// reproduces `s` exactly.
    private func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inWhitespace = false
        for ch in s {
            if ch.isWhitespace {
                current.append(ch)
                inWhitespace = true
            } else {
                if inWhitespace {
                    out.append(current)
                    current = ""
                    inWhitespace = false
                }
                current.append(ch)
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }
}
