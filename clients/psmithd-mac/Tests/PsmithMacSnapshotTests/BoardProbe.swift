import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI
import SnapshotHarness

/// Renders the main window with the boards' own content (the "Main
/// window" page of the redesign canvas), offscreen, so a capture and its
/// board can be compared pixel for pixel. Runs only when PSMITH_LIVE_PROBE
/// names the shots directory; PSMITH_PROBE_SIZE ("1280x800") and
/// PSMITH_PROBE_ONLY ("Conversation,InspectorContext") narrow it.
@MainActor
struct BoardProbe {
    nonisolated static let shots = ProcessInfo.processInfo.environment["PSMITH_LIVE_PROBE"] ?? ""

    // MARK: Board fixtures

    static let profiles: [PsmithProfile] = [
        profile("p-demo", "Demo Assistant", "A general helper with web search and grounding.", isDefault: true),
        profile("p-pirate", "Pirate Tutor", "Teaches fractions and decimals, in character.", favorite: true),
        profile("p-council", "Pricing Council", "Three personas argue a pricing question out."),
        profile("p-travel", "Travel Planner", "Itineraries with real opening hours."),
        profile("p-chief", "Chief of Staff", "Your calendar, reminders and notes."),
    ]

    static func profile(_ id: String, _ name: String, _ desc: String, isDefault: Bool = false, favorite: Bool = false) -> PsmithProfile {
        SnapshotFixtures.profile(id: id, name: name, description: desc, favorite: favorite, isDefault: isDefault)
    }

