import SwiftUI
import PsmithUI

/// iOS Appearance — adaptive grid of `ThemeCard` tiles per
/// `docs/clients/ios-reference.md` Skips the one-section middle list
/// (only Theme today) and pushes straight from SettingsRoot to this
/// detail. Tap a card → instant theme apply via `ThemeStore`.
struct AppearanceDetailView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show turn details", isOn: $prefs.showTurnDetails)
                Text("Role labels, the model on every reply, token counts and times, inline in the transcript. Off, a long-press on a reply shows them under Details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(Theme.allThemes) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: themeStore.current.id == theme.id,
                        onSelect: {
                            themeStore.current = theme
                        }
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
