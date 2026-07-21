import Testing
import Foundation
@testable import PsmithUI

/// Tests for `MarkdownBudget` — the size guard between transcript rows
/// and MarkdownUI. The cuts must be bounded (that's the whole point),
/// land on safe boundaries, and keep fenced code blocks balanced; the
/// chunker must reconstruct the source exactly.
struct MarkdownBudgetTests {

    // MARK: head

    @Test func headReturnsNilWithinBudget() {
        #expect(MarkdownBudget.head("short document", limit: 100) == nil)
    }

    @Test func headCutsAtLineBoundaryUnderLimit() {
        let source = Array(repeating: "0123456789", count: 20).joined(separator: "\n")
        let head = MarkdownBudget.head(source, limit: 55)
        // 5 lines * 10 chars + 4 newlines = 54 <= 55; a 6th line would exceed.
        #expect(head == Array(repeating: "0123456789", count: 5).joined(separator: "\n"))
    }

    @Test func headClosesOpenBacktickFence() throws {
        let source = "intro\n```swift\nlet a = 1\nlet b = 2\n" +
            Array(repeating: "let x = 0", count: 50).joined(separator: "\n")
        let head = try #require(MarkdownBudget.head(source, limit: 40))
        #expect(head.hasSuffix("\n```"))
        // Even count of fence lines = balanced.
        let fenceLines = head.split(separator: "\n").filter { $0.hasPrefix("```") }
        #expect(fenceLines.count % 2 == 0)
    }

    @Test func headClosesTildeFenceWithTilde() throws {
        let source = "~~~\ncode\n" +
            Array(repeating: "more", count: 60).joined(separator: "\n")
        let head = try #require(MarkdownBudget.head(source, limit: 30))
        #expect(head.hasSuffix("\n~~~"))
    }

    @Test func headDoesNotCloseAlreadyClosedFence() throws {
        let source = "```\ncode\n```\n" +
            Array(repeating: "prose", count: 60).joined(separator: "\n")
        let head = try #require(MarkdownBudget.head(source, limit: 40))
        #expect(!head.hasSuffix("```\n```"))
        let fenceLines = head.split(separator: "\n").filter { $0.hasPrefix("```") }
        #expect(fenceLines.count % 2 == 0)
    }

    @Test func headHardCutsSingleMonsterLine() throws {
        let source = String(repeating: "a", count: 50_000)
        let head = try #require(MarkdownBudget.head(source, limit: 1_000))
        #expect(head.count == 1_000)
    }

    @Test func headIsAlwaysBounded() {
        // The invariant that matters: no input produces an unbounded
        // preview. Slack allowance covers the appended fence closer.
        let inputs = [
            String(repeating: "word ", count: 20_000),
            Array(repeating: "```", count: 5_000).joined(separator: "\n"),
            String(repeating: "x", count: 100_000),
        ]
        for source in inputs {
            if let head = MarkdownBudget.head(source, limit: 2_000) {
                #expect(head.count <= 2_000 + 8)
            } else {
                #expect(source.count <= 2_000)
            }
        }
    }

    // MARK: tailClamped

    @Test func tailClampedPassesThroughWithinBudget() {
        let source = "hello\nworld"
        #expect(MarkdownBudget.tailClamped(source, limit: 100) == source)
    }

    @Test func tailClampedKeepsTrailingLines() {
        let source = (0..<100).map { "line-\($0)" }.joined(separator: "\n")
        let out = MarkdownBudget.tailClamped(source, limit: 50)
        #expect(out.hasPrefix("…\n\n"))
        #expect(out.hasSuffix("line-99"))
        #expect(out.count < 50 + 16)
    }

    @Test func tailClampedReopensFence() {
        // The cut lands inside an unclosed fence — the tail must
        // reopen it or everything after renders as corrupted prose.
        let source = "prose before\n```\n" +
            (0..<100).map { "code-\($0)" }.joined(separator: "\n")
        let out = MarkdownBudget.tailClamped(source, limit: 50)
        #expect(out.hasPrefix("…\n\n```\n"))
    }

    @Test func tailClampedHardCutsSingleMonsterLine() {
        let source = String(repeating: "b", count: 50_000)
        let out = MarkdownBudget.tailClamped(source, limit: 1_000)
        #expect(out.count <= 1_000 + 8)
        #expect(out.hasPrefix("…\n\n"))
    }

    // MARK: chunks

    @Test func chunksAreConcatenationFaithful() {
        let source = (0..<50).map { section in
            "## Section \(section)\n\nSome paragraph text for section \(section).\n\n```\ncode line 1\ncode line 2\n```\n"
        }.joined(separator: "\n")
        let parts = MarkdownBudget.chunks(source, target: 200)
        #expect(parts.count > 1)
        #expect(parts.joined() == source)
    }

    @Test func chunksNeverSplitInsideFence() {
        let fence = "```\n" + (0..<80).map { "code-\($0)" }.joined(separator: "\n") + "\n```"
        let source = "before\n\n" + fence + "\n\nafter"
        let parts = MarkdownBudget.chunks(source, target: 100)
        #expect(parts.joined() == source)
        // The fence's lines must all land in one chunk: every chunk
        // has an even number of fence markers.
        for part in parts {
            let markers = part.split(separator: "\n").filter { $0.hasPrefix("```") }
            #expect(markers.count % 2 == 0)
        }
    }

    @Test func chunksBoundMonsterLines() {
        let source = "intro\n\n" + String(repeating: "z", count: 25_000) + "\n\noutro"
        let parts = MarkdownBudget.chunks(source, target: 1_000)
        #expect(parts.joined() == source)
        for part in parts {
            #expect(part.count <= 2_000 + 2)
        }
    }

    @Test func chunksSingleSmallDocIsOneChunk() {
        let source = "just a paragraph"
        #expect(MarkdownBudget.chunks(source, target: 1_000) == [source])
    }

    @Test func chunksEmptySourceIsOneEmptyChunk() {
        #expect(MarkdownBudget.chunks("", target: 100) == [""])
    }

    @Test func chunksRealisticSummaryStaysBounded() {
        // Shape of the document class that motivated all of this: a
        // multi-leg compaction summary — sections, bullets, fences,
        // tables — at 100KB+ scale. Every chunk must stay within a
        // small multiple of the target.
        var doc = "# Summary\n"
        for s in 0..<60 {
            doc += "\n## Section \(s)\n\n"
            doc += (0..<12).map { "- item \($0) with some explanatory text" }.joined(separator: "\n")
            doc += "\n\n```go\nfunc f\(s)() {}\nreturn\n```\n\n"
            doc += "| a | b |\n|---|---|\n| 1 | 2 |\n"
        }
        let parts = MarkdownBudget.chunks(doc)
        #expect(parts.joined() == doc)
        for part in parts {
            #expect(part.count <= MarkdownBudget.chunkTarget * 2 + 2)
        }
    }
}
