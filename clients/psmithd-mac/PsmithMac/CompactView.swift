import SwiftUI
import PsmithKit

/// Full-pane "Compact this conversation" view shown when the user opens
/// the compact button in the conversation toolbar. Replaces the message
/// scroll inline (no popovers, no sheets) per the project's "no popup
/// windows" convention. Mirrors `NewConversationView` and
/// `ContextListPane`'s page structure: section labels + glass rows;
/// back navigation lives in the toolbar slot owned by `ConversationBody`
/// (the compact button swaps to a chevron while this page is active).
///
/// Two affordances:
///   1. Editable prompt textarea, pre-populated with the resolved
///      profile's `compressionGuide`. The edit is per-call only — it
///      doesn't persist back to the profile.
///   2. Inline-rows model picker (FAVORITES + per-provider groups), pre-
///      selected to the resolved profile's compression model. The user
///      can pick any other enabled (provider, model) pair. We do NOT use
///      a SwiftUI Menu here — single-item Menus render with zero-height
///      rows on macOS, and Menus over derived collections silently drop
///      items (see memory note `feedback_swiftui_menu_macos_bug.md`).
///      The inline rows pattern is reused from `NewConversationView`.
///
/// The footer carries a glass-prominent "Compact" button that fires the
/// RPC with the current draft + selection as overrides. On submit the
/// page closes and the conversation pane shows the streaming summary
/// just like the old confirmation-dialog flow.
struct CompactPane: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var modelSearch: String = ""
    @State private var pickingModel: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryHeader
                promptSection
                modelSection
                if let err = model.compactError {
                    Text("Last attempt: \(err)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Profiles list + available models drive the picker; profile
            // resolution drives the prompt + model preselection.
            await app.profiles.loadAvailableModels()
            await model.prepareCompactView()
        }
    }

    // MARK: Header summary

    /// Tiny advisory band above the prompt: how many turns will be summarized,
    /// the active context's token count vs window. Mirrors the old
    /// confirmation-dialog message but rendered inline so the page reads
    /// like a real screen rather than a sheet's prelude.
    @ViewBuilder
    private var summaryHeader: some View {
        let realCount = model.messages.filter { $0.role == .user || $0.role == .assistant }.count
        VStack(alignment: .leading, spacing: 4) {
            Text("\(realCount) message\(realCount == 1 ? "" : "s") will be summarized.")
                .font(.callout)
            if let count = model.tokenCount, let window = model.contextWindow, window > 0 {
                let pct = Int(Double(count) / Double(window) * 100)
                Text("Current: \(count.formatted()) / \(window.formatted()) tokens (\(pct)%).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("You'll review the summary before it replaces the active context.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Prompt")
            Text("System prompt sent to the compression model. Pre-filled from the profile; this edit is per-call only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextEditor(text: $model.compactPromptDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 140, maxHeight: 280)
        }
    }

    // MARK: Model picker

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Compression model")
            Text("Used to write the summary. Pre-selected from the profile; pick another enabled model to override for this run.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if pickingModel {
                modelRowList
            } else {
                selectedModelPill
            }
        }
    }

    /// Collapsed default state: shows the currently-selected compression model
    /// as a single glass row with a trailing "Change" button. Clicking Change
    /// expands the inline picker. Clicking the row itself also expands —
    /// matches the user's mental model of "tap to switch."
    @ViewBuilder
    private var selectedModelPill: some View {
        let providerLabels = app.profiles.providerLabels
        let selected = app.profiles.availableModels.first {
            $0.providerID == model.compactProviderID && $0.modelID == model.compactModelID
        }
        HStack(spacing: 10) {
            Image(systemName: selected == nil ? "exclamationmark.triangle" : "cpu")
                .font(.callout)
                .foregroundStyle(selected == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let s = selected {
                    Text(s.displayName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(providerLabels[s.providerID] ?? s.providerID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Model not found")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    if let mid = model.compactModelID, !mid.isEmpty {
                        Text("Profile points at \"\(mid)\", which isn't enabled. Pick another to continue.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No model resolved from the profile. Pick one to continue.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Change") {
                pickingModel = true
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 440, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .onTapGesture { pickingModel = true }
    }

    @ViewBuilder
    private var modelRowList: some View {
        let providerLabels = app.profiles.providerLabels
        let all = app.profiles.availableModels
        let needle = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? all : all.filter { m in
            let provider = providerLabels[m.providerID] ?? m.providerID
            return m.displayName.lowercased().contains(needle)
                || m.modelID.lowercased().contains(needle)
                || provider.lowercased().contains(needle)
        }
        // FAVORITES section + per-provider groups, mirroring
        // NewConversationView.modelRowList exactly.
        let favorites = filtered.filter { $0.favorite }.sorted { $0.displayName < $1.displayName }
        let nonFavorites = filtered.filter { !$0.favorite }
        let grouped: [(provider: String, models: [PsmithUserModel])] = Dictionary(grouping: nonFavorites) { $0.providerID }
            .map { (providerLabels[$0.key] ?? $0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.provider < $1.provider }
        let showProviderHeaders = grouped.count > 1 || !favorites.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            if all.count > 6 {
                TextField("Filter models", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 440)
            }

            ScrollView {
                VStack(spacing: 6) {
                    if !favorites.isEmpty {
                        groupHeader("Favorites")
                        ForEach(favorites, id: \.self) { m in
                            modelRow(
                                title: m.displayName,
                                subtitle: providerLabels[m.providerID] ?? m.providerID,
                                isSelected: model.compactProviderID == m.providerID && model.compactModelID == m.modelID,
                                model: m
                            ) {
                                model.compactProviderID = m.providerID
                                model.compactModelID    = m.modelID
                                pickingModel = false
                            }
                        }
                    }
                    ForEach(grouped, id: \.provider) { group in
                        if showProviderHeaders {
                            groupHeader(group.provider)
                        }
                        ForEach(group.models, id: \.self) { m in
                            modelRow(
                                title: m.displayName,
                                subtitle: showProviderHeaders ? nil : group.provider,
                                isSelected: model.compactProviderID == m.providerID && model.compactModelID == m.modelID,
                                model: m
                            ) {
                                model.compactProviderID = m.providerID
                                model.compactModelID    = m.modelID
                                pickingModel = false
                            }
                        }
                    }
                    if !needle.isEmpty && filtered.isEmpty {
                        Text("No models match \"\(modelSearch)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }
                    if all.isEmpty {
                        Text("No enabled models. Enable one in Settings → Providers first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 440)
            .frame(maxHeight: all.count > 6 ? 320 : .infinity)
        }
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.horizontal, 4)
    }

    private func modelRow(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        model: PsmithUserModel,
        action: @escaping () -> Void
    ) -> some View {
        // Same shape as NewConversationView.modelRow — two siblings inside
        // an HStack, one for the row's selection action and one for the
        // favorite-toggle star. No nesting so each Button sees its own taps.
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.callout)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await app.profiles.toggleModelFavorite(providerID: model.providerID, modelID: model.modelID) }
            } label: {
                Image(systemName: model.favorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.favorite ? Color.yellow : Color.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.favorite ? "Unfavorite" : "Mark as favorite")
            .padding(.trailing, 6)
        }
        .glassEffect(
            isSelected ? .regular.tint(theme.accent.opacity(0.18)).interactive()
                       : .regular.interactive(),
            in: .rect(cornerRadius: 10)
        )
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
