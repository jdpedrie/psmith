import SwiftUI
import PsmithKit
import PsmithUI

/// What the next send will run on, in precedence order: the composer's
/// live pick, the conversation's default, the profile's default.
extension ConversationViewModel {
    var ikProviderID: String? {
        if let p = selectedProviderID, !p.isEmpty { return p }
        if let p = conversation.settings?.defaultProviderID, !p.isEmpty { return p }
        return settingsResolvedProfile?.defaultSettings?.defaultProviderID
    }

    var ikModelID: String? {
        if let m = selectedModelID, !m.isEmpty { return m }
        if let m = conversation.settings?.defaultModelID, !m.isEmpty { return m }
        return settingsResolvedProfile?.defaultSettings?.defaultModelID
    }

    var ikModel: PsmithUserModel? {
        guard let p = ikProviderID, let m = ikModelID else { return nil }
        return availableModels.first { $0.providerID == p && $0.modelID == m }
    }

    var ikDriverType: String {
        ikProviderID.flatMap { providerTypes[$0] } ?? "anthropic"
    }

    /// True when the conversation pins its own model rather than following
    /// the profile's.
    var ikPinsModel: Bool { pinsModel }
}

/// The ground and bar treatment every conversation-scoped page shares.
struct IKConversationPage: ViewModifier {
    let title: String
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.hard, for: .top)
            .background(theme.chrome.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The ground and bar treatment every Settings page shares.
struct IKSettingsPageModifier: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.hard, for: .top)
            .background(IK.settingsGround.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func ikConversationPage(_ title: String) -> some View { modifier(IKConversationPage(title: title)) }
    func ikSettingsPage(_ title: String) -> some View { modifier(IKSettingsPageModifier(title: title)) }

    /// Keeps a save bar floating over the bottom safe area, and the content
    /// scrollable past it.
    func ikSaveBar<Bar: View>(_ visible: Bool, @ViewBuilder bar: () -> Bar) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if visible { bar().padding(.bottom, 0) }
        }
    }
}
