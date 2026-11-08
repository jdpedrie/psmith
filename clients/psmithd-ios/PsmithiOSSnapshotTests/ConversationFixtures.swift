import Foundation
import SwiftUI
import UIKit
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The conversation boards' content, so a render lays over its board.
@MainActor
enum Convo {
    static let ctx = "ctx-c-scroll"
    static let anthropic = "provider-anthropic"
    static let opus = SnapshotFixtures.userModel(modelID: "claude-opus-4-7", displayName: "Claude Opus 4.7")
    static let haiku = SnapshotFixtures.userModel(modelID: "claude-haiku-4-5", displayName: "Claude Haiku 4.5")

    static var scroll: PsmithConversation {
        Board.conversation("c-scroll", "Scroll architecture review", Board.demo, at: Board.today(10, 42))
    }

    static func user(_ id: String, _ text: String, parent: String? = nil, attachments: [PsmithMessageAttachment] = []) -> PsmithMessage {
        PsmithMessage(id: id, contextID: ctx, parentID: parent, role: .user, content: text,
                      createdAt: Board.today(10, 40), attachments: attachments)
    }

    static func reply(_ id: String, _ text: String, parent: String? = nil, usage: PsmithMessageUsage? = cached94,
                      thinking: String? = nil, thinkingMs: Int32? = nil, tools: [PsmithToolCall] = [],
                      error: String? = nil, model: String = "claude-opus-4-7", persona: String? = nil, personaIndex: Int? = nil,
                      fragments: [PsmithUIFragment] = []) -> PsmithMessage {
        PsmithMessage(id: id, contextID: ctx, parentID: parent, role: .assistant, content: text,
                      providerID: anthropic, modelID: model, usage: usage, errorText: error,
                      thinkingRenderedText: thinking, thinkingDurationMs: thinkingMs, toolCalls: tools,
                      createdAt: Board.today(10, 42), uiFragments: fragments, persona: persona, personaIndex: personaIndex)
    }

    /// 94% of the prompt from cache.
    static let cached94 = PsmithMessageUsage(inputTokens: 82_100, outputTokens: 1_204, cacheReadTokens: 77_200,
                                              reasoningTokens: 640, inputCostUsd: 0.0246, outputCostUsd: 0.0903,
                                              cacheReadCostUsd: 0.1158, totalCostUsd: 0.2307)

    static func json(_ s: String) -> Data { s.data(using: .utf8)! }

    /// A view model loaded with the board's messages, against a server
    /// that isn't there.
    static func model(_ messages: [PsmithMessage], conversation: PsmithConversation = scroll, client: PsmithClient,
                      tokenCount: Int32? = 82_000, contextWindow: Int32? = 200_000,
                      stream: StreamHub.ActiveStream? = nil, draft: String = "", queued: [String] = []) -> ConversationViewModel {
        let hub = StreamHub(subscriber: client.streams)
        if let stream { hub.seedForPreview(stream) }
        var queue: OutboundQueue?
        if !queued.isEmpty {
            let q = OutboundQueue(userDefaults: UserDefaults(suiteName: "psmith-snap-queue-\(UUID().uuidString)")!)
            for (i, text) in queued.enumerated() {
                q.enqueue(OutboundQueueEntry(conversationID: conversation.id, content: text, providerID: nil, modelID: nil,
                                             parentMessageID: nil, attachmentFileIDs: [], deviceFacts: [],
                                             queuedAt: Date().addingTimeInterval(Double(i))))
            }
            queue = q
        }
        let vm = ConversationViewModel(conversation: conversation, client: client, hub: hub, outboundQueue: queue, onTerminal: {})
        vm.messages = messages
        let context = SnapshotFixtures.context(id: conversation.activeContextID, conversationID: conversation.id)
        vm.contexts = [context]
        vm.activeContext = context
        vm.availableModels = [opus, haiku]
        vm.providerLabels = [anthropic: "Anthropic"]
        vm.providerTypes = [anthropic: "anthropic"]
        vm.selectedProviderID = anthropic
        vm.selectedModelID = "claude-opus-4-7"
        vm.tokenCount = tokenCount
        vm.contextWindow = contextWindow
        vm.draft = draft
        return vm
    }

