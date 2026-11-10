import SwiftUI
import PsmithKit
import PsmithUI

/// One provider (board SettingsModels): its models with on/off switches,
/// the defaults every one of them starts from, and removing it.
struct ModelsProviderScreen: View {
    let initialProvider: PsmithUserModelProvider
    var autoload = true
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// What the provider lists upstream; fills in the models that are off.
    @State var discovered: [PsmithDiscoveredModel]
    /// Switched off on this visit: they keep their row so a mistake is one
    /// tap to undo.
    @State var turnedOff: [PsmithUserModel]
    @State var showAllOff = false
    @State var confirmingRemove = false
    @State private var busy: Set<String> = []
    @State private var banner: (String, Color)?

    init(provider: PsmithUserModelProvider, discovered: [PsmithDiscoveredModel] = [],
         turnedOff: [PsmithUserModel] = [], confirmingRemove: Bool = false, autoload: Bool = true) {
        initialProvider = provider
        _discovered = State(initialValue: discovered)
        _turnedOff = State(initialValue: turnedOff)
        _confirmingRemove = State(initialValue: confirmingRemove)
        self.autoload = autoload
    }

    /// The live row, so an edit or a defaults save made below shows here.
    private var provider: PsmithUserModelProvider {
        app.providers.providers.first { $0.id == initialProvider.id } ?? initialProvider
    }

    private var enabled: [PsmithUserModel] {
        app.providers.selectedID == provider.id ? app.providers.enabledModels : []
    }

    /// Hand-added models that are off. The server keeps them, so they
    /// list here on every visit, not only the one that turned them off.
    private var keptOff: [PsmithUserModel] {
        guard app.providers.selectedID == provider.id else { return [] }
        let session = Set(turnedOff.map(\.modelID))
        return app.providers.disabledModels.filter { !session.contains($0.modelID) }
    }

