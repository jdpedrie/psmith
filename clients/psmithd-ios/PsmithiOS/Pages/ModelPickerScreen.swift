import SwiftUI
import PsmithKit
import PsmithUI

/// The conversation's model picker (board ModelPicker): search, the
/// profile's own model, the models this conversation has used, then every
/// enabled model by provider. Picking one applies from the next message
/// and pops back.
struct ModelPickerScreen: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKSearchField(prompt: "Search \(model.selectableModels.count) models", text: $query)
                if let notice = model.harnessNotice {
                    IKBanner(systemImage: "lock", text: notice, color: IK.secondary).padding(.top, 14)
                }
                if query.isEmpty {
                    IKPageGroup {
                        Button { Task { await useProfileModel() } } label: {
                            row(title: "Use the profile’s model", detail: profileDetail, selected: !model.ikPinsModel && false)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)

                    if !recent.isEmpty {
                        IKPageHead(text: "Recent")
                        IKPageGroup {
                            ForEach(recent, id: \.id) { m in modelButton(m, withProvider: true) }
                        }
                    }
                }
                ForEach(groups, id: \.providerID) { g in
                    IKPageHead(text: g.label, trailing: "\(g.total) enabled")
                    IKPageGroup {
                        ForEach(g.models, id: \.id) { m in modelButton(m, withProvider: false) }
                    }
                }
                if groups.isEmpty && !query.isEmpty {
                    IKPageNote("No models match “\(query)”.", top: 14)
                }
                Text("Applies from the next message in this conversation. \(profileName.map { "The \($0) profile" } ?? "The profile") keeps its own default.")
                    .font(.system(size: 13)).ikLineHeight(13, 18).foregroundStyle(IK.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
        .ikConversationPage("Model")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ConversationPage.callSettings) {
                    Text("Call Settings").font(.system(size: 15)).foregroundStyle(IK.text).padding(.horizontal, 4)
                }
            }
        }
    }

    // MARK: Data

    private var profile: PsmithProfile? {
        model.settingsResolvedProfile ?? app.profiles.profiles.first { $0.id == model.conversation.profileID }
    }

    private var profileName: String? { profile?.name }

    private var profileModel: PsmithUserModel? {
        guard let d = profile?.defaultSettings, let p = d.defaultProviderID, let m = d.defaultModelID else { return nil }
        return model.selectableModels.first { $0.providerID == p && $0.modelID == m }
    }

    private var profileDetail: String {
        let who = profileName ?? "The profile"
        if let m = profileModel { return "\(who) uses \(m.displayName)" }
        return "\(who) has no default model"
    }

    private func matches(_ m: PsmithUserModel) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return m.displayName.lowercased().contains(q) || m.modelID.lowercased().contains(q)
            || (model.providerLabels[m.providerID]?.lowercased().contains(q) ?? false)
    }

    /// The current pick first, then the models replies in this conversation
    /// came from, newest first, three at most.
    private var recent: [PsmithUserModel] {
        var keys: [String] = []
        if let p = model.selectedProviderID, let m = model.selectedModelID { keys.append("\(p)/\(m)") }
        for msg in model.messages.reversed() where msg.role == .assistant {
            if let p = msg.providerID, let m = msg.modelID, !keys.contains("\(p)/\(m)") { keys.append("\(p)/\(m)") }
        }
        return keys.compactMap { k in model.selectableModels.first { "\($0.providerID)/\($0.modelID)" == k } }
            .prefix(3).map { $0 }
    }

    private struct Group { let providerID: String; let label: String; let total: Int; let models: [PsmithUserModel] }

    private var groups: [Group] {
        let shown = query.isEmpty ? Set(recent.map { "\($0.providerID)/\($0.modelID)" }) : []
        let byProvider = Dictionary(grouping: model.selectableModels, by: \.providerID)
        return byProvider.keys.sorted { (model.providerLabels[$0] ?? $0).localizedCaseInsensitiveCompare(model.providerLabels[$1] ?? $1) == .orderedAscending }
            .compactMap { pid in
                let all = byProvider[pid] ?? []
                let list = all.filter { !shown.contains("\($0.providerID)/\($0.modelID)") && matches($0) }
                guard !list.isEmpty else { return nil }
                return Group(providerID: pid, label: model.providerLabels[pid] ?? pid, total: all.count, models: list)
            }
    }

    // MARK: Rows

    private func missing(_ m: PsmithUserModel) -> [String] {
        guard let r = model.activeProfileRequiredCapabilities else { return [] }
        let c = m.capabilities
        var out: [String] = []
        if r.toolUse && !(c?.toolUse ?? false) { out.append("tools") }
        if r.vision && !(c?.vision ?? false) { out.append("vision") }
        if r.thinking && !(c?.thinking ?? false) { out.append("thinking") }
        if r.promptCaching && !(c?.promptCaching ?? false) { out.append("caching") }
        if r.generatesImages && !(c?.generatesImages ?? false) { out.append("image output") }
        return out
    }

    private func modelButton(_ m: PsmithUserModel, withProvider: Bool) -> some View {
        let selected = m.providerID == model.selectedProviderID && m.modelID == model.selectedModelID
        let needs = missing(m)
        return Button {
            Task {
                await model.selectModel(providerID: m.providerID, modelID: m.modelID)
                dismiss()
            }
        } label: {
            row(title: m.displayName, detail: needs.isEmpty ? nil : "Needs \(needs.joined(separator: ", "))",
                meta: meta(m, withProvider: withProvider), tags: withProvider ? [] : tags(m), selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(!needs.isEmpty)
        .opacity(needs.isEmpty ? 1 : 0.5)
        .accessibilityLabel(m.displayName)
        .accessibilityValue(meta(m, withProvider: withProvider))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func meta(_ m: PsmithUserModel, withProvider: Bool) -> String {
        var parts: [String] = []
        if withProvider, let l = model.providerLabels[m.providerID] { parts.append(l) }
        if let w = IKFormat.window(m.contextWindow) { parts.append(w) }
        if let p = IKFormat.prices(m.pricing) { parts.append(p) }
        if !withProvider && tags(m).isEmpty && Set(m.modalities).subtracting(["text"]).isEmpty { parts.append("text only") }
        return parts.joined(separator: " · ")
    }

    private func tags(_ m: PsmithUserModel) -> [String] {
        var out: [String] = []
        if m.modalities.contains("image") { out.append("Images") }
        if m.modalities.contains("audio") { out.append("Audio") }
        if m.capabilities?.thinking == true { out.append("Thinks") }
        return out
    }

    private func row(title: String, detail: String? = nil, meta: String? = nil, tags: [String] = [], selected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 16, weight: selected ? .semibold : .regular)).foregroundStyle(IK.text)
                    .ikLineHeight(16, 21)
                HStack(spacing: 6) {
                    if let meta { Text(meta) }
                    if let detail, meta == nil { Text(detail) }
                    ForEach(tags, id: \.self) { IKTag(text: $0) }
                }
                .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit().lineLimit(1)
                .frame(height: 17)
                if let detail, meta != nil {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(IK.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accentInk).frame(width: 18).opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(selected ? theme.selection.opacity(0.6) : .clear)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Drops the conversation's own model so it follows the profile again.
    private func useProfileModel() async {
        guard model.canChangeProvider else { return }
        do {
            let (live, _) = try await app.client.conversations.get(id: model.conversation.id)
            var s = live.settings ?? PsmithConversationSettings()
            s.defaultProviderID = nil
            s.defaultModelID = nil
            _ = try await app.client.conversations.updateSettings(id: live.id, settings: s)
            if let p = profileModel {
                model.selectedProviderID = p.providerID
                model.selectedModelID = p.modelID
            }
            dismiss()
        } catch {
            model.loadError = PsmithError.display(error)
        }
    }
}
