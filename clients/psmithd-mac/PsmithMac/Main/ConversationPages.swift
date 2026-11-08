import SwiftUI
import PsmithKit
import PsmithUI

/// Pages that open in the reading column in place of the transcript
/// (boards AppModelPage, AppCallSettingsPage, AppFullText, AppImage). They
/// replace the sheets this window used to open: a breadcrumb, ⌘[ and
/// Escape lead back to the conversation.
struct ConversationPageView: View {
    let page: ConversationPage
    @Bindable var model: ConversationViewModel
    @Environment(Navigator.self) private var navigator
    @Environment(ConversationsModel.self) private var convos

    private var title: String {
        let t = convos.conversations.first(where: { $0.id == model.conversation.id })?.title ?? model.conversation.title ?? ""
        return t.isEmpty ? "Untitled" : t
    }

    private func back() { navigator.page = nil }

    var body: some View {
        switch page {
        case .models:
            pageScroll {
                SKBreadcrumb(parts: [(title, back)], current: "Model")
                SKPageHead("Model for this conversation", subtitle: "Replies from here on use it. Earlier replies keep theirs.")
                SKModelPickerList(
                    models: model.selectableModels,
                    providerLabels: model.providerLabels,
                    providerLogos: model.providerTypes,
                    selectedProviderID: model.selectedProviderID,
                    selectedModelID: model.selectedModelID,
                    inheritLabel: nil
                ) { p, m in
                    guard let p, let m else { return }
                    Task { await model.selectModel(providerID: p, modelID: m) }
                    back()
                }
            }
        case .callSettings:
            CallSettingsPage(model: model, title: title, back: back)
        case .fullText(let heading, let markdown):
            pageScroll {
                SKBreadcrumb(parts: [(title, back)], current: heading)
                SKPageHead(title: heading, subtitle: ByteCountFormatter.string(fromByteCount: Int64(markdown.utf8.count), countStyle: .file)) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc").font(.system(size: 11))
                            Text("Copy")
                        }
                    }
                    .skButton()
                }
                ChunkedMarkdownText(markdown)
                    .textSelection(.enabled)
            }
        case .image(_, let fileID, let filename):
            ImagePage(fileID: fileID, filename: filename, back: back, backTitle: title)
                .onExitCommand(perform: back)
        }
    }

    private func pageScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            MKColumn {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectHidden(true, for: .top)
    }
}

/// This conversation's call settings, with Settings' form. Edits wait in
/// a save bar; the profile and the model show through in blue.
private struct CallSettingsPage: View {
    @Bindable var model: ConversationViewModel
    let title: String
    let back: () -> Void
    @Environment(ConversationsModel.self) private var convos
    @State private var baseline: PsmithCallSettings?
    @State private var saving = false

    private var selected: PsmithUserModel? {
        model.availableModels.first { $0.providerID == model.selectedProviderID && $0.modelID == model.selectedModelID }
    }

    private var inheritedFrom: String {
        let profile = model.draftProfile?.name ?? convos.profiles.first(where: { $0.id == model.conversation.profileID })?.name
        return [profile, selected?.displayName].compactMap { $0 }.joined(separator: " and ")
    }

    private var dirty: Bool { baseline != nil && baseline != model.conversationCallSettingsDraft }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MKColumn {
                    VStack(alignment: .leading, spacing: 0) {
                        SKBreadcrumb(parts: [(title, back)], current: "Call settings")
                        SKPageHead("Call settings", subtitle: inheritedFrom.isEmpty
                                   ? "For this conversation."
                                   : "For this conversation. Blue text is inherited from \(inheritedFrom).")
                        // A harness-bound conversation can't change provider,
                        // and its fixed parts come first.
                        if let harness = model.harness {
                            HarnessBindingCard(binding: harness).padding(.bottom, 22)
                        }
                        if model.preparingSettingsView {
                            MKSpinner(size: 16).frame(maxWidth: .infinity).padding(.vertical, 40)
                        } else {
                            SKCallSettings(
                                settings: $model.conversationCallSettingsDraft,
                                inherited: model.resolvedCallSettings,
                                inheritedFrom: inheritedFrom.isEmpty ? nil : inheritedFrom,
                                driver: model.selectedProviderID.flatMap { model.providerTypes[$0] } ?? "anthropic",
                                driverTabs: true,
                                constraints: selected?.constraints
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectHidden(true, for: .top)
            if dirty {
                SKSaveBar(summary: "Call settings changed", saving: saving) {
                    if let baseline { model.conversationCallSettingsDraft = baseline }
                } onSave: {
                    saving = true
                    Task {
                        await model.saveCallSettings()
                        baseline = model.conversationCallSettingsDraft
                        saving = false
                    }
                }
            }
        }
        .task {
            await model.prepareSettingsView()
            baseline = model.conversationCallSettingsDraft
        }
    }
}
