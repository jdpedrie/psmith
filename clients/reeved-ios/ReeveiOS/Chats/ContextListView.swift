import SwiftUI
import ReeveKit
import ReeveUI

/// iOS contexts list — pushed onto the conversation's NavigationStack
/// per `docs/ios-screens.md` §2.6. Tapping a row activates that
/// context and **pops back** to the conversation (one-shot
/// select-and-return: the user came here to switch, dropping them
/// back on the conversation immediately confirms the switch).
struct ContextListView: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.contexts.isEmpty {
                EmptyStateView(
                    "No contexts yet",
                    systemImage: "tray",
                    description: "Contexts appear after the conversation starts. Compacting also creates new contexts."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
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
                                        dismiss()
                                    }
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Contexts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sorted: [ReeveContext] {
        model.contexts.sorted { $0.createdAt > $1.createdAt }
    }

    private var numbering: [String: Int] {
        let asc = model.contexts.sorted { $0.createdAt < $1.createdAt }
        var map: [String: Int] = [:]
        for (i, ctx) in asc.enumerated() {
            map[ctx.id] = i + 1
        }
        return map
    }

    private func parentLabel(for ctx: ReeveContext) -> String? {
        guard let pid = ctx.parentContextID,
              let parent = model.contexts.first(where: { $0.id == pid }),
              let n = numbering[parent.id]
        else { return nil }
        let title = parent.title?.isEmpty == false ? parent.title! : "Context \(String(parent.id.prefix(8)))"
        return "parent: \(n). \(title)"
    }
}
