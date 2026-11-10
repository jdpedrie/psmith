import SwiftUI
import Charts
import PsmithKit
import PsmithUI

/// The inspector beside the reading pane (boards AppInspectorContext,
/// AppInspectorSettings, AppInspectorPlugins): what this conversation is
/// costing and how big it is, its call settings, and the plugins running
/// for it. Settings' groups and rows, on the list column's ground.
struct ConversationInspector: View {
    @Bindable var model: ConversationViewModel
    @Binding var tab: InspectorTab
    var preparesSettings = true

    var body: some View {
        VStack(spacing: 0) {
            MKHeaderBand(ground: .well) {
                SKSegmented(options: InspectorTab.allCases.map { ($0, $0.rawValue) }, selection: $tab, fill: true)
            }
            .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .context: ContextInspector(model: model)
                    case .settings: CallSettingsSummary(model: model, prepares: preparesSettings)
                    case .plugins: PluginsInspector(model: model)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Under the empty toolbar's band: its edge effect would blur
            // the top rows. The header above is solid already.
            .scrollEdgeEffectHidden(true, for: .top)
        }
    }
}

/// One reply's context size and cost, for the inspector's charts.
struct TurnSample: Identifiable, Equatable {
    let id: String
    let index: Int
    let contextTokens: Int
    let cost: Double?
    let cacheMiss: Bool

    static func samples(from messages: [PsmithMessage]) -> [TurnSample] {
        var out: [TurnSample] = []
        for m in messages where m.role == .assistant {
            guard let u = m.usage, let input = u.inputTokens else { continue }
            let read = u.cacheReadTokens ?? 0
            let prompt = read > input ? Int(input) + Int(read) : Int(input)
            let total = prompt + Int(u.outputTokens ?? 0)
            let reportsCache = u.cacheReadTokens != nil || u.cacheWriteTokens != nil
            let miss = reportsCache && prompt >= Int(MessageRow.cacheGradeFloorTokens) && Double(read) / Double(max(prompt, 1)) < 0.3
            out.append(TurnSample(id: m.id, index: out.count + 1, contextTokens: total, cost: u.totalCostUsd, cacheMiss: out.isEmpty ? false : miss))
        }
        return out
    }
}

/// A card on the inspector's ground: Settings' card fill and ring.
private struct InspectorCard<Content: View>: View {
    var padding = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(MK.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.line, lineWidth: 1))
    }
}

/// A group header outside a card: "Contexts  2".
private struct InspectorHeading: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sk(12, SK.secondary, weight: .semibold)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).sk(12, SK.tertiary) }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 7)
    }
}

/// Label left, value right, at the inspector's row height.
private struct InspectorValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = SK.text
    var body: some View {
        SKRawRow(vertical: 7, horizontal: 12) {
            HStack {
                Text(label).sk(13)
                Spacer(minLength: 8)
                Text(value).sk(13, valueColor).monospacedDigit()
            }
        }
    }
}

