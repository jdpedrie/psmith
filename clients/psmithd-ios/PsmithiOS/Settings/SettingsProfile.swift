import SwiftUI
import PsmithKit
import PsmithUI

/// One profile (board SettingsProfile), and the page for a new one. Every
/// edit, here and on the pages it pushes, collects in one draft behind the
/// glass save bar.
struct SettingsProfile: View {
    /// nil creates a profile.
    let profileID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileDraft?

    var body: some View {
        Group {
            if let draft {
                SettingsProfileScreen(draft: draft, onSave: { Task { await save(draft) } })
            } else if profileID != nil && app.profiles.profiles.first(where: { $0.id == profileID }) == nil {
                IKSettingsPage(title: "Profile") {
                    IKSFooter("This profile is gone. It may have been deleted on another device.", top: 0)
                }
            } else {
                Color.clear.background(IK.settingsGround.ignoresSafeArea())
            }
        }
        .onAppear {
            guard draft == nil else { return }
            let profile = profileID.flatMap { id in app.profiles.profiles.first { $0.id == id } }
            if profileID != nil && profile == nil { return }
            draft = ProfileDraft.draft(for: profile)
        }
        .task {
            // Model names and plugin rows need these; both are cheap when warm.
            async let models: Void = app.profiles.loadAvailableModels()
            async let plugins: Void = draft?.loadPlugins(app.profiles) ?? ()
            _ = await (models, plugins)
        }
    }

    private func save(_ draft: ProfileDraft) async {
        let wasNew = draft.profileID == nil
        if await draft.save(app.profiles) {
            ProfileDraft.discard(draft)
            if wasNew { dismiss() }
        }
    }
}

struct SettingsProfileScreen: View {
    @Bindable var draft: ProfileDraft
    let onSave: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    private var profiles: ProfilesViewModel { app.profiles }
    private var stored: PsmithProfile? { profiles.profiles.first { $0.id == draft.profileID } }
    private var parent: PsmithProfile? { profiles.profiles.first { $0.id == draft.fields.parentProfileID } }

