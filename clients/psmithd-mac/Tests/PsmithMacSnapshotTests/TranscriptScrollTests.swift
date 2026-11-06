import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// The transcript's scroll behavior, driven the way the running app
/// drives it: an offscreen window, real layout, and real scroll-wheel
/// events for the user's part. Covers the rest-edge rules the Mac now
/// shares with iOS (docs/clients/chat-scroll.md): enter at the newest
/// message, follow growth while at the bottom, let go the moment the
/// user scrolls, park a long reply with its start in view, and leave it
/// there when the stream ends.
@Suite(.serialized)
@MainActor
struct TranscriptScrollTests {
    @MainActor final class Hosted {
        let window: NSWindow
        let host: NSView
        let model: ConversationViewModel
        let hub: StreamHub

        init(window: NSWindow, host: NSView, model: ConversationViewModel, hub: StreamHub) {
            self.window = window
            self.host = host
            self.model = model
            self.hub = hub
        }

        func settle(_ seconds: TimeInterval = 0.35) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }

        /// The transcript's scroll view: the tallest document on screen.
        var scrollView: NSScrollView {
            func all(_ v: NSView) -> [NSScrollView] {
                (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all)
            }
            return all(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
        }

        var documentHeight: CGFloat { scrollView.documentView?.frame.height ?? 0 }

        /// How far the viewport sits above the newest edge.
        var distanceFromBottom: CGFloat {
            let sv = scrollView
            let clip = sv.contentView.bounds
            return documentHeight + sv.contentInsets.bottom - clip.height - clip.origin.y
        }

        var offset: CGFloat { scrollView.contentView.bounds.origin.y }

        /// A trackpad-style scroll: began, a few changes, ended. Positive
        /// `dy` moves toward older messages.
        func scrollUp(by dy: Int32) {
            let sv = scrollView
            for (phase, delta) in [(CGScrollPhase.began, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.ended, 0)] {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                sv.scrollWheel(with: NSEvent(cgEvent: cg)!)
                settle(0.05)
                
            }
            settle(0.3)
        }

        func stream(_ text: String) {
            hub.seedForPreview(StreamHub.ActiveStream(
                runID: "run-1",
                conversationID: model.conversation.id,
                contextID: model.activeContext?.id ?? "ctx",
                purpose: .assistantResponse,
                streamingText: text
            ))
        }
    }

    static func turns(_ n: Int) -> [PsmithMessage] {
        var out: [PsmithMessage] = []
        var parent: String? = nil
        for i in 0..<n {
            let user = PsmithMessage(id: "u\(i)", contextID: "context-conv-1-1", parentID: parent, role: .user, content: "Question \(i)")
            let reply = PsmithMessage(
                id: "a\(i)", contextID: "context-conv-1-1", parentID: user.id, role: .assistant,
                content: "Answer \(i). " + String(repeating: "A sentence of settled history that wraps. ", count: 6)
            )
            out += [user, reply]
            parent = reply.id
        }
        return out
    }

    static func longText(words: Int) -> String {
        (0..<words).map { String(format: "w%03d", $0) }.chunked(20).map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    private func host(messages: [PsmithMessage]) -> Hosted {
        let client = SnapshotStubs.makeClient()
        let hub = StreamHub(subscriber: client.streams)
        let model = ConversationViewModel(
            conversation: SnapshotFixtures.conversation(),
            client: client,
            hub: hub,
            onTerminal: {}
        )
        model.messages = messages
        model.contexts = [SnapshotFixtures.context()]
        model.activeContext = model.contexts.first
        let env = SnapshotEnvironment.standard(conversations: [model.conversation], selectedID: model.conversation.id)
        let root = PsmithMacEnvironment(app: env.app, convos: env.convos, navigator: env.navigator, windowState: env.windowState) {
            NavigationStack {
                ConversationBody(model: model, liveConversation: model.conversation)
            }
        }
        let size = CGSize(width: 1000, height: 700)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        let hosted = Hosted(window: window, host: view, model: model, hub: hub)
        hosted.settle(0.6)
        return hosted
    }

    @Test
    func entersAtTheNewestMessage() {
        let h = host(messages: Self.turns(40))
        defer { h.window.orderOut(nil) }
        #expect(h.documentHeight > 3_000)
        #expect(abs(h.distanceFromBottom) < 2)
    }

    @Test
    func followsNewMessagesWhileAtTheBottom() {
        let h = host(messages: Self.turns(30))
        defer { h.window.orderOut(nil) }
        let before = h.documentHeight
        h.model.messages += Self.turns(33).suffix(6)
        h.settle()
        #expect(h.documentHeight > before + 200)
        #expect(abs(h.distanceFromBottom) < 2)
    }

    @Test
    func aUserScrollLetsGoOfTheBottom() {
        let h = host(messages: Self.turns(30))
        defer { h.window.orderOut(nil) }
        h.scrollUp(by: 800)
        let parked = h.offset
        #expect(h.distanceFromBottom > 400)
        h.model.messages += Self.turns(33).suffix(6)
        h.settle()
        // New content arrived below; the user's place didn't move.
        #expect(abs(h.offset - parked) < 2)
        #expect(h.distanceFromBottom > 600)
    }

    @Test
    func aLongReplyParksWithItsStartInView() {
        let h = host(messages: Self.turns(20))
        defer { h.window.orderOut(nil) }
        h.stream("Starting.")
        h.settle()
        #expect(abs(h.distanceFromBottom) < 2)
        h.stream(Self.longText(words: 120))
        h.settle()
        let parkedHeight = h.documentHeight
        #expect(abs(h.distanceFromBottom) < 2, "follows while the reply fits")
        // Far past one viewport: the clip holds the content still, so the
        // viewport stops moving with the reply's start at the top.
        h.stream(Self.longText(words: 1_200))
        h.settle()
        h.stream(Self.longText(words: 2_000))
        h.settle()
        #expect(abs(h.documentHeight - parkedHeight) < 700, "content capped near one viewport of reply")
        let capped = h.documentHeight
        h.stream(Self.longText(words: 2_400))
        h.settle()
        #expect(abs(h.documentHeight - capped) < 1, "the tail grows behind the clip")
    }

    @Test
    func theStreamEndingLeavesTheReplysStartInView() {
        let h = host(messages: Self.turns(20))
        defer { h.window.orderOut(nil) }
        h.stream("Starting.")
        h.settle()
        let text = Self.longText(words: 2_000)
        h.stream(text)
        h.settle()
        let parkedOffset = h.offset
        // Terminal, as the view model does it: the settled reply appended
        // and the stream cleared in the same update.
        h.model.messages.append(PsmithMessage(
            id: "a-final", contextID: "context-conv-1-1", parentID: "a19", role: .assistant, content: text
        ))
        h.hub.clear(conversationID: h.model.conversation.id)
        h.settle(0.8)
        #expect(h.documentHeight > 6_000)
        // Not dragged to the bottom of the long reply: the viewport stays
        // on its start.
        #expect(h.distanceFromBottom > 3_000)
        #expect(abs(h.offset - parkedOffset) < 120)
    }

    @Test
    func sendingCatchesUpFromAnywhere() {
        let h = host(messages: Self.turns(30))
        defer { h.window.orderOut(nil) }
        h.scrollUp(by: 1_200)
        #expect(h.distanceFromBottom > 600)
        h.model.pendingUserText = "a new question"
        h.settle(0.6)
        #expect(abs(h.distanceFromBottom) < 2)
    }
}

private extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