    static func stream(_ convo: PsmithConversation = scroll, text: String = "", purpose: PsmithStreamPurpose = .assistantResponse,
                       thinking: String = "", thinkingStarted: Date? = nil, thinkingFinished: Date? = nil,
                       tools: [LiveToolCall] = []) -> StreamHub.ActiveStream {
        StreamHub.ActiveStream(runID: "run-1", conversationID: convo.id, contextID: convo.activeContextID, purpose: purpose,
                               streamingText: text, streamingThinking: thinking, streamingThinkingStartedAt: thinkingStarted,
                               streamingThinkingFinishedAt: thinkingFinished, streamingToolCalls: tools)
    }

    static func liveTool(_ name: String, secondsAgo: Double, executing: Bool = true) -> LiveToolCall {
        var c = LiveToolCall(id: "tool-\(name)", name: name, startedAt: Date().addingTimeInterval(-secondsAgo - 0.2))
        c.input = #"{"query":"LazyVStack estimates"}"#
        if executing { c.argsCompletedAt = Date().addingTimeInterval(-secondsAgo) }
        return c
    }

    static func attachment(_ id: String, _ name: String, kind: String, mime: String, size: Int64) -> PsmithMessageAttachment {
        PsmithMessageAttachment(fileID: id, kind: kind, mimeType: mime, sha256: "x", originalFilename: name,
                                roleHint: "", sizeBytes: size)
    }

