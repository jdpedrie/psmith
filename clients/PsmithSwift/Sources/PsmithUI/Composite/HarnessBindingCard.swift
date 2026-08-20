import PsmithKit
import SwiftUI

/// Explains what a conversation gave up by running on a harness.
///
/// A stateful harness (Claude Code, Codex) holds the transcript itself, so
/// there is nothing to hand a different backend and nothing to rewrite when
/// the profile changes. Three controls stop working as a result, and each is
/// disabled somewhere else in the app. This card is the one place that says
/// why, so the user meets the explanation before the error rather than after.
///
/// Deliberately not a warning. Nothing is broken and there is nothing to fix;
/// the user chose a harness and this is what a harness is. Accent-tinted at
/// low opacity, secondary text, no yellow, no exclamation mark.
public struct HarnessBindingCard: View {
    private let binding: PsmithHarnessBinding

    @Environment(\.theme) private var theme

    public init(binding: PsmithHarnessBinding) {
        self.binding = binding
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(theme.accent)
                Text(binding.providerLabel)
                    .scaledFont(.caption, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 0)
            }

            Text("This conversation runs inside \(binding.providerLabel), which keeps the transcript on your machine. Psmith sends it one message at a time and never rebuilds the history, so a few things are fixed for the life of the conversation.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                constraint(
                    "arrow.left.arrow.right",
                    "Stays on this provider",
                    "You can still switch models within it. Another provider would need history that only \(binding.providerLabel) has."
                )
                if binding.systemPromptFrozen {
                    constraint(
                        "text.quote",
                        "System prompt is fixed",
                        "Set when the session opened. Editing the profile changes new conversations, not this one."
                    )
                }
                if !binding.acceptsAttachments {
                    constraint(
                        "paperclip",
                        "No attachments",
                        "Paste the relevant part into your message instead."
                    )
                }
            }

            Text("Start a new conversation to change any of this.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func constraint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(.caption, weight: .medium)
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
