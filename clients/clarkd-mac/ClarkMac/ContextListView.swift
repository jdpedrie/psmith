import SwiftUI
import ClarkKit

/// Full-pane context list shown when the user picks "View contexts…" from
/// the title menu. Replaces the message scroll inline (no popovers) per
/// the project's no-popup convention. Each row shows the context's title,
/// active state, message count, and relative activation time. Tapping a
/// row activates that context and returns to the message view.
struct ContextListPane: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.showingContextList = false
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)

            Text("Contexts")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(model.contexts.count) context\(model.contexts.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var list: some View {
        if model.contexts.isEmpty {
            EmptyStateView(
                "No contexts yet",
                systemImage: "tray",
                description: "Contexts appear after the conversation starts. Compacting also creates new contexts."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sorted) { ctx in
                        ContextRow(
                            context: ctx,
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
                .padding(14)
            }
        }
    }

    private var sorted: [ClarkContext] {
        model.contexts.sorted {
            ($0.activationTime ?? .distantPast) > ($1.activationTime ?? .distantPast)
        }
    }
}

private struct ContextRow: View {
    let context: ClarkContext
    let isActive: Bool
    let onActivate: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Label("\(context.messageCount)", systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let activated = context.activationTime {
                            Label(activated.formatted(.relative(presentation: .named)), systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(12)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.10))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isActive
                            ? AnyShapeStyle(Color.accentColor.opacity(0.4))
                            : AnyShapeStyle(Color.primary.opacity(0.06))
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if hovering && !isActive {
                    Color.primary.opacity(0.04)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var title: String {
        if let t = context.title, !t.isEmpty { return t }
        return "Context \(context.id.prefix(8))"
    }
}
