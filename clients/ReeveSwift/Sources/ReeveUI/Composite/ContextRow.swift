import SwiftUI
import ReeveKit

/// One row per context — used by the Mac contexts page-replace and the
/// iOS push destination. Glass-rect background tinted with the theme
/// accent when active, neutral otherwise. Five metadata chips below
/// the title (created, updated, msg count, last-turn tokens,
/// cumulative cost).
public struct ContextRow: View {
    let context: ReeveContext
    let number: Int
    let parentLabel: String?
    let isActive: Bool
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    public init(
        context: ReeveContext,
        number: Int,
        parentLabel: String?,
        isActive: Bool,
        onActivate: @escaping () -> Void
    ) {
        self.context = context
        self.number = number
        self.parentLabel = parentLabel
        self.isActive = isActive
        self.onActivate = onActivate
    }

    public var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "tray.full")
                        .font(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(number). \(title)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let parentLabel {
                            Text(parentLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                metadataStrip
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive ? .regular.tint(theme.accent.opacity(0.18)).interactive()
                     : .regular.interactive(),
            in: .rect(cornerRadius: 12)
        )
    }

    private var metadataStrip: some View {
        HStack(spacing: 6) {
            metadataChip(systemImage: "calendar", text: "Created \(formatted(context.createdAt))")
            if let activated = context.activationTime {
                metadataChip(systemImage: "clock.arrow.circlepath", text: "Updated \(formatted(activated))")
            }
            metadataChip(systemImage: "bubble.left", text: "\(context.messageCount) msg\(context.messageCount == 1 ? "" : "s")")
            if context.lastMessageTotalTokens > 0 {
                metadataChip(
                    systemImage: "text.word.spacing",
                    text: "\(context.lastMessageTotalTokens.formatted()) tok"
                )
            }
            if context.cumulativeCostUsd > 0 {
                metadataChip(
                    systemImage: "dollarsign.circle",
                    text: context.cumulativeCostUsd.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 30)
    }

    private func metadataChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }

    private var title: String {
        if let t = context.title, !t.isEmpty { return t }
        return "Untitled"
    }

    private func formatted(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}
