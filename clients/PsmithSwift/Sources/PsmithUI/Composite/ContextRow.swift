import SwiftUI
import PsmithKit

/// One row per context — used by the Mac contexts page-replace and the
/// iOS push destination. Glass-rect background tinted with the theme
/// accent when active, neutral otherwise. Five metadata chips below
/// the title (created, updated, msg count, last-turn tokens,
/// cumulative cost).
public struct ContextRow: View {
    let context: PsmithContext
    let number: Int
    let parentLabel: String?
    let isActive: Bool
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    public init(
        context: PsmithContext,
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
        // Wrap with a Layout-based flow so multiple chips can stack
        // onto extra rows on narrow widths (iPhone). On Mac the strip
        // typically fits one row; the layout collapses to that case.
        FlowHStack(spacing: 6, lineSpacing: 4) {
            metadataChip(systemImage: "calendar", text: "Created \(shortDate(context.createdAt))")
            if let activated = context.activationTime {
                metadataChip(systemImage: "clock.arrow.circlepath", text: "Updated \(shortDate(activated))")
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
        }
        .padding(.leading, 30)
    }

    private func metadataChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }

    /// Compact date format for the chips: drops the "at HH:MM" tail
    /// the system's `.shortened` style appends. The chips already
    /// communicate "this is a date" via the icon and label prefix;
    /// the time-of-day adds noise without paying for itself.
    private func shortDate(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }

    private var title: String {
        if let t = context.title, !t.isEmpty { return t }
        return "Untitled"
    }

    private func formatted(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}
