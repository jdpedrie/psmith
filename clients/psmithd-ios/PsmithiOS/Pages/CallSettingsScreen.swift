import SwiftUI
import PsmithKit
import PsmithUI

/// This conversation's call-settings overrides (board CallSettingsPage).
/// Edits stage in a draft; the save bar writes them or throws them away.
struct CallSettingsScreen: View {
    @Bindable var model: ConversationViewModel
    var autoload = true
    @State var draft: PsmithCallSettings
    @State private var prepared = false
    @State private var saving = false

    init(model: ConversationViewModel, autoload: Bool = true, draft: PsmithCallSettings? = nil) {
        self.model = model
        self.autoload = autoload
        _draft = State(initialValue: draft ?? model.conversationCallSettingsDraft)
    }

    private var pending: Int { IKCallSettingsDiff.count(draft, model.conversationCallSettingsDraft) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let harness = model.harness {
                    HarnessBindingCard(binding: harness).padding(.bottom, 12)
                }
                IKPageNote(intro, top: 0)
                if model.preparingSettingsView {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    IKCallSettingsForm(settings: $draft, inherited: model.resolvedCallSettings,
                                       driverType: model.ikDriverType, capabilities: model.ikModel?.capabilities,
                                       constraints: model.ikModel?.constraints, showAllProviderSections: true, style: .page)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, -2)
            .padding(.bottom, 24)
        }
        .ikConversationPage("Call settings")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pending > 0 {
                IKSaveBar(summary: IKCallSettingsDiff.summary(pending), ground: .themed, canSave: !saving,
                          onRevert: revert, onSave: { Task { await save() } })
            }
        }
        .task {
            guard autoload, !prepared else { return }
            prepared = true
            let untouched = pending == 0
            await model.prepareSettingsView()
            if untouched { draft = model.conversationCallSettingsDraft }
        }
    }

    private var intro: String {
        let profile = model.settingsResolvedProfile?.name
        let modelName = model.ikModel?.displayName
        let chain = [profile, modelName].compactMap { $0 }.joined(separator: ", then ")
        let inherit = chain.isEmpty ? "Unset fields inherit from the profile, then the model." : "Unset fields inherit from \(chain)."
        return "Overrides for this conversation only. \(inherit) A dot marks an override."
    }

    func revert() { draft = model.conversationCallSettingsDraft }

    func save() async {
        saving = true
        defer { saving = false }
        model.conversationCallSettingsDraft = draft
        await model.saveCallSettings()
    }
}
