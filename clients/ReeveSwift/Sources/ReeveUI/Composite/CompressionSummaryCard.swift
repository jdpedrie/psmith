import SwiftUI
import ReeveKit

/// Inline card rendered in the message stream for a compression
/// summary message (`role == .compression`). Two variants:
///
///   - **Success**: shows the streamed summary, plus Edit / Delete /
///     Confirm. Confirm promotes the summary into a fresh context;
///     Edit reopens the user's compaction prompt for revision.
///   - **Failure**: shows the error text in red plus an optional
///     disclosure for any partial summary that streamed before the
///     failure, plus a single Dismiss action.
///
/// Orange accent throughout — distinct from regular assistant
/// messages so the user immediately recognises this as a compaction
/// artifact, not a normal turn.
public struct CompressionSummaryCard: View {
    let message: ReeveMessage
    let model: ConversationViewModel
    @State private var showDeleteConfirm = false
    @State private var isPromoting = false
    @State private var showPartialContent = false

    public init(message: ReeveMessage, model: ConversationViewModel) {
        self.message = message
        self.model = model
    }

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
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Spacer()
                if !isErrored {
                    Text("Review and promote or delete")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let label = compressionModelLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if isErrored {
                erroredBody
            } else {
                MarkdownText(message.content)
                    .font(.callout)
                if let summary = usageSummaryLine {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 8) {
                if isErrored {
                    Spacer()
                    Button("Dismiss") {
                        Task { await model.deleteMessage(id: message.id) }
                    }
                    .buttonStyle(.glassProminent)
                    .help("Remove this failed compaction from the history. You can retry compaction at any time.")
                } else {
                    Button("Edit…") {
                        model.editingMessage = message
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("Delete") {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
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

                    Button {
                        isPromoting = true
                        Task {
                            await model.promoteCompaction(messageID: message.id)
                            isPromoting = false
                        }
                    } label: {
                        if isPromoting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Confirm")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isPromoting)
                    .help("Confirm the summary, open a fresh context, and continue from there")
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
    }

    /// Body for an errored compression card: error text in red + an optional
    /// disclosure for any partial summary text streamed before the failure.
    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !message.content.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    MarkdownText(message.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text("Partial summary streamed before failure")
                        .font(.caption)
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
