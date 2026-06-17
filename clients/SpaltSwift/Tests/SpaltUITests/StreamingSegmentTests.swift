import Testing
import Foundation
@testable import SpaltUI
import SpaltKit

/// Tests for `parseStreamingSegments` — the streaming-display parser
/// that splits a partial assistant body into [text, fragment,
/// pendingBlock] segments using the resolved component-tag list. This
/// is the user-facing behavior the inline-render feature depends on.
struct StreamingSegmentTests {
    /// Single configured component; helper for terse setup.
    private let sceneHeader = SpaltStreamingComponentTag(
        tag: "scene_header", component: "key_value"
    )

    /// Verifies the empty-config short-circuit. With no components,
    /// the parser must NOT hide tag-looking content — it returns the
    /// whole text as one prose segment.
    @Test func emptyComponentsReturnsTextVerbatim() {
        let body = #"<scene_header>{"x":1}</scene_header> hello"#
        let out = parseStreamingSegments(body, components: [])
        #expect(out.count == 1)
        if case .text(let s) = out[0] {
            #expect(s == body)
        } else {
            Issue.record("expected single .text segment, got \(out)")
        }
    }

    /// Closed `<scene_header>{json}</scene_header>` should become a
    /// .fragment segment carrying the body bytes for the configured
    /// component renderer.
    @Test func closedBlockBecomesFragment() {
        let body = #"<scene_header>{"Location":"X","Time":"Y"}</scene_header>"#
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 1)
        guard case .fragment(let frag) = out[0] else {
            Issue.record("expected .fragment, got \(out)")
            return
        }
        #expect(frag.component == "key_value")
        // Body bytes should round-trip to the same JSON object.
        let decoded = try? JSONSerialization.jsonObject(with: frag.props, options: [])
        let dict = decoded as? [String: Any]
        #expect(dict?["Location"] as? String == "X")
        #expect(dict?["Time"] as? String == "Y")
    }

    /// An OPEN tag without a matching close (still streaming) should
    /// collapse to a .pendingBlock placeholder and stop scanning —
    /// nothing past the open tag should leak into the displayed text.
    @Test func openWithoutCloseBecomesPendingBlock() {
        // No `</scene_header>` yet.
        let body = #"prose before <scene_header>{"Loca"#
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 2)
        if case .text(let s) = out[0] {
            #expect(s == "prose before ")
        } else {
            Issue.record("expected .text(\"prose before \"), got \(out)")
        }
        if case .pendingBlock = out[1] {
            // ok
        } else {
            Issue.record("expected .pendingBlock as second segment, got \(out)")
        }
    }

    /// Mid-tag stream (open `<sc...` without yet finishing the open
    /// tag) should also produce .pendingBlock — no partial `<` should
    /// leak into the rendered prose either.
    @Test func midOpenTagBecomesPendingBlock() {
        let body = #"prose <sc"#
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 2)
        if case .text(let s) = out[0] {
            #expect(s == "prose ")
        } else {
            Issue.record("expected .text(\"prose \"), got \(out)")
        }
        if case .pendingBlock = out[1] {} else {
            Issue.record("expected .pendingBlock, got \(out)")
        }
    }

    /// A closed block followed by trailing prose should produce
    /// [.fragment, .text(trailing)].
    @Test func closedBlockPlusTrailingProse() {
        let body = #"<scene_header>{"a":1}</scene_header> and then prose."#
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 2)
        if case .fragment = out[0] {} else {
            Issue.record("expected first segment .fragment, got \(out)")
        }
        if case .text(let s) = out[1] {
            #expect(s == " and then prose.")
        } else {
            Issue.record("expected trailing .text, got \(out)")
        }
    }

    /// An unknown tag (not in the component list) should render as
    /// literal markdown prose — the parser doesn't hide arbitrary
    /// angle-bracket-shaped content the user might have in their text.
    @Test func unknownTagRendersAsLiteralProse() {
        let body = "before <other>x</other> after"
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 1)
        if case .text(let s) = out[0] {
            #expect(s == "before <other>x</other> after")
        } else {
            Issue.record("expected single .text with literal tags, got \(out)")
        }
    }

    /// Invalid JSON inside a closed block should collapse to
    /// .pendingBlock — better to hide than render a broken fragment
    /// mid-stream. The settled MessageRow at terminal renders raw
    /// tags via the standard fallback.
    @Test func invalidJSONBodyBecomesPendingBlock() {
        let body = "<scene_header>not json</scene_header>"
        let out = parseStreamingSegments(body, components: [sceneHeader])
        #expect(out.count == 1)
        if case .pendingBlock = out[0] {} else {
            Issue.record("expected .pendingBlock for invalid JSON, got \(out)")
        }
    }

    /// Realistic snapshot of a mid-stream tick: the user's reported
    /// scene_header body is JSON-valid, multi-line, includes em-dash
    /// + colons inside string values. Must produce one .fragment.
    @Test func realisticSceneHeaderBlockProducesFragment() {
        let body = """
        <scene_header>
        {
          "Location": "Langley, Virginia — CIA Headquarters, Room 6B-14",
          "Interaction Level": "/4",
          "Time": "Tuesday, October 12, 2024 — 14:00"
        }
        </scene_header>

        The HVAC vent above the table produces a steady, tuneless hum.
        """
        let out = parseStreamingSegments(body, components: [sceneHeader])
        // Expect [.fragment(scene_header_body), .text(trailing prose)]
        #expect(out.count == 2)
        if case .fragment(let frag) = out[0] {
            #expect(frag.component == "key_value")
            let decoded = try? JSONSerialization.jsonObject(with: frag.props, options: [])
            let dict = decoded as? [String: Any]
            #expect(dict?["Location"] as? String == "Langley, Virginia — CIA Headquarters, Room 6B-14")
        } else {
            Issue.record("expected first segment .fragment, got \(out)")
        }
        if case .text(let s) = out[1] {
            #expect(s.contains("HVAC vent above"))
        } else {
            Issue.record("expected trailing prose .text, got \(out)")
        }
    }
}