    var body: some View {
        IKSettingsPage(title: draft.fields.name.isEmpty ? (draft.profileID == nil ? "New profile" : "Profile") : draft.fields.name) {
            IKGroup {
                IKSStackedField(label: "Name", text: $draft.fields.name, placeholder: "Profile name")
                    .padding(14)
            }

            IKSHead("Models")
            IKGroup {
                IKSLinkRow(title: "Replies", value: ProfileLookup.modelName(profiles, provider: draft.fields.defaultProviderID,
                                                                            model: draft.fields.defaultModelID) ?? "Inherit") {
                    ProfileModelPage(title: "Replies", provider: $draft.fields.defaultProviderID, model: $draft.fields.defaultModelID)
                }
                IKSLinkRow(title: "Compression", value: ProfileLookup.modelName(profiles, provider: draft.fields.compressionProviderID,
                                                                                model: draft.fields.compressionModelID) ?? "Inherit") {
                    ProfileCompressionPage(draft: draft)
                }
                IKSLinkRow(title: "Titles", value: titleValue) { ProfileTitlesPage(draft: draft) }
            }

            IKSHead("System prompt")
            IKGroup {
                VStack(alignment: .leading, spacing: 7.5) {
                    TextField("Optional. Sent at the top of every conversation.", text: $draft.fields.systemMessage, axis: .vertical)
                        .font(.system(size: 15))
                        .lineSpacing(21 - 18)
                        .lineLimit(4...14)
                        .foregroundStyle(IK.text)
                        .accessibilityLabel("System prompt")
                    HStack {
                        Text(parent.map { "Added after \($0.name)’s prompt" } ?? "Sent at the top of every conversation")
                        Spacer(minLength: 8)
                        Text("\(draft.fields.systemMessage.count) characters").monospacedDigit()
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(IK.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 13.5)
                .padding(.bottom, 12)
            }

            IKSHead("Behavior")
            IKGroup {
                NavigationLink { ProfileParentPage(draft: draft) } label: {
                    IKSRow {
                        Text("Based on").frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            if let parent { IKDot(color: ProfileLookup.color(parent, theme: theme), size: 8) }
                            Text(parent?.name ?? "Nothing")
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(IK.secondary)
                        IKChevron()
                    }
                }
                .buttonStyle(.plain)
                if let id = draft.profileID {
                    IKSLinkRow(title: "Call settings", value: callSettingsValue) { ProfileCallSettingsScreen(profileID: id) }
                } else {
                    IKSValueRow(title: "Call settings", value: "After it’s created", color: IK.tertiary)
                }
                IKSLinkRow(title: "Plugins", value: pluginsValue) { SettingsProfilePlugins(draft: draft) }
            }

            IKSHead("Messages")
            IKGroup {
                IKSLinkRow(title: "First message", value: preview(draft.fields.defaultUserMessage)) {
                    ProfileTextPage(title: "First message", note: "Fills the message field when a conversation starts.",
                                    text: $draft.fields.defaultUserMessage)
                }
                IKSLinkRow(title: "Welcome message", value: preview(draft.fields.welcomeMessage)) {
                    ProfileTextPage(title: "Welcome message", note: "Shown as the first reply in a new conversation.",
                                    text: $draft.fields.welcomeMessage)
                }
            }

            IKSHead("Options")
            IKGroup {
                IKSStackedField(label: "Description", text: $draft.fields.description, placeholder: "Optional",
                                caption: "Shown under the name in profile pickers.")
                    .padding(14)
                IKSSwitchRow(title: "Favorite", note: "Sorts first in every profile list.", isOn: $draft.fields.favorite)
                IKSSwitchRow(title: "Parent only", note: "A template other profiles build on. Never offered for a new chat.",
                             isOn: $draft.fields.parentOnly)
            }

            if let stored {
                IKGroup {
                    IKSLinkRow(title: "Share or delete") { SettingsProfileShare(profileID: stored.id) }
                }
                .padding(.top, 18)
            }
            if let error = draft.error { IKSError(text: error) }
        } bar: {
            if draft.isDirty {
                IKSaveBar(summary: draft.isNew ? "New profile" : SettingsFormat.unsaved(draft.changeCount),
                          saveLabel: draft.isNew ? "Create" : "Save",
                          canSave: draft.canSave,
                          onRevert: { draft.revert() }, onSave: onSave)
            }
        }
    }

    private var titleValue: String {
        if draft.fields.titleProviderKind == PsmithTitleProviderKind.appleFoundation { return "On-device" }
        return ProfileLookup.modelName(profiles, provider: draft.fields.titleProviderID, model: draft.fields.titleModelID) ?? "Inherit"
    }

    private var callSettingsValue: String {
        let n = ProfileLookup.overrideCount(stored?.defaultSettings?.callSettings)
        return n == 0 ? "Defaults" : "\(n) override\(n == 1 ? "" : "s")"
    }

    private var pluginsValue: String? {
        guard draft.pluginsLoaded else { return nil }
        let own = draft.plugins.filter { !$0.disabled }.count
        let inherited = ProfileInheritance.inherited(parentID: draft.fields.parentProfileID, profiles: profiles)
            .filter { i in !draft.plugins.contains { $0.pluginName == i.pluginName } }.count
        if own == 0 && inherited == 0 { return "None" }
        return inherited == 0 ? "\(own) on" : "\(own) on · \(inherited) inherited"
    }

    private func preview(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? "None" : t
    }
}

// MARK: - Pushed pages

/// Picks a model for one of the profile's slots; Inherit clears it.
struct ProfileModelPage: View {
    let title: String
    @Binding var provider: String?
    @Binding var model: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IKSettingsPage(title: title) {
            ModelPickerList(
                models: app.profiles.availableModels,
                providerLabels: app.profiles.providerLabels,
                providerTypes: app.profiles.providerTypes,
                providerPresetIDs: app.profiles.providerPresetIDs,
                selectedProviderID: provider,
                selectedModelID: model,
                onUnset: { provider = nil; model = nil; dismiss() },
                unsetDescription: "Inherit from the profile it’s based on, if any.",
                onSelect: { p, m in provider = p; model = m; dismiss() }
            )
        }
        .task { await app.profiles.loadAvailableModels() }
    }
}

/// How long conversations are compressed: mode, model and guide.
struct ProfileCompressionPage: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var app

