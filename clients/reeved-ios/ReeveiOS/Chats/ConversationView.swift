import SwiftUI
import ReeveKit
import ReeveUI

/// iOS conversation surface. Constructs `ConversationViewModel` against
/// the live `reeved`, then renders the status strip + message scroll.
/// Per `docs/ios-screens.md` §2.5: composer arrives in Phase 5d, the
/// page-replace alternates (Compact / Contexts / Settings / Model
/// Picker) become push/sheet destinations in Phase 5g.
struct ConversationView: View {
    let conversation: ReeveConversation
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.notifier) private var notifier
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ConversationViewModel?

    var body: some View {
        Group {
            if let model {
                ConversationBody(model: model, liveConversation: liveConversation)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Per `docs/ios-screens.md` §1.8 + §4.1: cancel the live
            // SSE on background, re-subscribe from the last seen
            // sequence on foreground. Supervisor keeps streaming the
            // whole time and persists chunks to stream_chunks; replay
            // is correct-by-construction.
            guard let m = model else { return }
            switch newPhase {
            case .background, .inactive:
                m.suspendActiveStream()
            case .active:
                m.resumeStreamIfPaused()
            @unknown default:
                break
            }
        }
        .task(id: conversation.id) {
            // Capture env-injected notifier into the closure so the VM-side
            // firing path doesn't reach into a global. iOS Notifier impl
            // arrives in Phase 8b; for now `\.notifier` resolves to the
            // NoopNotifier default.
            let liveNotifier = notifier
            let m = ConversationViewModel(
                conversation: conversation,
                client: app.client,
                onTerminal: { [weak convos] in await convos?.refresh() },
                onAssistantTurnComplete: { convID, title, msgID, preview in
                    liveNotifier.generationCompleted(
                        conversationID: convID,
                        conversationTitle: title,
                        messageID: msgID,
                        preview: preview
                    )
                }
            )
            self.model = m
            await m.load()
            // Loaded alongside the message list so the model chip
            // can show the display name (not just the model id) and
            // contexts toolbar item knows the count up-front.
            await m.loadContexts()
            await m.loadAvailableModels()
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Always read the latest snapshot from the list so an auto-generated
    /// title propagates without forcing a remount of this view.
    private var liveConversation: ReeveConversation {
        convos.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private var navTitle: String {
        let title = liveConversation.title?.isEmpty == false ? liveConversation.title! : "Untitled"
        return title
    }
}

// MARK: - Conversation body (separated for env injection of model)

private struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: ReeveConversation

    /// Auto-follow tracking — same machinery the Mac uses, so the
    /// streaming bubble stays pinned to the bottom unless the user
    /// actively scrolls up.
    @State private var autoFollow = true
    @State private var lastAutoScroll: Date = .distantPast
    @State private var showingMissingCostInfo = false

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            if let err = model.loadError, !model.messages.isEmpty {
                loadErrorBanner(err)
            }
            messageScroll
            Composer(model: model)
        }
        .refreshable {
            await model.load()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showingCompactView = true
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(model.isStreaming || model.isCompacting)
                .accessibilityLabel("Compact")
            }
        }
        .sheet(isPresented: $model.showingCompactView) {
            CompactView(model: model)
        }
        .toast(
            message: Binding(
                get: { model.lastPromotedContextID == nil ? nil : "Switched to new context" },
                set: { _ in model.lastPromotedContextID = nil }
            ),
            systemImage: "wand.and.stars"
        )
        // Note: model-picker sheet is presented from the Composer
        // itself. SwiftUI doesn't reliably dispatch multiple
        // `.sheet(isPresented:)` modifiers from the same anchor;
        // attaching the picker at its trigger view sidesteps the
        // race.
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 8) {
            costChip
            if let context = activeContextLabel {
                NavigationLink {
                    ContextListView(model: model)
                } label: {
                    HStack(spacing: 3) {
                        chipLabel(text: context, systemImage: "tray.full")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open contexts")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chipLabel(text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    /// Cost chip with a best-effort total + a (!) tap target when
    /// any assistant message in the active context has usage data
    /// but no per-token price (subscription / flat-fee models like
    /// Z.AI Coding Plan don't populate per-million pricing in
    /// `user_models`, so the cost rolls up as $0). Tapping the
    /// warning lists which models contributed cost-less turns so
    /// the user can decide whether to wire prices in.
    @ViewBuilder
    private var costChip: some View {
        // Show even when the rollup is zero — better than vanishing
        // silently. The (!) makes the missing-data case legible.
        let total = accruedCost
        let label = String(format: "$%.4f", total)
        HStack(spacing: 6) {
            chipLabel(text: label, systemImage: "dollarsign.circle")
            if !modelsMissingCost.isEmpty {
                Button {
                    showingMissingCostInfo = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cost data missing")
            }
        }
        .alert(
            "Cost is approximate",
            isPresented: $showingMissingCostInfo
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            let names = modelsMissingCost.joined(separator: "\n• ")
            Text("Some turns ran on models without per-token pricing in your catalog, so they're not included in the running total:\n\n• \(names)")
        }
    }

    /// Sum of every assistant message's `totalCostUsd` in the active
    /// context. Messages with nil cost contribute nothing — those
    /// are the ones the warning chip surfaces. Computed off
    /// `model.messages` (the linear chain currently visible) rather
    /// than the contexts aggregate so the value reflects what's on
    /// screen even on cold cache hits.
    private var accruedCost: Double {
        model.messages.reduce(0) { acc, m in
            acc + (m.usage?.totalCostUsd ?? 0)
        }
    }

    /// Distinct display-name list of models that produced an assistant
    /// message with usage data (real LLM call) but no totalCostUsd
    /// (no per-token price). Sorted, deduped.
    private var modelsMissingCost: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for m in model.messages {
            guard m.role == .assistant,
                  m.usage != nil,
                  m.usage?.totalCostUsd == nil,
                  let mid = m.modelID else { continue }
            // Resolve to display name when we know it; otherwise fall
            // back to the raw id so the user can still identify it.
            let pid = m.providerID
            let display = model.availableModels
                .first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) })?
                .displayName ?? mid
            if seen.insert(display).inserted {
                out.append(display)
            }
        }
        return out.sorted()
    }

    /// Header pill label for the active context. Numbering matches the
    /// Contexts list (chronological by createdAt) so "Context 2" in
    /// the header points at the same row the user sees in the list.
    /// Hidden when there's only one context in the conversation —
    /// the pill carries no signal in that case.
    private var activeContextLabel: String? {
        guard let ctx = model.activeContext, model.contexts.count > 1 else { return nil }
        let chronological = model.contexts.sorted { $0.createdAt < $1.createdAt }
        let idx = (chronological.firstIndex(where: { $0.id == ctx.id }) ?? 0) + 1
        return "Context \(idx)"
    }

    private func loadErrorBanner(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { model.loadError = nil }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Message scroll

    @ViewBuilder
    private var messageScroll: some View {
        if let err = model.loadError, model.messages.isEmpty {
            EmptyStateView(
                "Failed to load",
                systemImage: "exclamationmark.triangle",
                description: "\(err)"
            )
        } else if model.loading && model.messages.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                paneScrollBody
                    .environment(\.chatPaneWidth, geo.size.width)
            }
        }
    }

    @ViewBuilder
    private var paneScrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { msg in
                        if msg.role == .compressionSummary {
                            CompressionSummaryCard(message: msg, model: model)
                                .id(msg.id)
                        } else {
                            MessageRow(message: msg, model: model)
                                .id(msg.id)
                        }
                    }
                    if let pending = model.pendingUserText {
                        PendingUserRow(text: pending)
                            .id("__pending__")
                    }
                    if !model.streamingText.isEmpty || model.isStreaming {
                        StreamingRow(
                            text: model.streamingText,
                            thinkingText: model.streamingThinking,
                            thinkingStartedAt: model.streamingThinkingStartedAt,
                            thinkingFinishedAt: model.streamingThinkingFinishedAt,
                            thinkingExpanded: $model.streamingThinkingExpanded,
                            toolCalls: model.streamingToolCalls
                        )
                        .id("__streaming__")
                    }
                }
                .padding()
                // Tap-to-dismiss for the composer keyboard.
                // `scrollDismissesKeyboard(.interactively)` (below)
                // alone needs actual scroll motion to fire — on a
                // short chain it never triggers, so the user has no
                // way to drop focus without sending or hitting a
                // button. simultaneousGesture lets row taps + bubble
                // long-presses keep working.
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
            }
            .onAppear {
                if let id = model.messages.last?.id {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .top) }
            }
            .onChange(of: model.pendingUserText) { _, text in
                if text != nil {
                    autoFollow = true
                    withAnimation { proxy.scrollTo("__pending__", anchor: .top) }
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming { autoFollow = true }
            }
            .onChange(of: model.streamingText) { _, _ in
                guard autoFollow else { return }
                let now = Date()
                if now.timeIntervalSince(lastAutoScroll) >= 0.1 {
                    lastAutoScroll = now
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo("__streaming__", anchor: .bottom)
                    }
                }
            }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    autoFollow = false
                case .idle, .animating:
                    break
                @unknown default:
                    break
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

}