    static func conversation(_ id: String, _ title: String, _ profileID: String, daysAgo: Double, hour: Int, minute: Int, pinned: Bool = false) -> PsmithConversation {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -Int(daysAgo), to: cal.startOfDay(for: Date()))!
        let at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        return PsmithConversation(id: id, profileID: profileID, title: title, activeContextID: "context-\(id)-2",
                                  ownerUserID: "user-fixed-1", createdAt: at, updatedAt: at, lastActivityAt: at,
                                  pinnedAt: pinned ? at : nil)
    }

    static let conversations: [PsmithConversation] = [
        conversation("c-weekly", "Weekly planning", "p-chief", daysAgo: 3, hour: 9, minute: 0, pinned: true),
        conversation("c-scroll", "Scroll architecture review", "p-demo", daysAgo: 0, hour: 0, minute: 14),
        conversation("c-pirate", "Pirate tutor: fractions", "p-pirate", daysAgo: 0, hour: 0, minute: 10),
        conversation("c-tax", "Tax documents checklist", "p-demo", daysAgo: 0, hour: 0, minute: 2),
        conversation("c-md", "Markdown showcase", "p-demo", daysAgo: 1, hour: 16, minute: 40),
        conversation("c-council", "Council: pricing debate", "p-council", daysAgo: 1, hour: 9, minute: 15),
        conversation("c-arch", "Architecture tour", "p-demo", daysAgo: 4, hour: 10, minute: 0),
        conversation("c-lisbon", "Trip to Lisbon", "p-travel", daysAgo: 5, hour: 10, minute: 0),
        conversation("c-sourdough", "Sourdough timing", "p-demo", daysAgo: 6, hour: 10, minute: 0),
    ]

    static func usage(cachedPct: Double) -> PsmithMessageUsage {
        let prompt: Int32 = 12_480
        let read = Int32(Double(prompt) * cachedPct)
        return PsmithMessageUsage(inputTokens: prompt, outputTokens: 214, cacheReadTokens: read, cacheWriteTokens: 0,
                                  reasoningTokens: nil, inputCostUsd: 0.0113, outputCostUsd: 0.0161,
                                  cacheReadCostUsd: 0.0018, cacheWriteCostUsd: 0, totalCostUsd: 0.0450)
    }

    static let thread: [PsmithMessage] = {
        let ctx = "context-c-scroll-2"
        return [
            PsmithMessage(id: "m1", contextID: ctx, role: .user, content: "Why does the stream jump when a long reply finishes?"),
            PsmithMessage(id: "m2", contextID: ctx, parentID: "m1", role: .assistant,
                          content: """
                          Because the settled message replaced the live row in the same update, and layout ran before the view heard the stream end. With nothing telling it otherwise, the follow logic pinned the viewport to the new bottom: the end of the reply instead of its start.

                          The fix ends the stream wherever it's first seen, before any pin:

                          ```
                          if streamActive, !model.isStreaming { endStream(proxy) }
                          ```
                          """,
                          providerID: "provider-anthropic", modelID: "claude-opus-4-7", usage: usage(cachedPct: 0.94),
                          thinkingRenderedText: "The swap and the pin land in one update.", thinkingDurationMs: 6_200),
            PsmithMessage(id: "m3", contextID: ctx, parentID: "m2", role: .user, content: "And the compression summary card: same problem?"),
            PsmithMessage(id: "m4", contextID: ctx, parentID: "m3", role: .assistant,
                          content: """
                          Yes, and it's worse there. The card swaps from the compacting row to the summary in one update, and the card is taller than the row it replaces, so the pin lands even further down.

                          The same fix covers it. The compacting row and the streaming row share one end-of-stream path, so ending the stream before the swap keeps the card's header in view.
                          """,
                          providerID: "provider-anthropic", modelID: "claude-opus-4-7", usage: usage(cachedPct: 0.91),
                          toolCalls: [PsmithToolCall(id: "t1", name: "grep", elapsedMs: 400), PsmithToolCall(id: "t2", name: "read_file", elapsedMs: 200)]),
        ]
    }()

    // MARK: Rendering

    struct Scene {
        let rig: LiveProbe.Rig
        let convos: ConversationsModel
        var model: ConversationViewModel
        init(rig: LiveProbe.Rig, convos: ConversationsModel, model: ConversationViewModel) {
            self.rig = rig; self.convos = convos; self.model = model
        }
    }

    static func scene(size: CGSize, selected: String? = "c-scroll", connectivity: ConnectivityMonitor.State = .online) -> Scene {
        let app = SnapshotStubs.makeAppModel(profiles: profiles, connectivityState: connectivity)
        let rig = LiveProbe.Rig(app: app, size: size)
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: conversations, profiles: profiles, selectedID: selected)
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: conversations[1], client: app.client, messages: thread,
            contexts: [SnapshotFixtures.context(id: "context-c-scroll-1", conversationID: "c-scroll", messageCount: 92, lastMessageTotalTokens: 151_000, cumulativeCostUsd: 1.92),
                       SnapshotFixtures.context(id: "context-c-scroll-2", conversationID: "c-scroll", parentContextID: "context-c-scroll-1", messageCount: 36, lastMessageTotalTokens: 82_140, cumulativeCostUsd: 0.4183)],
            tokenCount: 82_140)
        return Scene(rig: rig, convos: convos, model: model)
    }

    /// The window as HomeView lays it out, with the reading pane's model
    /// prepared instead of loaded.
    struct Window: View {
        let convos: ConversationsModel
        let model: ConversationViewModel?
        @State var archived = false
        @State var width: Double = MK.listWidth
        @Environment(Navigator.self) private var navigator

        var body: some View {
            HStack(spacing: 0) {
                if navigator.listShown {
                    MainListColumn(user: SnapshotFixtures.user(username: "john"), showingArchived: $archived, width: $width)
                        .frame(width: CGFloat(width))
                }
                Group {
                    if let model {
                        ConversationBody(model: model, liveConversation: model.conversation)
                    } else {
                        WelcomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .environment(convos)
        }
    }

    @Test(.enabled(if: !shots.isEmpty))
    func boards() async throws {
        let sz = (ProcessInfo.processInfo.environment["PSMITH_PROBE_SIZE"] ?? "1280x800").split(separator: "x").compactMap { Double($0) }
        let size = CGSize(width: sz[0], height: sz[1])
        let only = ProcessInfo.processInfo.environment["PSMITH_PROBE_ONLY"].flatMap { $0.isEmpty ? nil : $0.split(separator: ",").map(String.init) }
        func wanted(_ n: String) -> Bool { only == nil || only!.contains(n) }
        let saved = sharedThemeStore.current
        sharedThemeStore.current = .slate
        defer { sharedThemeStore.current = saved }
        let tag = "\(Int(size.width))"

        func shoot(_ name: String, selected: String? = "c-scroll", connectivity: ConnectivityMonitor.State = .online,
                   setup: (inout Scene) -> Void = { _ in }, content: ((Scene) -> AnyView)? = nil) async {
            guard wanted(name) else { return }
            var s = Self.scene(size: size, selected: selected, connectivity: connectivity)
            setup(&s)
            if let content {
                s.rig.mount(content(s).environment(s.convos))
            } else {
                s.rig.mount(Window(convos: s.convos, model: selected == nil ? nil : s.model))
            }
            s.rig.window.setContentSize(size)
            await s.rig.pump(0.3)
            // Once on screen the window can become main, which is when
            // the app's chrome configuration applies to it.
            AppDelegate.configure(s.rig.window)
            await s.rig.pump(1.2)
            s.rig.snap("\(tag)-\(name)")
            s.rig.window.orderOut(nil)
        }

        await shoot("Conversation")
        await shoot("InspectorContext") { $0.rig.navigator.inspectorShown = true; $0.rig.navigator.inspectorTab = .context }
        await shoot("InspectorSettings") { $0.rig.navigator.inspectorShown = true; $0.rig.navigator.inspectorTab = .settings }
        await shoot("InspectorPlugins") { $0.rig.navigator.inspectorShown = true; $0.rig.navigator.inspectorTab = .plugins }
        await shoot("Welcome", selected: nil)
        await shoot("ListHidden") { $0.rig.navigator.listShown = false }
        await shoot("MessageStates") { s in
            let ctx = "context-c-scroll-2"
            s.model.messages = [
                PsmithMessage(id: "s0", contextID: ctx, role: .system, content: "You are a careful reviewer of scroll and layout code. Answer with the cause first, then the fix."),
                PsmithMessage(id: "s1", contextID: ctx, parentID: "s0", role: .user, content: "Why does the stream jump when a long reply finishes?"),
                PsmithMessage(id: "s2", contextID: ctx, parentID: "s1", role: .assistant,
                              content: "Because the settled message replaced the live row in the same update. The follow logic pinned the viewport to the new bottom: the end of the reply instead of its start.",
                              providerID: "provider-anthropic", modelID: "claude-opus-4-7", usage: Self.usage(cachedPct: 0.94), finishReason: "max_tokens"),
                PsmithMessage(id: "s3", contextID: ctx, parentID: "s2", role: .user, content: "Try again with the full trace."),
                PsmithMessage(id: "s4", contextID: ctx, parentID: "s3", role: .assistant, content: "Partial", providerID: "provider-anthropic", modelID: "claude-opus-4-7",
                              errorText: "Anthropic returned 529: the API is overloaded. Try again in a moment."),
            ]
        }
        await shoot("Streaming") { s in
            s.model = SnapshotStubs.makeConversationViewModel(
                conversation: Self.conversations[1], client: s.rig.app.client,
                messages: [PsmithMessage(id: "u", contextID: "context-c-scroll-2", role: .user, content: "Walk me through the follow-then-park rules.")],
                tokenCount: 82_140, streamRunID: "r",
                streamingText: "Entry anchors at the newest message. While the view sits at the bottom, any growth re-pins it there.\n\nA scroll gesture lets go immediately. When it settles, following resumes only within 32 points of the bottom.")
        }
        await shoot("Resend") { s in
            s.model.messages = Self.thread + [PsmithMessage(id: "m5", contextID: "context-c-scroll-2", parentID: "m4", role: .user, content: "And for the welcome reveal?")]
        }
        await shoot("Council", selected: "c-council") { s in
            s.model.messages = SnapshotFixtures.councilMessages(contextID: "context-c-scroll-2")
        }
        await shoot("Review") { s in
            s.model.messages = Array(Self.thread.prefix(2)) + [SnapshotFixtures.compressionSummaryMessage(contextID: "context-c-scroll-2")]
        }
        await shoot("ReviewTruncated") { s in
            s.model.messages = Array(Self.thread.prefix(2)) + [SnapshotFixtures.compressionSummaryMessage(contextID: "context-c-scroll-2", finishReason: "max_tokens")]
        }
        await shoot("Compacting") { s in
            s.model = SnapshotStubs.makeConversationViewModel(
                conversation: Self.conversations[1], client: s.rig.app.client, messages: Self.thread, tokenCount: 82_140,
                streamingText: "The conversation reviews why the transcript jumps when a long reply finishes.", isCompacting: true)
        }
        await shoot("Banners") { s in
            s.model.loadError = "Couldn’t load newer messages: the request timed out."
            s.model.compactError = "Claude Haiku 4.5 can’t fit 82,140 tokens."
        }
        await shoot("ModelPage") { $0.rig.navigator.page = .models }
        await shoot("CallSettingsPage") { $0.rig.navigator.page = .callSettings }
        await shoot("FullText") { $0.rig.navigator.page = .fullText(title: "Full text", markdown: String(repeating: "The eager stack makes every offset exact, so the follow logic never has to guess where a row will land. ", count: 30)) }
        await shoot("ListOffline", connectivity: .offline)
        let draft = ConversationViewModel.draft(client: SnapshotStubs.makeClient(), hub: StreamHub(subscriber: SnapshotStubs.makeClient().streams), onTerminal: {})
        await draft.chooseDraftProfile(Self.profiles[0])
        draft.availableModels = [SnapshotFixtures.userModel()]
        draft.selectedProviderID = "provider-anthropic"
        draft.selectedModelID = "claude-opus-4-7"
        await shoot("Draft", selected: nil, content: { s in AnyView(Window(convos: s.convos, model: draft)) })
        await shoot("LoginServer", selected: nil, content: { _ in AnyView(LoginView().ignoresSafeArea()) })
        await shoot("Compress") { $0.model.showingCompactView = true; $0.model.compactPromptDraft = "Summarize the conversation so far for a fresh context. Keep decisions, open questions, names and numbers. Drop pleasantries and anything already resolved." }
    }
}