    private var offRows: [PsmithDiscoveredModel] {
        let on = Set(enabled.map(\.modelID))
        let off = Set(turnedOff.map(\.modelID)).union(keptOff.map(\.modelID))
        return discovered.filter { !on.contains($0.modelID) && !off.contains($0.modelID) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let banner {
                    IKBanner(systemImage: "info.circle", text: banner.0, color: banner.1) { self.banner = nil }
                        .padding(.bottom, 10)
                }
                header

                headLink("Models", "Find New") { ModelsDiscoverScreen(provider: provider) }
                IKGroup {
                    if enabled.isEmpty && turnedOff.isEmpty && keptOff.isEmpty && offRows.isEmpty {
                        IKRow("No models on", detail: "Find New lists what this provider offers.")
                    }
                    ForEach(enabled) { m in modelRow(m, on: true) }
                    ForEach(turnedOff) { m in modelRow(m, on: false) }
                    ForEach(keptOff) { m in modelRow(m, on: false) }
                    if showAllOff {
                        ForEach(offRows) { d in discoveredRow(d) }
                    } else if !offRows.isEmpty {
                        Button { withAnimation(.snappy) { showAllOff = true } } label: {
                            HStack {
                                Text("\(offRows.count) more, off").font(.system(size: 16)).foregroundStyle(IK.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                IKChevron(down: true)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                IKPageNote("Tap a model for its own call settings and prices. Swipe to delete one you added by hand.", settings: true)

                headLink("Defaults for every \(provider.label) model", "All Defaults") { ProviderDefaultsScreen(provider: provider) }
                IKGroup {
                    let rows = defaultsSummary
                    if rows.isEmpty {
                        defaultsLink(IKRow("None set", value: "Model defaults apply", chevron: true))
                    }
                    ForEach(rows, id: \.0) { r in defaultsLink(IKRow(r.0, value: r.1, chevron: true)) }
                }

                Group {
                    if confirmingRemove {
                        IKConfirmCard(question: "Remove \(provider.label)?",
                                      detail: removeDetail, confirmLabel: "Remove",
                                      onCancel: { withAnimation(.snappy) { confirmingRemove = false } },
                                      onConfirm: remove)
                    } else {
                        IKGroup {
                            Button { withAnimation(.snappy) { confirmingRemove = true } } label: {
                                IKRow("Remove \(provider.label)", titleColor: IK.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage(provider.label)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ModelsProviderKeyScreen(mode: .edit(provider)) } label: {
                    Text("Edit").font(.system(size: 16)).foregroundStyle(IK.text).padding(.horizontal, 4)
                }
            }
        }
        .task {
            guard autoload else { return }
            await app.providers.selectProvider(provider.id)
            if let list = try? await app.providers.discoverModels(providerID: provider.id) { discovered = list }
        }
    }

    private func headLink<D: View>(_ title: String, _ link: String, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            NavigationLink(destination: dest) {
                Text(link).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentInk)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 18, leading: 4, bottom: 6, trailing: 4))
    }

    // MARK: Header

    private var header: some View {
        let status = ModelsProviderStatus(provider, app.providers.providerTestStatus[provider.id])
        let total = discovered.isEmpty && keptOff.isEmpty ? nil
            : Set(discovered.map(\.modelID)).union(enabled.map(\.modelID)).union(keptOff.map(\.modelID)).count
        return HStack(spacing: 12) {
            IKLetterTile(letter: String(provider.label.prefix(1)).uppercased(), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.label).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text("\(status.text) · \(enabled.count)\(total.map { " of \($0)" } ?? "") models on")
                }
                .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
    }

    // MARK: Rows

    private func detail(window: Int32?, pricing: PsmithModelPricing?, thinks: Bool) -> String {
        [IKFormat.window(window), IKFormat.prices(pricing), thinks ? "thinks" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }

    private func modelRow(_ m: PsmithUserModel, on: Bool) -> some View {
        HStack(spacing: 12) {
            NavigationLink { ModelDetailScreen(provider: provider, mode: .edit(m)) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(m.displayName).font(.system(size: 16)).foregroundStyle(on ? IK.text : IK.secondary)
                        if m.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(IK.orange) }
                    }
                    Text(detail(window: m.contextWindow, pricing: m.pricing, thinks: m.capabilities?.thinking == true))
                        .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(on)
            Toggle(m.displayName, isOn: Binding(get: { on }, set: { setOn(m.modelID, $0, model: m) }))
                .labelsHidden().tint(theme.accent).disabled(busy.contains(m.modelID))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .frame(minHeight: 44)
        .contextMenu {
            Button(m.favorite ? "Unfavorite" : "Favorite", systemImage: m.favorite ? "star.slash" : "star") {
                Task { await app.providers.toggleModelFavorite(modelID: m.modelID) }
            }
            Button("Test", systemImage: "checkmark.seal") { Task { await test(m) } }
            if m.metadataSource == "manual" {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(m) }
            }
        }
    }

    private func discoveredRow(_ d: PsmithDiscoveredModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(d.displayName).font(.system(size: 16)).foregroundStyle(IK.secondary)
                Text(detail(window: d.contextWindow, pricing: d.pricing, thinks: d.capabilities?.thinking == true))
                    .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(d.displayName, isOn: Binding(get: { false }, set: { if $0 { setOn(d.modelID, true, model: nil) } }))
                .labelsHidden().tint(theme.accent).disabled(busy.contains(d.modelID))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .frame(minHeight: 44)
    }

    private func defaultsLink(_ row: IKRow<EmptyView>) -> some View {
        NavigationLink { ProviderDefaultsScreen(provider: provider) } label: { row }.buttonStyle(.plain)
    }

    /// The provider defaults worth a glance, in the order the form lists them.
    private var defaultsSummary: [(String, String)] {
        guard let s = provider.defaultSettings else { return [] }
        var out: [(String, String)] = []
        if let t = s.temperature { out.append(("Temperature", String(format: "%.2f", t))) }
        if let m = s.maxOutputTokens { out.append(("Max output tokens", m.formatted())) }
        if let e = s.thinking?.effort { out.append(("Thinking effort", e.label)) }
        if let c = s.anthropic?.cacheEnabled { out.append(("Prompt caching", c ? "On" : "Off")) }
        if let t = s.anthropic?.cacheTTL { out.append(("Cache TTL", t == .oneHour ? "1 hour" : "5 min")) }
        if let e = s.explicitCache { out.append(("Explicit caching", e ? "On" : "Off")) }
        let shown = out.count
        let total = IKCallSettingsDiff.setCount(s)
        if total > shown { out.append(("Other fields", "\(total - shown) set")) }
        return out
    }

    private var removeDetail: String {
        let n = enabled.count
        return "Its \(n) model\(n == 1 ? "" : "s") go. Conversations keep their history; profiles using one of them need a new default."
    }

    // MARK: Actions

    private func setOn(_ id: String, _ on: Bool, model: PsmithUserModel?) {
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            if on {
                do {
                    _ = try await app.providers.enableModels(providerID: provider.id, modelIDs: [id])
                    turnedOff.removeAll { $0.modelID == id }
                } catch {
                    banner = (PsmithError.display(error), IK.red)
                }
            } else {
                await app.providers.disableModel(id)
                // A hand-added model lands in disabledModels (keptOff) instead.
                if let model, model.metadataSource != "manual",
                   !app.providers.enabledModels.contains(where: { $0.modelID == id }) {
                    turnedOff.append(model)
                }
            }
        }
    }

    private func delete(_ m: PsmithUserModel) {
        busy.insert(m.modelID)
        Task {
            defer { busy.remove(m.modelID) }
            await app.providers.deleteModel(m.modelID)
            turnedOff.removeAll { $0.modelID == m.modelID }
        }
    }

    private func test(_ m: PsmithUserModel) async {
        await app.providers.testModel(providerID: provider.id, modelID: m.modelID)
        switch app.providers.modelTestStatus[ModelTestKey(providerID: provider.id, modelID: m.modelID)] {
        case .success(let r) where r.ok:
            banner = ("\(m.displayName) answered in \(r.latencyMs) ms (\(r.inputTokens) in, \(r.outputTokens) out).", IK.green)
        case .success(let r): banner = ("\(m.displayName) failed: \(r.errorMessage)", IK.red)
        case .failure(let msg): banner = ("\(m.displayName) failed: \(msg)", IK.red)
        default: break
        }
    }

    private func remove() {
        app.providers.selectedID = provider.id
        Task { await app.providers.deleteSelected() }
        dismiss()
    }
}

// MARK: - Find new models

/// What the provider lists upstream (board SettingsDiscover). Models already
/// on show checked and fixed; tick others and enable them together.
struct ModelsDiscoverScreen: View {
    let provider: PsmithUserModelProvider
    var autoload = true
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State var discovered: [PsmithDiscoveredModel]
    @State var selected: Set<String>
    @State private var query = ""
    @State private var loading = false
    @State private var enabling = false
    @State private var error: String?

    init(provider: PsmithUserModelProvider, discovered: [PsmithDiscoveredModel] = [], selected: Set<String> = [],
         autoload: Bool = true) {
        self.provider = provider
        _discovered = State(initialValue: discovered)
        _selected = State(initialValue: selected)
        self.autoload = autoload
    }

    private var enabledIDs: Set<String> {
        Set(app.providers.selectedID == provider.id ? app.providers.enabledModels.map(\.modelID) : [])
    }

    private func isOn(_ d: PsmithDiscoveredModel) -> Bool { d.alreadyEnabled || enabledIDs.contains(d.modelID) }

    private var shown: [PsmithDiscoveredModel] {
        guard !query.isEmpty else { return discovered }
        let q = query.lowercased()
        return discovered.filter { $0.displayName.lowercased().contains(q) || $0.modelID.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKSearchField(prompt: "Search models", text: $query, height: 38, radius: 11).padding(.top, 2)
                IKPageHead(text: "\(provider.label) lists \(discovered.count)",
                           trailing: "\(discovered.filter(isOn).count) on")
                IKGroup {
                    if discovered.isEmpty {
                        IKRow(loading ? "Asking \(provider.label)…" : (error ?? "Nothing listed"),
                              titleColor: error == nil ? IK.secondary : IK.red)
                    }
                    ForEach(shown) { d in row(d) }
                }
                IKPageNote("Models already on stay on. Turn one off from the provider page.", settings: true)

                IKGroup {
                    NavigationLink { ModelDetailScreen(provider: provider, mode: .add) } label: { IKAddRow(title: "Add Custom Model") }
                        .buttonStyle(.plain)
                }
                .padding(.top, 18)
                IKPageNote("Describe a model by hand, for private fine-tunes or models the provider doesn’t list.", settings: true)
                if let error, !discovered.isEmpty {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error, color: IK.red).padding(.top, 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("Find New Models")
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty {
                IKActionBar(summary: "\(selected.count) new of \(discovered.count) selected", primary: "Enable Selected",
                            canSave: !enabling, onPrimary: { Task { await enable() } })
            }
        }
        .task { if autoload { await load() } }
    }

    private func row(_ d: PsmithDiscoveredModel) -> some View {
        let on = isOn(d)
        let picked = selected.contains(d.modelID)
        return Button {
            guard !on else { return }
            if picked { selected.remove(d.modelID) } else { selected.insert(d.modelID) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if on || picked {
                        Circle().fill(on ? theme.accent.opacity(0.45) : theme.accent)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(IK.ring(0.25), lineWidth: 1.5)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(d.displayName).font(.system(size: 16)).foregroundStyle(IK.text)
                        if on { IKTag(text: "On", color: IK.green, fill: IK.green.opacity(0.12)) }
                    }
                    Text(d.modelID).font(.system(size: 12, design: .monospaced)).foregroundStyle(IK.secondary)
                        .padding(.top, 1)
                    IKFlow(spacing: 4) {
                        ForEach(tags(d), id: \.0) { t in IKTag(text: t.0, color: t.1 ?? IK.secondary) }
                    }
                    .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on || picked ? .isSelected : [])
    }

    private func tags(_ d: PsmithDiscoveredModel) -> [(String, Color?)] {
        var out: [(String, Color?)] = []
        if let w = IKFormat.window(d.contextWindow) { out.append((w.uppercased(), nil)) }
        if let b = costBucket(d.pricing) { out.append((b, IK.orange)) }
        let c = d.capabilities
        if c?.thinking == true { out.append(("Thinks", nil)) }
        if c?.vision == true { out.append(("Sees", nil)) }
        if c?.toolUse == true { out.append(("Tools", nil)) }
        if c?.promptCaching == true { out.append(("Caches", nil)) }
        return out
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            discovered = try await app.providers.discoverModels(providerID: provider.id)
        } catch {
            if !PsmithError.isCancellation(error) { self.error = PsmithError.display(error) }
        }
    }

    private func enable() async {
        enabling = true
        defer { enabling = false }
        do {
            _ = try await app.providers.enableModels(providerID: provider.id, modelIDs: Array(selected).sorted())
            selected = []
            await app.providers.selectProvider(provider.id)
            dismiss()
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

/// Wraps its children onto as many lines as they need.
struct IKFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
