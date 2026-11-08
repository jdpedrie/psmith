import SwiftUI
import PsmithKit
import PsmithUI

// Cards that take the composer's place while something else needs an
// answer first: compress (Compress), a summary to review (Review,
// ReviewTruncated), an archived conversation (Archived), a tool asking
// for input (Elicit).

/// The slot's glass card with an optional colored ring.
private struct SlotCard<Content: View>: View {
    var ring: Color?
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ikGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                if let ring {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(ring, lineWidth: 1)
                }
            }
    }
}

private struct SlotTitle: View {
    let systemImage: String
    let title: String
    var color: Color
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
            }
            Text(detail).cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Compress

struct CompressCard: View {
    @Bindable var model: ConversationViewModel
    let ui: ConversationUIState

    private var tokens: Int32? { model.contextTokens }
    private var empty: Bool { model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SlotCard {
            VStack(alignment: .leading, spacing: 0) {
                SlotTitle(systemImage: "rectangle.expand.vertical", title: "Compress into a new context", color: IK.strong,
                          detail: detail)
                Text("Instructions").font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
                    .padding(.top, 12)
                TextField(model.preparingCompactView ? "Loading the profile’s instructions" : "What should the summary keep?",
                          text: $model.compactPromptDraft, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(3...6)
                    .foregroundStyle(IK.text)
                    .padding(.horizontal, 12)
                    // The field can't take line spacing without clipping;
                    // the board's three 21pt lines come back as padding.
                    .padding(.vertical, 10 + 4.65)
                    .background(RoundedRectangle(cornerRadius: 12).fill(IK.well))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IK.ring(0.08), lineWidth: 1))
                    .padding(.top, 6)
                Menu {
                    ForEach(model.availableModels) { m in
                        Button {
                            model.compactProviderID = m.providerID
                            model.compactModelID = m.modelID
                        } label: {
                            if m.modelID == model.compactModelID && m.providerID == model.compactProviderID {
                                Label(m.displayName, systemImage: "checkmark")
                            } else {
                                Text(m.displayName)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Summarize with").foregroundStyle(IK.secondary)
                        Spacer(minLength: 8)
                        Text(model.modelDisplayName(providerID: model.compactProviderID, modelID: model.compactModelID) ?? "Choose a model")
                            .foregroundStyle(IK.text).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(IK.secondary)
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                if let err = model.compactError {
                    Text(err).font(.system(size: 13)).foregroundStyle(IK.red).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Cancel") { ui.cancelCompress(model: model) }.ikButton(height: 40, fill: true)
                    Button("Compress") { ui.startCompress(model: model) }
                        .ikButton(.primary, height: 40, fill: true)
                        .disabled(model.compactProviderID == nil || model.compactModelID == nil || empty || model.isCompacting)
                }
                .padding(.top, 12)
            }
        }
    }

    private var detail: String {
        let n = tokens.map { "\($0.formatted()) tokens" } ?? "this context"
        return "A model summarizes \(n). You review the summary before the next message goes out. The old context stays readable."
    }
}

// MARK: - Review

struct ReviewCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let ui: ConversationUIState
    @State private var promoting = false

    private var truncated: Bool { message.isTruncatedOutput }

    var body: some View {
        SlotCard(ring: IK.orange.opacity(0.45)) {
            if ui.confirmingSummaryDelete {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Delete the summary?").font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                    Text("The conversation carries on in this context as if it never compressed.")
                        .cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        Button("Cancel") { ui.confirmingSummaryDelete = false }.ikButton(height: 40, fill: true)
                        Button("Delete") {
                            ui.confirmingSummaryDelete = false
                            Haptics.notify(.warning)
                            Task { await model.deleteMessage(id: message.id) }
                        }
                        .ikButton(.destructive, height: 40, fill: true)
                    }
                    .padding(.top, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SlotTitle(systemImage: "rectangle.expand.vertical",
                              title: truncated ? "Truncated summary awaiting review" : "Compression awaiting review",
                              color: IK.orange,
                              detail: truncated
                                ? "The summary is incomplete. Delete it and compress again."
                                : "Confirm to continue in a fresh context, or delete the summary to carry on here.")
                    if truncated {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(IK.orange).padding(.top, 2)
                            Text(limitNote).cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(IK.orange.opacity(0.12)))
                        .padding(.top, 10)
                    }
                    HStack(spacing: 8) {
                        if truncated {
                            confirmButton(prominent: false)
                            editButton
                            deleteButton(prominent: true)
                        } else {
                            deleteButton(prominent: false)
                            editButton
                            confirmButton(prominent: true)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var limitNote: String {
        if let out = message.usage?.outputTokens {
            return "It stopped at the \(out.formatted()) token output limit. Confirming keeps the cut text."
        }
        return "It stopped at the model’s output limit. Confirming keeps the cut text."
    }

    private func deleteButton(prominent: Bool) -> some View {
        Button { ui.confirmingSummaryDelete = true } label: {
            Label("Delete", systemImage: "trash").labelStyle(TightLabel())
                .foregroundStyle(prominent ? Color.white : IK.red)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .ikButton(prominent ? .destructive : .plain, height: 40, fill: true)
        .disabled(promoting)
    }

    private var editButton: some View {
        Button { ui.beginEdit(message, model: model) } label: {
            Label("Edit", systemImage: "pencil").labelStyle(TightLabel())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .ikButton(height: 40, fill: true)
        .disabled(promoting)
    }

    @ViewBuilder
    private func confirmButton(prominent: Bool) -> some View {
        Button {
            promoting = true
            Task {
                await model.promoteCompaction(messageID: message.id)
                promoting = false
            }
        } label: {
            if promoting { IKSpinner(color: .white) } else { Text("Confirm") }
        }
        .buttonStyle(AmberButtonStyle(prominent: prominent))
        .disabled(promoting)
    }
}

/// Confirm on a summary under review: amber, the summary's color.
private struct AmberButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : IK.text)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(prominent ? IK.amberFill : IK.wash(0.09)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Archived

struct ArchivedCard: View {
    let conversationID: String
    let archivedAt: Date
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SlotCard {
            HStack(spacing: 12) {
                Image(systemName: "archivebox").font(.system(size: 20)).foregroundStyle(IK.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Archived").font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                    Text("Archived \(archivedAt.formatted(.dateTime.month(.abbreviated).day())). Unarchive to reply.")
                        .cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Unarchive") {
                    Task {
                        await convos.unarchive(conversationID)
                        dismiss()
                    }
                }
                .ikButton(.primary, height: 44)
            }
        }
    }
}

// MARK: - Tool input

/// What a tool asks for mid-reply. Mirrors the stream's pending
/// elicitation as a value the card (and tests) can build.
struct ElicitRequest: Identifiable, Equatable {
    let id: String
    let message: String
    let schemaJSON: Data
}

struct ElicitCard: View {
    let conversationID: String
    let request: ElicitRequest
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var fields: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var working = false
    @State private var error: String?
    @State private var seeded = false

    var body: some View {
        let schema = ElicitSchema(request.schemaJSON)
        SlotCard(ring: theme.accent.opacity(0.5)) {
            VStack(alignment: .leading, spacing: 0) {
                SlotTitle(systemImage: "key.horizontal", title: "Psmith needs input", color: theme.accentInk,
                          detail: request.message)
                VStack(spacing: 8) {
                    ForEach(schema.fields, id: \.name) { field in row(field) }
                }
                .padding(.top, 12)
                Text(error ?? "The reply waits until you answer.")
                    .font(.system(size: 12.5)).foregroundStyle(error == nil ? IK.tertiary : IK.red)
                    .padding(.top, 8)
                HStack(spacing: 8) {
                    Button("Cancel") { Task { await submit(.cancel, schema) } }.ikButton(height: 40, fill: true)
                    Button("Decline") { Task { await submit(.decline, schema) } }.ikButton(height: 40, fill: true)
                    Button("Submit") { Task { await submit(.accept, schema) } }
                        .ikButton(.primary, height: 40, fill: true)
                        .disabled(!schema.requiredFilled(fields))
                }
                .disabled(working)
                .padding(.top, 10)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            for f in schema.fields {
                switch f.kind {
                case .boolean: if let d = f.defaultBool { bools[f.name] = d }
                default: if let d = f.defaultText { fields[f.name] = d }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ f: ElicitSchema.Field) -> some View {
        switch f.kind {
        case .boolean:
            HStack(spacing: 10) {
                Text(f.label).font(.system(size: 13.5)).foregroundStyle(IK.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(f.label, isOn: Binding(get: { bools[f.name] ?? false }, set: { bools[f.name] = $0 }))
                    .labelsHidden()
                    .tint(theme.accent)
            }
            .frame(minHeight: 44)
        default:
            HStack(spacing: 10) {
                Text(f.label).font(.system(size: 13.5)).foregroundStyle(IK.secondary)
                    .lineLimit(2)
                    .frame(width: 96, alignment: .leading)
                Group {
                    if f.kind == .password {
                        SecureField(f.placeholder, text: binding(f.name))
                    } else {
                        TextField(f.placeholder, text: binding(f.name))
                            .keyboardType(f.kind == .integer ? .numberPad : .default)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(IK.text)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(IK.well))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1))
                .accessibilityLabel(f.label)
            }
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { fields[name] ?? "" }, set: { fields[name] = $0 })
    }

    private func submit(_ action: PsmithElicitAction, _ schema: ElicitSchema) async {
        working = true
        error = nil
        defer { working = false }
        let content = action == .accept ? schema.payload(fields: fields, bools: bools) : nil
        do {
            try await app.elicitations.respond(conversationID: conversationID, elicitationID: request.id,
                                               action: action, content: content)
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: request.id)
        } catch PsmithElicitationError.notFound {
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: request.id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

/// The narrow JSON Schema an elicitation carries: an object of string,
/// password, integer and boolean properties. Text fields come first,
/// switches after, each group alphabetical (JSON objects keep no order).
struct ElicitSchema {
    struct Field {
        enum Kind { case string, password, integer, boolean }
        let name: String
        let kind: Kind
        let description: String?
        let defaultText: String?
        let defaultBool: Bool?
        var label: String {
            name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        var placeholder: String { description ?? "" }
    }

    let fields: [Field]
    let required: Set<String>

    init(_ data: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let props = obj["properties"] as? [String: [String: Any]] ?? [:]
        required = Set(obj["required"] as? [String] ?? [])
        var out: [Field] = []
        for name in props.keys.sorted() {
            let p = props[name] ?? [:]
            let kind: Field.Kind
            switch p["type"] as? String ?? "string" {
            case "boolean": kind = .boolean
            case "integer", "number": kind = .integer
            default: kind = (p["format"] as? String) == "password" ? .password : .string
            }
            let def = p["default"]
            out.append(Field(name: name, kind: kind, description: p["description"] as? String,
                             defaultText: (def as? String) ?? (def as? NSNumber).map { "\($0)" },
                             defaultBool: def as? Bool))
        }
        fields = out.filter { $0.kind != .boolean } + out.filter { $0.kind == .boolean }
    }

    func requiredFilled(_ values: [String: String]) -> Bool {
        fields.allSatisfy { f in
            guard required.contains(f.name), f.kind != .boolean else { return true }
            return !(values[f.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func payload(fields values: [String: String], bools: [String: Bool]) -> Data? {
        var out: [String: Any] = [:]
        for f in fields {
            switch f.kind {
            case .string, .password: out[f.name] = values[f.name] ?? ""
            case .integer: out[f.name] = Int(values[f.name] ?? "") ?? 0
            case .boolean: out[f.name] = bools[f.name] ?? false
            }
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }
}
