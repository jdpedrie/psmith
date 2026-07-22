import SwiftUI
import PsmithKit
import PsmithUI

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
    /// Row the pointer is over — drives the hover-revealed delete
    /// button. (An inline button, not a context menu: row context
    /// menus render as a window-wide black box on macOS 26.)
    @State private var hoveredContextID: String?
    /// Context id awaiting delete confirmation.
    @State private var pendingDeleteContextID: String?

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
                            let isActive = ctx.id == model.activeContext?.id
                            ContextRow(
                                context: ctx,
                                number: numbering[ctx.id] ?? 0,
                                parentLabel: parentLabel(for: ctx),
                                isActive: isActive
                            ) {
                                if !isActive {
                                    Task {
                                        await model.activateContext(ctx.id)
                                        model.showingContextList = false
                                    }
                                } else {
                                    model.showingContextList = false
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                // Delete lives on non-active rows only —
                                // the server refuses the active context
                                // (it's the conversation's live surface).
                                if !isActive, hoveredContextID == ctx.id {
                                    Button {
                                        pendingDeleteContextID = ctx.id
                                    } label: {
                                        Image(systemName: "trash")
                                            .scaledFont(size: 11, weight: .semibold)
                                            .foregroundStyle(.red)
                                            .frame(width: 26, height: 26)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .help("Delete context and all of its messages")
                                    .padding(8)
                                }
                            }
                            .onHover { inside in
                                hoveredContextID = inside ? ctx.id : (hoveredContextID == ctx.id ? nil : hoveredContextID)
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
        .confirmationDialog(
            "Delete this context?",
            isPresented: Binding(
                get: { pendingDeleteContextID != nil },
                set: { if !$0 { pendingDeleteContextID = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteContextID
        ) { ctxID in
            Button("Delete Context and Messages", role: .destructive) {
                Task { await model.deleteContext(ctxID) }
                pendingDeleteContextID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteContextID = nil }
        } message: { _ in
            Text("Every message in this context is permanently deleted. This can't be undone.")
        }
    }

    /// Rows are listed newest-first by creation date so the freshly created
    /// context (e.g. just after compaction) is the natural first hit.
    /// Compaction sets `created_at` monotonically, so this ordering also
    /// matches the conversation's history flow top-to-bottom in the page.
    private var sorted: [PsmithContext] {
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
    private func parentLabel(for ctx: PsmithContext) -> String? {
        guard let pid = ctx.parentContextID,
              let parent = model.contexts.first(where: { $0.id == pid }),
              let n = numbering[parent.id]
        else { return nil }
        let title = (parent.title?.isEmpty == false) ? parent.title! : "Context \(n)"
        return "parent: \(n). \(title)"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
    }
}

// `ContextRow` extracted to PsmithUI/Composite/ContextRow.swift for
// iOS reuse. The Mac call site above passes the same arguments that
// the shared init expects.

#if false  // legacy Mac-private definition retired
private struct ContextRow_Legacy: View {
    let context: PsmithContext
    let number: Int
    let parentLabel: String?
    let isActive: Bool
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "tray.full")
                        .scaledFont(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(number). \(title)")
                            .scaledFont(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let parentLabel {
                            Text(parentLabel)
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if isActive {
                            Text("Active")
                                .scaledFont(.caption2, weight: .semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark")
                            .scaledFont(.callout, weight: .semibold)
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
                // The server aggregate prices the cache delta (see
                // Context.cache_savings_usd): billed is what actually
                // hit the ledger, saved is what full-price input would
                // have added on top.
                metadataChip(
                    systemImage: "dollarsign.circle",
                    text: context.cacheSavingsUsd >= 0.0001
                        ? "billed \(costText(context.cumulativeCostUsd)) · saved \(costText(context.cacheSavingsUsd))"
                        : costText(context.cumulativeCostUsd)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 30) // align under the title (past the leading icon)
    }

    private func costText(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(4)))
    }

    private func metadataChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .scaledFont(.caption2)
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
#endif
