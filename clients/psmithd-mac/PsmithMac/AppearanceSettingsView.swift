import SwiftUI
import PsmithUI

/// The Appearance pane (board "Appearance"): theme, text size, transcript.
/// Everything here is stored on this Mac and applies as it changes.
struct AppearanceSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SKFormPage(width: 700) {
            SKGroup("Theme") {
                SKRawRow(vertical: 12, horizontal: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 10) {
                        ForEach(Theme.allThemes) { theme in
                            ThemeTile(theme: theme, selected: themeStore.current.id == theme.id) {
                                themeStore.current = theme
                            }
                        }
                    }
                }
            } trailing: {
                SKChip.thisMac
            } footer: {
                Text("Sets the accent, your message bubbles, the selection highlight, the window tint and the Dock icon. The windows use its dark colors.")
            }

            SKGroup("Text") {
                SKRow("Size", detail: "⌘+ and ⌘− work anywhere; ⌘0 resets.") {
                    HStack(spacing: 10) {
                        if prefs.fontScale != 1.0 {
                            Button("Reset") { prefs.fontScale = 1.0 }.skButton(.plain)
                        }
                        // Fixed sizes: they label the slider's ends, not the setting.
                        Text("A").font(.system(size: 11)).foregroundStyle(SK.secondary)
                        SKSlider(
                            value: $prefs.fontScale,
                            range: AppPreferences.minFontScale...AppPreferences.maxFontScale,
                            step: AppPreferences.fontScaleStep,
                            width: 200,
                            ticks: Int(((AppPreferences.maxFontScale - AppPreferences.minFontScale) / AppPreferences.fontScaleStep).rounded()) + 1
                        )
                        Text("A").font(.system(size: 18)).foregroundStyle(SK.secondary)
                        Text(String(format: "%.0f%%", prefs.fontScale * 100)).sk(13, SK.secondary, mono: true)
                    }
                }
            } trailing: {
                SKChip.thisMac
            }

            SKGroup("Transcript") {
                SKRow("Show turn details", detail: "Role labels, the model on every reply, token counts and times.") {
                    Toggle("Show turn details", isOn: $prefs.showTurnDetails).skSwitch()
                }
            } trailing: {
                SKChip.thisMac
            } footer: {
                Text("Off, the transcript keeps only what's worth noticing: a model change, a poor cache on a large prompt, a reply that stopped early.")
            }
        }
    }
}

/// One theme in the grid: name and check, a two-bubble preview in the
/// theme's colors, and a line about it.
private struct ThemeTile: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    /// The board's wording, shorter than Theme.blurb, which iOS shows in full.
    private var blurb: String {
        switch theme.id {
        case "system": "Your system accent and stock neutrals."
        case "sage": "Deep sage on a soft green-gray ground."
        case "clay": "Terracotta on linen-paper neutrals."
        case "slate": "Steel blue on blue-gray neutrals."
        case "aubergine": "Plum on warm cream."
        case "nordic": "Fjord blue on icy gray."
        default: theme.blurb
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(theme.name).sk(13, weight: .semibold).skOneLine(13)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 14, height: 14)
                    }
                }
                VStack(spacing: 4) {
                    Text("Capital of Japan?")
                        .sk(11, .white)
                        .skOneLine(11)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Tokyo.")
                        .sk(11)
                        .skOneLine(11)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(blurb).sk(11, SK.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? theme.accent : SK.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
