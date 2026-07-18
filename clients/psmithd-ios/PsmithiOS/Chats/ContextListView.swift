import SwiftUI
import PsmithKit
import PsmithUI

/// iOS contexts list — pushed onto the conversation's NavigationStack
/// per `docs/clients/ios-reference.md` Tapping a row activates that
/// context and **pops back** to the conversation (one-shot
/// select-and-return: the user came here to switch, dropping them
/// back on the conversation immediately confirms the switch).
struct ContextListView: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewContext = false
    /// Context id awaiting delete confirmation. Set by the row's
    /// long-press menu; cleared when the dialog resolves either way.
    @State private var pendingDeleteContextID: String?

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
                                        dismiss()
                                    }
                                } else {
                                    dismiss()
                                }
                            }
                            .contextMenu {
                                if isActive {
                                    // The server refuses deleting the
                                    // active context; say why instead
                                    // of hiding the concept.
                                    Label("Active context can't be deleted", systemImage: "info.circle")
                                } else {
                                    Button(role: .destructive) {
                                        pendingDeleteContextID = ctx.id
                                    } label: {
                                        Label("Delete Context…", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
        }
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
        .navigationTitle("Contexts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewContext = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New context")
            }
        }
        .sheet(isPresented: $showingNewContext) {
            NewContextSheet(model: model) {
                showingNewContext = false
                dismiss()
            }
        }
    }

    private var sorted: [PsmithContext] {
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

    private func parentLabel(for ctx: PsmithContext) -> String? {
        guard let pid = ctx.parentContextID,
              let parent = model.contexts.first(where: { $0.id == pid }),
              let n = numbering[parent.id]
        else { return nil }
        let title = parent.title?.isEmpty == false ? parent.title! : "Context \(String(parent.id.prefix(8)))"
        return "parent: \(n). \(title)"
    }
}

/// Modal for the "+ New context" flow. Two controls:
///   - A multi-line text input for the seed user message (optional).
///   - A segmented picker between Replace (no prior framing) and
///     Append (inherit the prior context's role=context message).
/// On Create, the new context becomes active and ContextListView's
/// onCreate closure pops the user back to the conversation.
private struct NewContextSheet: View {
    let model: ConversationViewModel
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var initialUserMessage: String = ""
    @State private var mode: PsmithCompressionMode = .replace
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Initial user message") {
                    ZStack(alignment: .topLeading) {
                        if initialUserMessage.isEmpty {
                            Text("Optional. Type a starting prompt for the new context, or leave blank.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $initialUserMessage)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                    }
                }
                Section {
                    Picker("Prior framing", selection: $mode) {
                        Text("Replace").tag(PsmithCompressionMode.replace)
                        Text("Append").tag(PsmithCompressionMode.append)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(mode == .replace
                         ? "The new context starts fresh — no prior context message."
                         : "The new context inherits this conversation's prior context message verbatim.")
                }
            }
            .navigationTitle("New context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if creating {
                            ProgressView()
                        } else {
                            Text("Create").bold()
                        }
                    }
                    .disabled(creating)
                }
            }
        }
    }

    private func create() async {
        creating = true
        await model.createContextManual(
            initialUserMessage: initialUserMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode
        )
        creating = false
        onCreate()
    }
}