    static func png(_ w: Int = 112, _ h: Int = 112) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            UIColor(red: 0.16, green: 0.23, blue: 0.31, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            UIColor(red: 0.3, green: 0.59, blue: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(x: w / 4, y: h / 3, width: w / 2, height: h / 3))
        }.pngData()!
    }

    // MARK: Boards

    static let lazyAnswer = """
    The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts.

    Two changes fix it:

    1. **Render eagerly.** Every offset is exact, so a jump lands where it says.
    2. **Follow, then park.** At the bottom, growth re-pins there. Scroll up and it stops following.

    ```
    ScrollView {
      VStack(spacing: 18) { rows }
    }
    ```
    """

    static var conversation: [PsmithMessage] {
        [
            user("u1", "Why does the transcript jump when a reply finishes?"),
            reply("a1", lazyAnswer, parent: "u1", thinking: "Check the stack type first.", thinkingMs: 12_400,
                  tools: [PsmithToolCall(id: "t1", name: "read_file", input: json(#"{"path":"ConversationView.swift"}"#))]),
        ]
    }

    static var streamingHistory: [PsmithMessage] {
        [
            reply("a0", "Swap the lazy stack for an eager one and the offsets stop moving. The cost is building every row up front, which is cheap below a few hundred messages.", usage: nil),
            user("u1", "And past a few hundred? Check what the docs say about LazyVStack estimates.", parent: "a0"),
        ]
    }

    static var usageBoard: [PsmithMessage] {
        [
            user("u-b", "What does the eager stack cost at 500 rows?"),
            reply("a1", "About 38 ms to lay out the first time and 21 MB held. Both are fine on a phone.", parent: "u-b",
                  tools: [PsmithToolCall(id: "t1", name: "run_benchmark", input: json(#"{"rows":500,"stack":"eager"}"#),
                                         output: json(#"{"first_layout_ms":38,"memory_mb":21}"#), elapsedMs: 2_000)]),
        ]
    }

    /// Three versions of the question; the board shows the second.
    static var usageTree: [PsmithMessage] {
        [user("u-a", "What does it cost?"), user("u-b", "What does the eager stack cost at 500 rows?"),
         user("u-c", "And at 2,000?")] + Array(usageBoard.dropFirst())
    }

    static var states: [PsmithMessage] {
        [
            user("u1", "Is the lazy stack the problem?"),
            reply("a1", "It is. Rows above the viewport report estimated heights until they render.", parent: "u1", usage: nil),
            user("u2", "So what does a jump cost past a few hundred rows? Give me numbers.", parent: "a1"),
            reply("a2", "Past a few hundred rows the", parent: "u2", usage: nil,
                  error: "Anthropic returned 529: the API is overloaded. Try again in a moment."),
        ]
    }

    static var council: [PsmithMessage] {
        [
            user("u1", "Should launch pricing include a free tier?"),
            reply("p1", "A free tier anchors the price at zero. Charge from day one and offer a 14-day trial instead.", parent: "u1",
                  usage: nil, persona: "Skeptic", personaIndex: 0),
            reply("p2", "Self-hosters try before they buy. A free tier capped at one user costs us almost nothing.", parent: "p1",
                  usage: nil, persona: "Optimist", personaIndex: 1),
            reply("p3", "Both work if the cap sits below where a team needs it. Pick the cap first, then the price.", parent: "p2",
                  usage: nil, persona: "Economist", personaIndex: 2),
        ]
    }

    static var thinking: [PsmithMessage] {
        [
            reply("a1", "I couldn't open the file at that path. Going from the summary: the view follows while pinned to the bottom and parks on any drag.",
                  usage: nil,
                  thinking: "The user wants the scroll code read straight from the repo. ConversationView.swift holds the follow logic, so read that first. If the path moved in the restructure, fall back to the summary from earlier in this context and say so.",
                  thinkingMs: 6_800,
                  tools: [PsmithToolCall(id: "t1", name: "read_file", input: json(#"{"path":"clients/ios/ConversationView.swift"}"#),
                                         error: "No such file: clients/ios/ConversationView.swift", elapsedMs: 2_000)]),
            user("u2", "Try clients/psmithd-ios instead.", parent: "a1"),
        ]
    }

    static var selectText: [PsmithMessage] {
        [
            reply("a1", "An eager stack builds every row up front. Below a few hundred messages that costs less than a frame, and every offset is exact, so jumps land where they say.", usage: nil),
            user("u2", "What breaks if a reply is taller than the screen?", parent: "a1"),
            reply("a2", "Nothing breaks. The streaming row clips at one viewport, so its first line rests near the top while the tail fills in under a fade.\n\nWhen it ends, the clip releases and the view scrolls the reply's top into view. Following resumes only if you're within 32 points of the bottom, so a long answer never yanks you away from where you're reading.", parent: "u2", usage: nil),
        ]
    }

    static let summaryText = """
    We reviewed why the transcript jumps when a reply finishes. Cause: the lazy stack reports estimated row heights until rows render.

    Decided: render eagerly, follow while pinned, park on any drag, resume within 32 points of the bottom. Open: paging history past a few hundred rows.
    """ + String(repeating: "\n\nDetail: the follow and park rules, measured offsets, and the rejected correction passes.", count: 60)

    static var systemStrip: [PsmithMessage] {
        [
            PsmithMessage(id: "s1", contextID: ctx, role: .system,
                          content: "You are a senior iOS reviewer. Answer in short paragraphs, cite the file and line you mean, and say plainly when you are guessing.\n\nPrefer measured numbers over adjectives."),
            PsmithMessage(id: "c1", contextID: ctx, parentID: "s1", role: .context,
                          content: "Psmith scroll notes: follow, park, clip\n\nThe transcript is inverted."),
            user("u1", "Picking up from the summary: how do we page older history?", parent: "c1"),
            reply("a1", "Keep the newest 200 rows eager and load older ones in pages above them. Insert each page while the reader is parked, then restore the offset of the first visible row.", parent: "u1", usage: nil),
        ]
    }

    static var attachments: [PsmithMessage] {
        [
            user("u1", "Before and after on device, plus the Instruments trace. What moves?", attachments: [
                attachment("f1", "scroll-jump-before.png", kind: "image", mime: "image/png", size: 210_000),
                attachment("f2", "scroll-jump-after.png", kind: "image", mime: "image/png", size: 208_000),
                attachment("f3", "scroll-trace.pdf", kind: "document", mime: "application/pdf", size: 1_258_291),
            ]),
            reply("a1", "In the first shot the reply's top sits 214 points lower than in the second. That's the estimate correcting as rows above it render.\n\nThe trace agrees: page 3 shows a layout pass on every row above the viewport when the stream ends. With the eager stack that pass is gone.", parent: "u1"),
        ]
    }

    static var longReply: [PsmithMessage] {
        let lines = (0..<1_345).map { i -> String in
            let ms = 114 + i * 17
            return String(format: "09:41:%02d.%03d %@", 2 + ms / 1000 % 58, ms % 1000,
                          i % 2 == 0 ? "layout pass rows=412 dy=0" : "stream chunk len=\(96 + i % 7 * 18)")
        }
        let first = """
        09:41:02.114 layout pass rows=412 dy=0
        09:41:02.131 stream chunk len=184
        09:41:02.148 layout pass rows=412 dy=0
        09:41:02.166 stream chunk len=203
        09:41:02.183 layout pass rows=412 dy=0
        09:41:02.201 stream end id=m_8f21
        09:41:02.321 scroll to top id=m_8f21
        09:41:02.571 follow resumed gap=12
        09:41:03.002 layout pass rows=412 dy=0
        09:41:03.019 stream chunk len=96
        """
        let body = "Here is the full log from the 400-message run, one line per layout pass, newest last.\n\n```\n"
            + first + "\n" + lines.dropFirst(10).joined(separator: "\n") + "\n```"
        // Exactly the board's 48 KB.
        let padded = body + String(repeating: " ", count: max(0, 49_152 - body.utf8.count))
        return [
            user("u1", "Paste the full scroll trace log so I can search it."),
            reply("a1", padded, parent: "u1"),
        ]
    }

    static var fragments: [PsmithMessage] {
        let choices = PsmithUIFragment(component: "choice_list", props: json(#"{"items":[{"label":"A. Fixed pages of 100 rows","value":"send:A"},{"label":"B. Pages by day","value":"send:B"},{"label":"C. No paging; load everything","value":"send:C"}]}"#))
        let cards = PsmithUIFragment(component: "card_list", props: json(#"{"items":[{"title":"ScrollPosition and anchored inserts","description":"Keep the first visible row fixed while content is inserted above it.","url":"https://developer.apple.com","badges":["Apple docs","iOS 18"]},{"title":"Chat scroll design note","description":"Follow, then park. Why the stack is eager and when that stops being cheap.","url":"https://example.com","badges":["docs/clients"]}]}"#))
        let kv = PsmithUIFragment(component: "key_value", props: json(#"{"pairs":[{"key":"Rows","value":"412"},{"key":"Build time","value":"11.8 ms"},{"key":"Largest jump","value":"0 pt"}]}"#))
        return [
            reply("a1", "Which way should we page older history?", usage: nil,
                  fragments: [PsmithUIFragment(component: "text", props: json(#"{"text":"Which way should we page older history?"}"#)), choices]),
            user("u2", "B. Then find me references on restoring scroll position.", parent: "a1"),
            reply("a2", "Three references worth reading, then the numbers from our own run.", parent: "u2", usage: nil,
                  fragments: [PsmithUIFragment(component: "text", props: json(#"{"text":"Three references worth reading, then the numbers from our own run."}"#)), cards, kv]),
        ]
    }

    static var offline: [PsmithMessage] {
        [reply("a1", "Pages by day keep a session's messages together, so a restore lands on a familiar boundary. Insert each page while the reader is parked.")]
    }

    static var renameBoard: [PsmithMessage] {
        [
            user("u1", "Why does the transcript jump when a reply finishes?"),
            reply("a1", "The lazy stack is the cause. Rows above the viewport report estimated heights until they render, so when the finished reply swaps in, every offset above it shifts.\n\nRender eagerly and every offset is exact, so a jump lands where it says.", parent: "u1"),
        ]
    }

    static let decision = "Decision: render the transcript eagerly and follow, then park. Rejected: estimated heights with correction passes, because every correction moves the reader."

    static let reviewSummary = """
    Topic: why the iOS transcript jumps when a reply finishes, and what to build instead.

    Decided: render the transcript eagerly and follow, then park. Estimated heights with correction passes were rejected because every correction moves the reader.

    Open: paging older history above the last 200 rows. Jamie wants numbers for 500 and 2,000 messages before choosing.
    """

    static func review(truncated: Bool) -> [PsmithMessage] {
        // One long closing paragraph past the preview budget brings the
        // text to the board's size without showing in the preview.
        let target = truncated ? 16_691 : 6_963
        let pad = "\n\n" + String(repeating: "Detail. ", count: (target - reviewSummary.utf8.count - 2) / 8)
        return [
            user("u1", "Write it up as a decision record."),
            reply("a1", decision, parent: "u1", usage: nil),
            PsmithMessage(id: "sum", contextID: ctx, parentID: "a1", role: .compressionSummary, content: reviewSummary + pad,
                          providerID: anthropic, modelID: "claude-haiku-4-5",
                          usage: PsmithMessageUsage(inputTokens: 118_420, outputTokens: truncated ? 4_096 : 1_684,
                                                    cacheReadTokens: 96_210, totalCostUsd: truncated ? 0.0441 : 0.0321),
                          finishReason: truncated ? "max_tokens" : nil),
        ]
    }

    static var decisionPair: [PsmithMessage] {
        [user("u1", "Write it up as a decision record."), reply("a1", decision, parent: "u1", usage: nil)]
    }

    static var compressFailed: [PsmithMessage] {
        decisionPair + [
            PsmithMessage(id: "sum", contextID: ctx, parentID: "a1", role: .compressionSummary, content: "Topic: why the iOS",
                          providerID: anthropic, modelID: "claude-haiku-4-5",
                          errorText: "Claude Haiku 4.5 can’t fit 82,140 tokens."),
        ]
    }

    static var archived: [PsmithMessage] {
        [
            user("u1", "So the eager stack wins below 500 rows?"),
            reply("a1", "Yes. Below 500 rows the eager stack builds in under 40 ms on an iPhone 13, and every offset is exact. Above that, keep the last 200 eager and page older history in above them.\n\nThat is the whole decision. The record is in the thread above.", parent: "u1", usage: nil),
        ]
    }

    static var elicit: [PsmithMessage] {
        [user("u1", "Ship a preview of the scroll fix so Jamie can try it.")]
    }

    static let elicitRequest = ElicitRequest(
        id: "el-1", message: "deploy_preview wants to know where to deploy the scroll fix.",
        schemaJSON: json(#"{"type":"object","properties":{"branch":{"type":"string","default":"scroll-follow-park"},"replicas":{"type":"integer","description":"Number of preview instances"},"notify_team":{"type":"boolean","default":true}},"required":["branch"]}"#)
    )

    static let demoDescribed = SnapshotFixtures.profile(id: "p-demo-7", name: "Demo",
                                                        description: "Shows off tools and fragments. Good for testing a new model.",
                                                        favorite: false)
    static let chiefDescribed = SnapshotFixtures.profile(id: "p-chief-4", name: "Chief of staff",
                                                         description: "Calendar, email triage and the weekly memo. Terse and direct.",
                                                         favorite: true, isDefault: true)
    static let pirateDescribed = SnapshotFixtures.profile(id: "p-pirate-0", name: "Pirate tutor",
                                                          description: "Teaches fractions to a nine-year-old, in pirate voice.", favorite: false)
    static let councilDescribed = SnapshotFixtures.profile(id: "p-council-3", name: "Council",
                                                           description: "Skeptic, Optimist and Economist debate, then you decide.", favorite: false)
    static var describedProfiles: [PsmithProfile] { [demoDescribed, chiefDescribed, pirateDescribed, councilDescribed] }
}