private struct ContextInspector: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var deletingContextID: String?

    private var threshold: Int32 { app.preferences.preferences.contextWarningTokens }
    private var samples: [TurnSample] { TurnSample.samples(from: model.messages) }

    var body: some View {
        sizeCard
        Color.clear.frame(height: 18)
        totalsGroup
        if samples.count >= 2 {
            growthChart
            costChart
        }
        branchesGroup
        contextsList
    }

    private var warningTint: Color? {
        switch model.contextWarning(threshold: threshold) {
        case .nearWindow: SK.red
        case .overThreshold: SK.orange
        case nil: nil
        }
    }

    private var sizeCard: some View {
        let tokens = Int(model.contextTokens ?? 0)
        let window = Int(model.contextWindow ?? 0)
        return InspectorCard {
            HStack {
                Text("Context size").sk(13, weight: .semibold)
                Spacer(minLength: 8)
                Text("\(tokens.formatted()) tokens").sk(13, warningTint ?? SK.text, weight: .semibold).monospacedDigit()
            }
            if window > 0 {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                        Capsule().fill(warningTint ?? theme.accent)
                            .frame(width: max(4, w * min(1, Double(tokens) / Double(window))), height: 6)
                        if threshold > 0, Int(threshold) < window {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(SK.text)
                                .frame(width: 2, height: 14)
                                .offset(x: w * Double(threshold) / Double(window) - 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: 6)
                }
                .frame(height: 6)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .accessibilityElement()
                .accessibilityLabel("\(tokens.formatted()) of \(window.formatted()) tokens")
                HStack {
                    Text(threshold > 0 ? "Your warning: \(ContextWarning.compact(threshold))" : "No warning set")
                    Spacer(minLength: 8)
                    Text("Window: \(ContextWarning.compact(Int32(window)))")
                }
                .sk(11.5, SK.tertiary)
            }
            Button {
                model.showingCompactView = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11.5))
                    Text("Compress into a New Context…")
                }
                .frame(maxWidth: .infinity)
            }
            .skButton()
            .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression || model.messages.isEmpty)
            .padding(.top, 12)
        }
    }

    private var totalsGroup: some View {
        SKGroup("This context") {
            InspectorValueRow(label: "Cost", value: String(format: "$%.4f", accruedCost))
            InspectorValueRow(label: "Replies", value: "\(model.messages.filter { $0.role == .assistant }.count)")
            if let last = lastCache {
                InspectorValueRow(label: "Cache, last reply", value: last.text, valueColor: last.good ? SK.green : SK.text)
            }
            InspectorValueRow(label: "Model changes", value: "\(model.modelChangeMessageIDs.count)")
        } footer: {
            if !modelsMissingCost.isEmpty {
                Text("No pricing for \(modelsMissingCost.joined(separator: ", ")), so the cost leaves those turns out.")
                    .sk(11.5, SK.orange)
            }
        }
    }

    private var accruedCost: Double {
        if let ctx = model.activeContext, let row = model.contexts.first(where: { $0.id == ctx.id }) {
            return row.cumulativeCostUsd
        }
        return model.messages.reduce(0) { $0 + ($1.usage?.totalCostUsd ?? 0) }
    }

    private var lastCache: (text: String, good: Bool)? {
        guard let u = model.messages.last(where: { $0.role == .assistant && $0.usage != nil })?.usage,
              let input = u.inputTokens, input > 0,
              u.cacheReadTokens != nil || u.cacheWriteTokens != nil else { return nil }
        let read = u.cacheReadTokens ?? 0
        let prompt = read > input ? input + read : input
        let pct = Int((Double(read) / Double(prompt) * 100).rounded())
        return ("\(pct)% hit", pct >= 80)
    }

    private var modelsMissingCost: [String] {
        var seen = Set<String>()
        for m in model.messages {
            guard m.role == .assistant, m.usage != nil, m.usage?.totalCostUsd == nil, let mid = m.modelID else { continue }
            seen.insert(model.availableModels.first(where: { $0.modelID == mid })?.displayName ?? mid)
        }
        return seen.sorted()
    }

    private var growthChart: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeading(title: "Context over this run")
            InspectorCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                Chart {
                    ForEach(samples) { s in
                        LineMark(x: .value("Reply", s.index), y: .value("Tokens", s.contextTokens))
                            .foregroundStyle(theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(.monotone)
                    }
                    if threshold > 0 {
                        RuleMark(y: .value("Warning", Int(threshold)))
                            .foregroundStyle(SK.orange.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 84)
                HStack {
                    Text("1")
                    Spacer()
                    Text("\(samples.count) replies")
                }
                .sk(11, SK.tertiary)
            }
            .accessibilityLabel("Context size by reply, from \(ContextWarning.compact(Int32(samples.first?.contextTokens ?? 0))) to \(ContextWarning.compact(Int32(samples.last?.contextTokens ?? 0))) tokens")
        }
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var costChart: some View {
        let priced = samples.filter { $0.cost != nil }
        if !priced.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeading(title: "Cost per reply")
                InspectorCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                    Chart(priced) { s in
                        BarMark(x: .value("Reply", s.index), y: .value("Cost", s.cost ?? 0))
                            .foregroundStyle(s.cacheMiss ? SK.orange : theme.accent.opacity(0.75))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 56)
                    if priced.contains(where: \.cacheMiss) {
                        Text("Orange replies missed the cache on a large prompt.").sk(11, SK.tertiary).padding(.top, 6)
                    }
                }
            }
            .padding(.bottom, 22)
        }
    }

    @ViewBuilder
    private var branchesGroup: some View {
        let forks: [(turn: Int, info: (siblingIDs: [String], index: Int))] = model.messages.enumerated().compactMap { i, m in
            guard let info = model.branchInfo(for: m.id) else { return nil }
            return (i + 1, info)
        }
        if !forks.isEmpty {
            SKGroup("Branches") {
                ForEach(forks, id: \.turn) { fork in
                    InspectorValueRow(label: "Message \(fork.turn)", value: "\(fork.info.index + 1) of \(fork.info.siblingIDs.count)", valueColor: SK.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var contextsList: some View {
        if !model.contexts.isEmpty {
            InspectorHeading(title: "Contexts", trailing: "\(model.contexts.count)")
            VStack(spacing: 4) {
                ForEach(Array(model.contexts.enumerated()).reversed(), id: \.element.id) { i, ctx in
                    contextRow(ctx, number: i + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func contextRow(_ ctx: PsmithContext, number: Int) -> some View {
        let active = ctx.id == model.activeContext?.id
        let title = ctx.title?.isEmpty == false ? ctx.title! : "Context \(model.contextNumber(for: ctx.id) ?? number)"
        if deletingContextID == ctx.id {
            MKConfirmCard(question: "Delete \(title)?", detail: "Its \(ctx.messageCount) messages are removed. The other contexts are unchanged.", confirmLabel: "Delete Context") {
                deletingContextID = nil
            } onConfirm: {
                deletingContextID = nil
                Task { await model.deleteContext(ctx.id) }
            }
        } else {
            SKListItem(
                title: title,
                subtitle: "\(ctx.messageCount) messages · \(ContextWarning.compact(Int32(clamping: ctx.lastMessageTotalTokens))) · \(String(format: "$%.2f", ctx.cumulativeCostUsd))",
                selected: active,
                action: { if !active { Task { await model.activateContext(ctx.id) } } },
                lead: {
                    Image(systemName: active ? "checkmark" : "archivebox")
                        .font(.system(size: 11, weight: active ? .bold : .regular))
                        .foregroundStyle(active ? Color.white : SK.secondary)
                        .frame(width: 16)
                },
                trail: {
                    if active { Text("active").sk(11, .white.opacity(0.75)) }
                }
            )
            .help(active ? "The context you're in" : "Switch to this context")
            .contextMenu {
                Button("Switch to This Context") { Task { await model.activateContext(ctx.id) } }
                    .disabled(active)
                Divider()
                Button("Delete Context…", role: .destructive) { deletingContextID = ctx.id }
                    .disabled(active)
            }
            // The context menu is pointer-only; VoiceOver reaches delete here.
            .accessibilityActions {
                if !active {
                    Button("Delete Context…") { deletingContextID = ctx.id }
                }
            }
        }
    }
}

/// The call settings this conversation sends with, and where each comes
/// from. Editing opens a page in the reading column.
private struct CallSettingsSummary: View {
    @Bindable var model: ConversationViewModel
    var prepares = true
    @Environment(Navigator.self) private var navigator
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme

    private struct Line: Identifiable {
        let name: String
        let value: String
        let source: String
        var id: String { name }
    }

    private var lines: [Line] {
        let own = model.conversationCallSettingsDraft
        let inherited = model.resolvedCallSettings ?? PsmithCallSettings()
        func line<T>(_ name: String, _ path: KeyPath<PsmithCallSettings, T?>, _ show: (T) -> String) -> Line {
            if let v = own[keyPath: path] { return Line(name: name, value: show(v), source: "this conversation") }
            if let v = inherited[keyPath: path] { return Line(name: name, value: show(v), source: "inherited") }
            return Line(name: name, value: "Default", source: "model")
        }
        var out = [
            line("Temperature", \.temperature) { String(format: "%.2g", $0) },
            line("Top P", \.topP) { String(format: "%.2g", $0) },
            line("Max output", \.maxOutputTokens) { $0.formatted() },
            line("Top K", \.topK) { "\($0)" },
            line("Thinking", \.thinking) { $0.effort?.label ?? "Default" },
            line("Explicit cache", \.explicitCache) { $0 ? "On" : "Off" },
        ]
        let stops = own.stopSequences.isEmpty ? inherited.stopSequences : own.stopSequences
        if !stops.isEmpty {
            out.append(Line(name: "Stop sequences", value: "\(stops.count)", source: own.stopSequences.isEmpty ? "inherited" : "this conversation"))
        }
        return out
    }

    private var modelName: String {
        if let mid = model.selectedModelID, let pid = model.selectedProviderID,
           let m = model.availableModels.first(where: { $0.modelID == mid && $0.providerID == pid }) {
            return m.displayName
        }
        return model.selectedModelID ?? "None"
    }

    var body: some View {
        Group {
            if let err = model.settingsError {
                SKBanner(.warning, "Couldn’t load the call settings", message: err)
            }
            SKGroup {
                Button { navigator.page = .models } label: {
                    SKRow("Model", detail: profileName.map { "From \($0)" }) {
                        HStack(spacing: 6) {
                            Text(modelName).sk(13)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SK.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.preparingSettingsView {
                MKSpinner(size: 16).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                SKGroup("Call settings") {
                    ForEach(lines) { l in
                        SKRawRow(vertical: 6, horizontal: 12) {
                            HStack {
                                Text(l.name).sk(13)
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(l.value).sk(12.5, mono: true)
                                    Text(l.source).sk(10.5, l.source == "this conversation" ? theme.accentInk : SK.tertiary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Blue is set on this conversation. The rest is inherited.").sk(11.5, SK.tertiary)
                }
                Button { navigator.page = .callSettings } label: {
                    HStack(spacing: 4) {
                        Text("Edit Call Settings")
                        Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .skButton()
                .disabled(model.settingsError != nil && model.conversationCallSettingsDraft.isEmpty && model.resolvedCallSettings == nil)
            }
        }
        .task {
            if prepares { await model.prepareSettingsView() }
        }
    }

    private var profileName: String? {
        model.draftProfile?.name ?? convos.profiles.first(where: { $0.id == model.conversation.profileID })?.name
    }
}

/// The plugins running for this conversation, each switchable here
/// without touching the profile.
private struct PluginsInspector: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.theme) private var theme

    private var subtracted: [String] {
        let active = Set(model.resolvedPluginPipeline.map(\.pluginName))
        return model.conversationPluginOverrides
            .filter { $0.disabled && !active.contains($0.pluginName) }
            .map(\.pluginName)
    }

    var body: some View {
        content.task { await model.prepareSettingsView() }
    }

    @ViewBuilder
    private var content: some View {
        if model.resolvedPluginPipeline.isEmpty && subtracted.isEmpty {
            SKGroup("Running for this conversation") {
                SKRawRow(vertical: 9, horizontal: 12) {
                    Text("No plugins are running for this conversation.").sk(13, SK.secondary)
                }
            }
        } else {
            SKGroup("Running for this conversation") {
                ForEach(model.resolvedPluginPipeline) { entry in
                    row(entry.pluginName, source: entry.source, on: true)
                }
                ForEach(subtracted, id: \.self) { name in
                    row(name, source: .profile, on: false)
                }
            } footer: {
                Text("Turning one off here leaves the profile alone.").sk(11.5, SK.tertiary)
            }
        }
        if !model.conversationPluginOverrides.isEmpty {
            Button {
                Task { await model.clearAllConversationOverrides() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
                    Text("Clear Conversation Changes")
                }
                .foregroundStyle(SK.red)
            }
            .buttonStyle(.plain)
            .sk(13, SK.red)
        }
    }

    private func row(_ name: String, source: PsmithResolvedPipelineSource, on: Bool) -> some View {
        SKRawRow(vertical: 9, horizontal: 12) {
            HStack(spacing: 6) {
                Text(displayName(name)).sk(13).lineLimit(1)
                switch source {
                case .conversation: SKChip(text: "This conversation", color: theme.accentInk, fill: theme.accent.opacity(0.16))
                case .profile: SKChip(text: "Profile")
                default: SKChip(text: "Unknown")
                }
                Spacer(minLength: 8)
                if source == .profile || source == .conversation {
                    Toggle("", isOn: Binding(get: { on }, set: { _ in
                        Task {
                            if source == .conversation {
                                await model.removeConversationOverride(pluginName: name)
                            } else {
                                await model.toggleConversationDisableInherited(pluginName: name)
                            }
                        }
                    }))
                    .skSwitch()
                    .accessibilityLabel(displayName(name))
                }
            }
        }
    }

    private func displayName(_ name: String) -> String {
        if let t = model.registeredPluginTypes.first(where: { $0.name == name }) {
            return t.displayName.isEmpty ? name : t.displayName
        }
        return name
    }
}
