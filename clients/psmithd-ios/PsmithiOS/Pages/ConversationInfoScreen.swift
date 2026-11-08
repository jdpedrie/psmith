import SwiftUI
import PsmithKit
import PsmithUI

/// The conversation's Info page (boards ConversationInfo, InfoContextDelete,
/// InfoSettings, InfoPlugins): three tabs over one pushed page.
/// Context holds the token gauge, the contexts and the conversation's own
/// actions; Settings reads out what the next send runs with; Plugins edits
/// this conversation's plugin overrides behind an explicit save.
struct ConversationInfoScreen: View {
    enum Tab: Hashable { case context, settings, plugins }

    @Bindable var model: ConversationViewModel
    @State var tab: Tab = .context
    /// Snapshot tests mount the page with its data already in place.
    var autoload = true

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var prepared = false
    @State var staging = PluginStaging()

    init(model: ConversationViewModel, tab: Tab = .context, autoload: Bool = true, staging: PluginStaging? = nil) {
        self.model = model
        _tab = State(initialValue: tab)
        self.autoload = autoload
        _staging = State(initialValue: staging ?? PluginStaging())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKSegmented(options: [(Tab.context, "Context"), (.settings, "Settings"), (.plugins, "Plugins")],
                            selection: $tab)
                if let err = model.settingsError {
                    IKBanner(systemImage: "exclamationmark.triangle", text: err) { model.settingsError = nil }
                        .padding(.top, 14)
                }
                switch tab {
                case .context: InfoContextTab(model: model)
                case .settings: InfoSettingsTab(model: model)
                case .plugins: InfoPluginsTab(model: model, staging: staging)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .ikConversationPage("Info")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let pending = staging.pending(model).count
            if tab == .plugins && pending > 0 {
                IKSaveBar(summary: IKCallSettingsDiff.summary(pending), ground: .themed, canSave: !staging.saving,
                          onRevert: { staging.revert() },
                          onSave: { Task { await staging.save(model) } })
            }
        }
        .task {
            guard autoload, !prepared else { return }
            prepared = true
            async let contexts: Void = model.loadContexts()
            async let settings: Void = model.prepareSettingsView()
            _ = await (contexts, settings)
        }
    }
}

// MARK: - Context tab

