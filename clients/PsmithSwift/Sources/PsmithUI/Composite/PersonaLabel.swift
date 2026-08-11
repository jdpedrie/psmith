import PsmithKit
import SwiftUI

/// Speaker attribution for a message in a conversation with more than one
/// voice in it.
///
/// Two goals in tension. Speakers have to be distinguishable at a glance, so a
/// discussion reads as grouped rather than as a wall of text. And Psmith's
/// themes are each built around one hue plus neutrals, several of them
/// explicitly low-stimulus, so five saturated colors would flatten them.
///
/// The resolution is that structure does most of the work and color is the
/// fast-scan accelerant. The name is the information: anyone colorblind or
/// reading in sunlight gets the full grouping without the color. The rail is
/// what the eye tracks when scrolling past quickly, since it reads as a
/// continuous stripe without being read.
///
/// The color always comes from the active theme's `personaColors`, never from
/// the server, which only ever sends a palette slot.
public struct PersonaLabel: View {
    private let name: String
    private let index: Int

    @Environment(\.theme) private var theme

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.personaColor(index))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.personaColor(index))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Said by \(name)")
    }
}

/// The vertical stripe down the left of a persona's message.
///
/// Deliberately thin and low-contrast. It is a grouping cue, not a decoration,
/// and it sits beside body text that has to stay the most legible thing on
/// screen.
public struct PersonaRail: View {
    private let index: Int

    @Environment(\.theme) private var theme

    public init(index: Int) {
        self.index = index
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(theme.personaColor(index).opacity(0.55))
            .frame(width: 3)
            .accessibilityHidden(true)
    }
}

public extension View {
    /// Wraps a message body in its speaker's rail and indent.
    ///
    /// A no-op when there is no persona, so an ordinary conversation is
    /// untouched and nothing shifts for the single-assistant case.
    @ViewBuilder
    func personaRail(index: Int?) -> some View {
        if let index {
            HStack(alignment: .top, spacing: 8) {
                PersonaRail(index: index)
                self
            }
        } else {
            self
        }
    }
}
