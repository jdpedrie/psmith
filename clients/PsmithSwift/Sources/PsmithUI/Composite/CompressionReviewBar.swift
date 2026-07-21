import SwiftUI
import PsmithKit

/// Replaces the composer while a clean compression summary awaits the
/// user's decision. The conversation is deliberately limited in this
/// state — the server refuses sends and further compactions until the
/// summary is promoted or deleted — so the bottom bar IS the decision
/// surface: Delete resumes the current context as if compaction never
/// happened; Confirm promotes the summary into a fresh context.
///
/// The summary CONTENT lives in `CompressionSummaryCard` up in the
/// transcript (editable via its standard context menu); this bar
/// carries only the verdict. Orange accent ties the two together.
public struct CompressionReviewBar: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @State private var showDeleteConfirm = false
    @State private var isPromoting = false

    public init(message: PsmithMessage, model: ConversationViewModel) {
        self.message = message
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compression awaiting review")
                    .scaledFont(.subheadline)
                    .fontWeight(.semibold)
                Text("Confirm to continue in a fresh context, or delete to resume here.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)

            Button("Delete", role: .destructive) {
                showDeleteConfirm = true
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isPromoting)
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
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 64)
                } else {
                    Text("Confirm")
                        .frame(minWidth: 64)
                }
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .disabled(isPromoting)
            .help("Confirm the summary, open a fresh context, and continue from there")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) {
            // A hairline of the accent color over the divider so the
            // band reads as part of the compaction flow at a glance.
            Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1)
        }
    }
}
