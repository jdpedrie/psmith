import SwiftUI
import PsmithUI

/// iOS Appearance — adaptive grid of `ThemeCard` tiles per
/// `docs/clients/ios-reference.md` Skips the one-section middle list
/// (only Theme today) and pushes straight from SettingsRoot to this
/// detail. Tap a card → instant theme apply via `ThemeStore`.
struct AppearanceDetailView: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        ScrollView {
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
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}