    var body: some View {
        IKSettingsPage(title: "Compression") {
            IKSHead("Mode", first: true)
            IKSSegmented(options: [(PsmithCompressionMode?.none, "Inherit"), (.some(.replace), "Replace"), (.some(.append), "Append")],
                         selection: $draft.fields.compressionMode)
            IKSFooter("Replace starts the new context from the summary alone. Append keeps the summary and the latest turns.")
            IKSHead("Model")
            IKGroup {
                IKSLinkRow(title: "Model", value: ProfileLookup.modelName(app.profiles, provider: draft.fields.compressionProviderID,
                                                                          model: draft.fields.compressionModelID) ?? "Inherit") {
                    ProfileModelPage(title: "Compression model", provider: $draft.fields.compressionProviderID,
                                     model: $draft.fields.compressionModelID)
                }
            }
            IKSHead("Guide")
            ProfileTextBox(text: $draft.fields.compressionGuide, placeholder: "Optional extra instruction for the summary")
        } bar: {
            ProfileDraftBar(draft: draft)
        }
    }
}

/// How conversations get their titles.
struct ProfileTitlesPage: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var app

    var body: some View {
        IKSettingsPage(title: "Titles") {
            IKSHead("Generator", first: true)
            IKSSegmented(options: [(String?.none, "Cloud or inherit"), (.some(PsmithTitleProviderKind.appleFoundation), "On-device")],
                         selection: $draft.fields.titleProviderKind)
            if !AppleFoundation.isAvailable, let msg = AppleFoundation.unavailabilityMessage {
                IKSFooter("On-device titles aren’t available here: \(msg)")
            }
            if draft.fields.titleProviderKind != PsmithTitleProviderKind.appleFoundation {
                IKSHead("Cloud model")
                IKGroup {
                    IKSLinkRow(title: "Model", value: ProfileLookup.modelName(app.profiles, provider: draft.fields.titleProviderID,
                                                                              model: draft.fields.titleModelID) ?? "Inherit") {
                        ProfileModelPage(title: "Title model", provider: $draft.fields.titleProviderID, model: $draft.fields.titleModelID)
                    }
                }
            }
            IKSHead("Guide")
            ProfileTextBox(text: $draft.fields.titleGuide, placeholder: "Optional, such as “prefer technical phrasing”")
        } bar: {
            ProfileDraftBar(draft: draft)
        }
    }
}

/// Which profile this one builds on. Itself and its descendants are left
/// out: either would close the chain into a loop.
struct ProfileParentPage: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var eligible: [PsmithProfile] {
        let all = app.profiles.profiles
        var excluded: Set<String> = []
        if let me = draft.profileID {
            excluded.insert(me)
            var frontier = [me]
            while let id = frontier.popLast() {
                for child in all where child.parentProfileID == id && !excluded.contains(child.id) {
                    excluded.insert(child.id)
                    frontier.append(child.id)
                }
            }
        }
        return all.filter { !excluded.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        IKSettingsPage(title: "Based on") {
            IKGroup {
                choice(nil, title: "Nothing", note: "Standalone")
                ForEach(eligible) { p in choice(p.id, title: p.name, note: p.parentOnly ? "Template" : nil, dot: ProfileLookup.color(p, theme: theme)) }
            }
            .padding(.top, 4)
            IKSFooter("A profile inherits its parent’s prompt, models, call settings and plugins, and adds its own on top.")
        }
    }

    private func choice(_ id: String?, title: String, note: String?, dot: Color? = nil) -> some View {
        Button {
            draft.fields.parentProfileID = id
            dismiss()
        } label: {
            IKSRow {
                if let dot { IKDot(color: dot, size: 10) }
                IKSTitleNote(title: title, note: note, noteSize: 12.5)
                if draft.fields.parentProfileID == id {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentInk)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.fields.parentProfileID == id ? .isSelected : [])
    }
}

/// A long text field on its own page.
struct ProfileTextPage: View {
    let title: String
    let note: String
    @Binding var text: String

    var body: some View {
        IKSettingsPage(title: title) {
            ProfileTextBox(text: $text, placeholder: "Optional", minLines: 10).padding(.top, 4)
            IKSFooter(note)
        }
    }
}

struct ProfileTextBox: View {
    @Binding var text: String
    let placeholder: String
    var minLines = 4

    var body: some View {
        IKGroup {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineSpacing(3)
                .lineLimit(minLines...40)
                .foregroundStyle(IK.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }
}

/// The profile's save bar, on any page that edits its draft.
struct ProfileDraftBar: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var app

    var body: some View {
        if draft.isDirty && !draft.isNew {
            IKSaveBar(summary: SettingsFormat.unsaved(draft.changeCount), canSave: draft.canSave,
                      onRevert: { draft.revert() },
                      onSave: { Task { if await draft.save(app.profiles) { ProfileDraft.discard(draft) } } })
        }
    }
}
