import SwiftUI
import ClarkKit

/// Full-pane "Contexts" view shown when the user opens the inbox button in
/// the conversation toolbar. Replaces the message scroll inline (no
/// popovers, no sheets) per the project's "no popup windows" convention.
/// Mirrors `NewConversationView`'s page structure: navigation title +
/// section labels + glass rows. Back navigation lives in the toolbar slot
/// owned by `ConversationBody` (the inbox button swaps to a chevron while
/// this page is active), so this view only renders the list itself.
///
/// Each row exposes the metadata the user asked for: created, updated
/// (proxied by activation time, which mirrors when the context was last
/// brought to the front), message count, last-turn token total, and
/// cumulative cost. Tapping a row activates that context and dismisses
/// the page; tapping the already-active row just dismisses.
struct ContextListPane: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.contexts.isEmpty {
                EmptyStateView(
                    "No contexts yet",
                    systemImage: "tray",
                    description: "Contexts appear after the conversation starts. Compacting also creates new contexts."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("\(model.contexts.count) context\(model.contexts.count == 1 ? "" : "s")")
                            .padding(.horizontal, 4)
                        ForEach(sorted) { ctx in
                            ContextRow(
                                context: ctx,
                                number: numbering[ctx.id] ?? 0,
                                parentLabel: parentLabel(for: ctx),
                                isActive: ctx.id == model.activeContext?.id
                            ) {
                                if ctx.id != model.activeContext?.id {
                                    Task {
                                        await model.activateContext(ctx.id)
                                        model.showingContextList = false
                                    }
                                } else {
                                    model.showingContextList = false
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Rows are listed newest-first by creation date so the freshly created
    /// context (e.g. just after compaction) is the natural first hit.
    /// Compaction sets `created_at` monotonically, so this ordering also
    /// matches the conversation's history flow top-to-bottom in the page.
    private var sorted: [ClarkContext] {
        model.contexts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Stable per-context ordinal — oldest = 1, newest = N — derived from
    /// creation order regardless of how the list is currently sorted. Larger
    /// number = newer, which matches the conversation's chronological flow
    /// and lets the parent reference ("parent: 3. …") read like a back-edge.
    private var numbering: [String: Int] {
        let asc = model.contexts.sorted { $0.createdAt < $1.createdAt }
        var map: [String: Int] = [:]
        for (i, ctx) in asc.enumerated() {
            map[ctx.id] = i + 1
        }
        return map
    }

    /// "parent: 3. Some title" if this context was forked from another one
    /// in the list. nil for root contexts. Falls back to `Context xxxxxxxx`
    /// when the parent has no title.
    private func parentLabel(for ctx: ClarkContext) -> String? {
        guard let pid = ctx.parentContextID,
              let parent = model.contexts.first(where: { $0.id == pid }),
              let n = numbering[parent.id]
        else { return nil }
        let title = (parent.title?.isEmpty == false) ? parent.title! : "Context \(n)"
        return "parent: \(n). \(title)"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// One row per context. Glass-rect background tinted with the accent color
/// when active, neutral otherwise — mirrors the row treatment in
/// `NewConversationView.modelRow` so the two pages feel like the same UX
/// language.
private struct ContextRow: View {
    let context: ClarkContext
    let number: Int
    let parentLabel: String?
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
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
            isActive ? .regular.tint(.accentColor.opacity(0.18)).interactive()
                     : .regular.interactive(),
            in: .rect(cornerRadius: 12)
        )
    }

    /// Five chips below the row title: created date, updated (activation)
    /// date, message count, last-turn tokens, cumulative cost. Each chip is
    /// a tiny `.glassEffect` capsule so the row reads as a stack of two
    /// rows (header + metadata band) without dropping to plain captions.
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
        .padding(.leading, 30) // align under the title (past the leading icon)
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
        // ContextRow already shows the leading ordinal ("3. <title>"), so the
        // "Context N" fallback would read like "3. Context 3" — redundant.
        // Drop the prefix in this fallback case; the row's own ordinal carries it.
        return "Untitled"
    }

    private func formatted(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}
