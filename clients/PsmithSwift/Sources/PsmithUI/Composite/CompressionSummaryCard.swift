import SwiftUI
import PsmithKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Inline card rendered in the message stream for a compression
/// summary message (`role == .compression`). Two variants:
///
///   - **Success**: shows the streamed summary. The review ACTIONS
///     (Delete / Confirm) live in `CompressionReviewBar`, which
///     replaces the composer while the summary is pending — the card
///     is content, the bar is the decision. Editing goes through the
///     standard context menu, same as every other message row.
///   - **Failure**: shows the error text in red plus an optional
///     disclosure for any partial summary that streamed before the
///     failure, plus inline Dismiss / Retry (an errored summary does
///     NOT gate the conversation, so there's no review bar to host
///     its actions).
///
/// Orange accent throughout — distinct from regular assistant
/// messages so the user immediately recognises this as a compaction
/// artifact, not a normal turn.
public struct CompressionSummaryCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @State private var showDeleteConfirm = false
    @State private var showPartialContent = false

    public init(message: PsmithMessage, model: ConversationViewModel) {
        self.message = message
        self.model = model
    }

    /// Inline budget for the summary body — deliberately far below the
    /// message-bubble default. The card's job is "the summary is ready,
    /// review it"; a couple of paragraphs orient the user and the full
    /// document is one tap away. Keeping the card short also keeps the
    /// cold-entry window's tallest row bounded, which the transcript's
    /// entry machinery depends on (a multi-thousand-point row makes
    /// LazyVStack's content estimate flap at tick rate).
    static let summaryPreviewLimit = 1_500

    private var isErrored: Bool {
        message.errorText != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: isErrored
                      ? "exclamationmark.triangle.fill"
                      : "wand.and.stars")
                    .foregroundStyle(.orange)
                Text(isErrored ? "Compression failed" : "Compression summary")
                    .scaledFont(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Spacer()
                // Output-limit badge: the summary text is incomplete
                // even after the server's continuation legs (up to 4).
                // Confirming a truncated summary bakes the cut into
                // the fresh context, so make the state loud here and
                // let the review bar carry the recommendation.
                if !isErrored && message.isTruncatedOutput {
                    Label("Truncated", systemImage: "scissors")
                        .scaledFont(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                // Which model produced this summary — same trailing
                // slot the assistant rows use for their model label.
                // (This used to read "Awaiting review — actions
                // below" on clean summaries, which duplicated the
                // review bar's own title and hid the model.)
                if let label = compressionModelLabel {
                    Text(label)
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if isErrored {
                erroredBody
            } else {
                // Bounded, not raw MarkdownText: a multi-leg compaction
                // summary can run past 100KB, and an unbounded inline
                // render of that hard-locks the app on entry (the
                // transcript's single layout pass never returns). The
                // preview + full-text viewer keeps entry O(preview).
                BoundedMarkdownText(
                    message.content,
                    cacheKey: markdownCacheKey,
                    documentTitle: "Compression summary",
                    limit: Self.summaryPreviewLimit
                )
                .scaledFont(.callout)
                if message.isTruncatedOutput {
                    Text("Cut off at the model's output limit — the tail of the summary is missing. Delete and re-run compaction rather than confirming.")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = usageSummaryLine {
                    Text(summary)
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isErrored {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Dismiss") {
                        Task { await model.deleteMessage(id: message.id) }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this failed compaction from the history. You can retry compaction at any time.")

                    Button {
                        Task { await model.compact() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isCompacting || model.sending || model.isStreaming)
                    .help("Re-fire compaction with the current profile defaults. The failed summary stays in history until dismissed.")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color.orange.opacity(isErrored ? 0.55 : 0.35),
                    lineWidth: 1.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // The STANDARD message affordances — same long-press/right-click
        // controls every other row gets, replacing the old inline
        // "Edit…" special case. Delete here shares the confirmation
        // with the review bar's Delete; both are the same operation.
        .contextMenu {
            if !isErrored {
                Button {
                    model.editingMessage = message
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            Button {
                copyContent()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } preview: {
            // Explicit upright preview: on iOS the card renders
            // inside the inverted transcript's flip and the automatic
            // preview snapshot degenerates on transformed rows.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.orange)
                    Text("Compression summary")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
                // Raw head cut, not BoundedMarkdownText — its "Show
                // full text" affordance would render as a dead button
                // inside the preview snapshot.
                MarkdownText(
                    MarkdownBudget.head(message.content, limit: 600) ?? message.content
                )
                .scaledFont(.callout)
            }
            .padding(12)
            .frame(maxWidth: 340, alignment: .leading)
        }
        .confirmationDialog(
            "Delete compression summary?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete summary", role: .destructive) {
                Task { await model.deleteMessage(id: message.id) }
            }
        } message: {
            Text("The conversation will resume in the current context as if compaction never happened.")
        }
    }

    private func copyContent() {
        #if canImport(UIKit)
        UIPasteboard.general.string = message.content
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
    }

    /// Body for an errored compression card: error text in red + an optional
    /// disclosure for any partial summary text streamed before the failure.
    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .scaledFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !message.content.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    // A failure after several continuation legs can
                    // leave a partial as big as a full summary — same
                    // bounded treatment as the success body.
                    BoundedMarkdownText(
                        message.content,
                        cacheKey: markdownCacheKey,
                        documentTitle: "Partial summary",
                        limit: Self.summaryPreviewLimit
                    )
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                } label: {
                    Text("Partial summary streamed before failure")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One-line token + cost summary for the compaction call. Mirrors
    /// MessageRow's bubble footer so a compression with usage data
    /// reads the same way as a regular assistant turn (in/out/cache,
    /// trailing $cost). Returns nil when the row has no usage payload
    /// — local-FoundationModels compactions and very old DB rows.
    private var usageSummaryLine: String? {
        guard let u = message.usage else { return nil }
        var parts: [String] = []
        if let n = u.inputTokens {
            var inputPart = "in: \(n.formatted())"
            if let cr = u.cacheReadTokens, cr > 0 {
                inputPart += " (\(cr.formatted()) cached)"
            }
            parts.append(inputPart)
        }
        if let cw = u.cacheWriteTokens, cw > 0 {
            parts.append("cw: \(cw.formatted())")
        }
        if let n = u.outputTokens {
            parts.append("out: \(n.formatted())")
        }
        if let c = u.totalCostUsd {
            parts.append("$\(String(format: "%.4f", c))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "<Provider Label> <Model Display Name>" with graceful fallbacks.
    /// Mirrors `MessageRow.modelDisplayLabel` so the failed compression
    /// summary header reads consistently with assistant message rows.
    /// Stable cache key for the summary's parsed MarkdownContent.
    /// Includes edited_at so post-edit content is re-parsed.
    private var markdownCacheKey: String {
        let stamp = message.editedAt?.timeIntervalSince1970 ?? 0
        return "\(message.id):\(stamp)"
    }

    private var compressionModelLabel: String? {
        guard let mid = message.modelID, !mid.isEmpty else { return nil }
        let pid = message.providerID
        let providerLabel = pid.flatMap { model.providerLabels[$0] }
        let modelDisplay = model.availableModels
            .first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) })?
            .displayName
        switch (providerLabel, modelDisplay) {
        case let (p?, m?): return "\(p) \(m)"
        case let (p?, nil): return "\(p) \(mid)"
        case let (nil, m?): return m
        case (nil, nil): return mid
        }
    }
}