struct InfoContextTab: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ikPopToRoot) private var popToRoot
    @State var confirmingContextDelete: String?
    @State var confirmingConversationDelete = false
    @State private var creatingContext = false

    init(model: ConversationViewModel, confirmingContextDelete: String? = nil) {
        self.model = model
        _confirmingContextDelete = State(initialValue: confirmingContextDelete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gauge.padding(.top, 14)

            IKPageHead(text: "Contexts")
            IKPageGroup {
                ForEach(sorted) { ctx in
                    if confirmingContextDelete == ctx.id {
                        contextDeleteCard(ctx).padding(8)
                    } else {
                        contextRow(ctx)
                    }
                }
            }
            IKPageNote("Swipe a past context to delete it. Its summary in the current context stays.")

            IKPageHead(text: "This context")
            IKPageGroup {
                IKPageRow(title: "Cache hits, last 10 replies") { value(cacheHits) }
                IKPageRow(title: "Branches") { value(branches) }
                IKPageRow(title: "Profile") {
                    HStack(spacing: 6) {
                        if let p = profile { IKDot(color: ProfileColor.color(for: p.id, theme: theme)) }
                        value(profile?.name ?? "None")
                    }
                }
            }

            actions.padding(.top, 18)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creatingContext = true } label: { Image(systemName: "plus").foregroundStyle(IK.text) }
                    .accessibilityLabel("New context")
            }
        }
        .navigationDestination(isPresented: $creatingContext) {
            NewContextScreen(model: model) { creatingContext = false; dismiss() }
        }
    }

    // MARK: Gauge

    private var gauge: some View {
        let tokens = Int(model.contextTokens ?? 0)
        let window = Int(model.contextWindow ?? 0)
        let frac = window > 0 ? min(Double(tokens) / Double(window), 1) : 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tokens.formatted()).font(.system(size: 28, weight: .bold)).tracking(-0.5).monospacedDigit()
                    .foregroundStyle(IK.text)
                Text(window > 0 ? "of \(window.formatted()) tokens" : "tokens")
                    .font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                Spacer(minLength: 0)
                if window > 0 {
                    Text("\(Int((frac * 100).rounded()))%").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accentInk)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(IK.wash(0.08))
                    Capsule().fill(theme.accent).frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 6)
            .padding(.top, 10)
            HStack {
                Text(warnText)
                Spacer(minLength: 8)
                Text("\(IKFormat.cost(activeCost)) here · \(IKFormat.cost(model.conversationCost)) in all")
            }
            .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
            .padding(.top, 10)
            IKWashButton(title: "Compress into a New Context", systemImage: "arrow.up.and.down.text.horizontal") {
                model.showingCompactView = true
                dismiss()
            }
            .padding(.top, 12)
            .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.06), lineWidth: 1))
    }

    private var warnText: String {
        let t = Int(app.preferences.preferences.contextWarningTokens)
        guard t > 0 else { return "No warning set" }
        if let w = model.contextWindow, w > 0 { return "Warns at \(Int((Double(t) / Double(w) * 100).rounded()))%" }
        return "Warns at \(t.formatted()) tokens"
    }

    private var activeCost: Double {
        model.activeContext.flatMap { a in model.contexts.first { $0.id == a.id } }?.cumulativeCostUsd ?? 0
    }

    // MARK: Contexts

    private var sorted: [PsmithContext] { model.contexts.sorted { $0.createdAt > $1.createdAt } }

    private func label(_ ctx: PsmithContext) -> String {
        if let t = ctx.title, !t.isEmpty { return t }
        return "Context \(model.contextNumber(for: ctx.id) ?? 0)"
    }

    private func contextRow(_ ctx: PsmithContext) -> some View {
        let active = ctx.id == model.activeContext?.id
        var parts = ["\(ctx.messageCount) messages"]
        if ctx.lastMessageTotalTokens > 0 { parts.append("\(IKFormat.grouped(ctx.lastMessageTotalTokens)) tokens") }
        parts.append(IKFormat.cost(ctx.cumulativeCostUsd))
        return Button {
            if active { dismiss(); return }
            Task { await model.activateContext(ctx.id); dismiss() }
        } label: {
            IKPageRow(title: active ? "\(label(ctx)) · current" : label(ctx), detail: parts.joined(separator: " · "),
                      bold: active) { IKPageChevron() }
                .background(active ? theme.selection.opacity(0.6) : .clear)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { g in
            if !active, g.translation.width < -60, abs(g.translation.height) < 30 {
                withAnimation(.snappy) { confirmingContextDelete = ctx.id }
            }
        })
        .contextMenu {
            if active {
                Label("The current context can’t be deleted", systemImage: "info.circle")
            } else {
                Button(role: .destructive) { confirmingContextDelete = ctx.id } label: {
                    Label("Delete Context", systemImage: "trash")
                }
            }
        }
        .accessibilityAction(named: "Delete") { if !active { confirmingContextDelete = ctx.id } }
    }

    private func contextDeleteCard(_ ctx: PsmithContext) -> some View {
        let current = model.activeContext.map(label) ?? "The current context"
        return IKConfirmCard(
            question: "Delete \(label(ctx).lowercasedFirst)?",
            detail: "Its \(ctx.messageCount) messages are deleted for good. \(current) and the summary that started it stay.",
            onCancel: { withAnimation(.snappy) { confirmingContextDelete = nil } },
            onConfirm: {
                let id = ctx.id
                confirmingContextDelete = nil
                Task { await model.deleteContext(id) }
            }
        )
    }

    // MARK: This context

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 15.5)).foregroundStyle(IK.secondary).monospacedDigit()
    }

    private var cacheHits: String {
        let replies = model.messages.filter { $0.role == .assistant && $0.usage != nil }.suffix(10)
        var cached: Int64 = 0, prompt: Int64 = 0
        for m in replies {
            guard let u = m.usage, let input = u.inputTokens else { continue }
            let c = Int64(u.cacheReadTokens ?? 0)
            let i = Int64(input)
            cached += c
            prompt += c > i ? i + c : i
        }
        guard prompt > 0 else { return "None yet" }
        return "\(Int((Double(cached) / Double(prompt) * 100).rounded()))%"
    }

    private var branches: String {
        for (i, m) in model.messages.enumerated().reversed() {
            if let info = model.branchInfo(for: m.id), info.siblingIDs.count > 1 {
                return "\(info.siblingIDs.count) at message \(i + 1)"
            }
        }
        return "None"
    }

    private var profile: PsmithProfile? {
        app.profiles.profiles.first { $0.id == model.conversation.profileID } ?? model.settingsResolvedProfile
    }

    // MARK: Conversation actions

    private var live: PsmithConversation {
        convos.conversations.first { $0.id == model.conversation.id }
            ?? convos.archivedConversations.first { $0.id == model.conversation.id }
            ?? model.conversation
    }

    @ViewBuilder
    private var actions: some View {
        if confirmingConversationDelete {
            IKConfirmCard(question: "Delete this conversation?",
                          detail: "Every context and message in it is deleted for good.",
                          onCancel: { withAnimation(.snappy) { confirmingConversationDelete = false } },
                          onConfirm: {
                              let id = live.id, archived = live.archivedAt != nil
                              Task {
                                  if archived { await convos.deleteArchived(id) } else { await convos.delete(id) }
                              }
                              leave()
                          })
        } else {
            IKPageGroup {
                if live.archivedAt == nil {
                    actionRow(live.pinnedAt == nil ? "Pin" : "Unpin") { Task { await convos.togglePin(live.id) } }
                    actionRow("Archive") {
                        let id = live.id
                        Task { await convos.archive(id) }
                        leave()
                    }
                } else {
                    actionRow("Unarchive") { Task { await convos.unarchive(live.id) } }
                }
                actionRow("Delete Conversation", color: IK.red) {
                    withAnimation(.snappy) { confirmingConversationDelete = true }
                }
            }
        }
    }

    private func actionRow(_ title: String, color: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { IKPageRow(title, titleColor: color ?? theme.accentInk) }
            .buttonStyle(.plain)
    }

    private func leave() {
        if let popToRoot { popToRoot() } else { dismiss() }
    }
}

extension String {
    /// "Context 1" reads "context 1" mid-sentence; a custom title keeps its case.
    var lowercasedFirst: String {
        guard hasPrefix("Context ") else { return self }
        return prefix(1).lowercased() + dropFirst()
    }
}

// MARK: - New context

/// Starts a context by hand, without compressing: an optional opening
/// message, and whether to carry the prior context message over.
struct NewContextScreen: View {
    let model: ConversationViewModel
    let onCreate: () -> Void
    @State private var message = ""
    @State private var mode: PsmithCompressionMode = .replace
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKPageHead(text: "Opening message", topPadding: 4)
                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Optional. A first prompt for the new context.")
                            .font(.system(size: 16)).foregroundStyle(IK.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    TextEditor(text: $message)
                        .font(.system(size: 16)).foregroundStyle(IK.text)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .frame(minHeight: 140)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.06), lineWidth: 1))

                IKPageHead(text: "Prior context message")
                IKSegmented(options: [(PsmithCompressionMode.replace, "Replace"), (.append, "Append")], selection: $mode)
                IKPageNote(mode == .replace
                           ? "The new context starts fresh, with no prior context message."
                           : "The new context keeps this conversation’s prior context message as it is.")

                Button {
                    creating = true
                    Task {
                        await model.createContextManual(
                            initialUserMessage: message.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
                        creating = false
                        onCreate()
                    }
                } label: {
                    Text(creating ? "Creating…" : "Create Context").frame(maxWidth: .infinity)
                }
                .ikButton(.primary, height: 44, fill: true)
                .disabled(creating)
                .padding(.top, 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .ikConversationPage("New Context")
    }
}
