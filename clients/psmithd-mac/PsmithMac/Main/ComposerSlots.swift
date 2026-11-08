import SwiftUI
import PsmithKit
import PsmithUI

// Cards that take the composer's place (boards AppReview, AppElicit,
// AppCompress, AppListArchived): whatever has to happen before the next
// message sits where the next message would be typed, at the composer's
// width. Nothing floats over the transcript and nothing is a sheet.

/// The header every slot card opens with: icon, title, one line of detail.
struct SlotHead: View {
    let systemImage: String
    let title: String
    let detail: String
    var tint: Color = SK.secondary
    var detailColor: Color = SK.secondary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 13.5, weight: .medium)).foregroundStyle(tint).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).sk(13, weight: .semibold).skOneLine(13)
                Text(detail).sk(11.5, detailColor).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An archived conversation: readable, not writable, one click back.
struct ArchivedCard: View {
    let conversationID: String
    let archivedAt: Date
    @Environment(ConversationsModel.self) private var convos

    var body: some View {
        MKSlotCard {
            HStack(spacing: 12) {
                SlotHead(systemImage: "archivebox", title: "Archived",
                         detail: "Archived \(archivedAt.formatted(.dateTime.month(.abbreviated).day())). Unarchive to reply.")
                Button("Unarchive") { Task { await convos.unarchive(conversationID) } }
                    .skButton(.primary)
            }
        }
    }
}

/// A clean compression summary waiting for a decision. The server refuses
/// sends until it's confirmed or deleted.
struct ReviewCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @State private var confirmingDelete = false
    @State private var promoting = false

    var body: some View {
        MKSlotCard(ring: SK.orange.opacity(0.4)) {
            if confirmingDelete {
                HStack(spacing: 10) {
                    SlotHead(systemImage: "exclamationmark.triangle", title: "Delete the summary?",
                             detail: "The conversation carries on in this context as if it never ran.", tint: SK.red)
                    Button("Cancel") { confirmingDelete = false }.skButton().keyboardShortcut(.cancelAction)
                    Button("Delete Summary") {
                        confirmingDelete = false
                        Task { await model.deleteMessage(id: message.id) }
                    }
                    .skButton(.destructiveFilled)
                }
            } else {
                HStack(spacing: 10) {
                    let cut = message.isTruncatedOutput
                    SlotHead(systemImage: "wand.and.stars",
                             title: cut ? "Truncated summary awaiting review" : "Compression awaiting review",
                             detail: cut ? "The summary is incomplete. Delete it and compress again; confirming keeps the cut text."
                                         : "Confirm to continue in a fresh context, or delete the summary to carry on here.",
                             tint: SK.orange, detailColor: cut ? SK.red : SK.secondary)
                    Button("Delete Summary") { confirmingDelete = true }
                        .skButton(.destructive)
                        .disabled(promoting)
                    Button {
                        promoting = true
                        Task {
                            await model.promoteCompaction(messageID: message.id)
                            promoting = false
                        }
                    } label: {
                        Text(promoting ? "Confirming…" : "Confirm")
                    }
                    .buttonStyle(SlotOrangeButtonStyle())
                    .disabled(promoting)
                    .help("Confirm the summary, open a fresh context, and continue from there")
                }
            }
        }
    }
}

/// The review card's Confirm: filled in the compression orange.
struct SlotOrangeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .sk(13, .white, weight: .semibold)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xC7782F)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A tool asked for input mid-reply (MCP elicitation). The reply waits.
struct ElicitCard: View {
    let conversationID: String
    let pending: StreamHub.PendingElicit
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var fields: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let schema = ElicitSchema(pending.schemaJSON)
        MKSlotCard(ring: theme.accent.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 0) {
                SlotHead(systemImage: "key", title: "Psmith needs input", detail: pending.message, tint: theme.accentInk)
                if !schema.fields.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(schema.fields, id: \.name) { f in
                            GridRow {
                                Text(f.label).sk(12.5, SK.secondary).frame(width: 110, alignment: .leading)
                                control(f, required: schema.required.contains(f.name))
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                if let error {
                    Text(error).sk(12, SK.red).padding(.top, 8)
                }
                HStack(spacing: 8) {
                    Text("The reply waits until you answer.").sk(11.5, SK.tertiary)
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await submit(.cancel, schema) } }.skButton().disabled(working)
                    Button("Decline") { Task { await submit(.decline, schema) } }.skButton().disabled(working)
                    Button(working ? "Submitting…" : "Submit") { Task { await submit(.accept, schema) } }
                        .skButton(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !schema.requiredFilled(fields))
                }
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func control(_ f: ElicitSchema.Field, required: Bool) -> some View {
        switch f.kind {
        case .boolean:
            Toggle("", isOn: Binding(get: { bools[f.name] ?? false }, set: { bools[f.name] = $0 })).skSwitch()
        case .password, .string, .integer:
            SKTextField(label: f.label,
                        text: Binding(get: { fields[f.name] ?? "" }, set: { fields[f.name] = $0 }),
                        placeholder: required ? "Required" : (f.description ?? ""),
                        width: nil,
                        secure: f.kind == .password)
        }
    }

    private func submit(_ action: PsmithElicitAction, _ schema: ElicitSchema) async {
        working = true
        error = nil
        defer { working = false }
        var content: Data?
        if action == .accept {
            content = schema.payload(fields: fields, bools: bools)
        }
        do {
            try await app.elicitations.respond(conversationID: conversationID, elicitationID: pending.id, action: action, content: content)
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: pending.id)
        } catch PsmithElicitationError.notFound {
            // Already answered or expired: nothing to wait on.
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: pending.id)
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// The JSON Schema subset elicitations use: an object of string,
/// password, boolean and integer properties.
struct ElicitSchema {
    struct Field {
        enum Kind { case string, password, boolean, integer }
        let name: String
        let kind: Kind
        let description: String?
        var label: String { name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
    }

    let fields: [Field]
    let required: Set<String>

    init(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fields = []
            required = []
            return
        }
        let properties = obj["properties"] as? [String: [String: Any]] ?? [:]
        required = Set((obj["required"] as? [String]) ?? [])
        fields = properties.keys.sorted().map { name in
            let prop = properties[name] ?? [:]
            let kind: Field.Kind = switch prop["type"] as? String ?? "string" {
            case "boolean": .boolean
            case "integer", "number": .integer
            default: (prop["format"] as? String) == "password" ? .password : .string
            }
            return Field(name: name, kind: kind, description: prop["description"] as? String)
        }
    }

    func requiredFilled(_ values: [String: String]) -> Bool {
        fields.allSatisfy { f in
            guard required.contains(f.name), f.kind != .boolean else { return true }
            return !(values[f.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func payload(fields values: [String: String], bools: [String: Bool]) -> Data? {
        var payload: [String: Any] = [:]
        for f in fields {
            switch f.kind {
            case .password, .string: payload[f.name] = values[f.name] ?? ""
            case .integer: payload[f.name] = Int(values[f.name] ?? "") ?? 0
            case .boolean: payload[f.name] = bools[f.name] ?? false
            }
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

/// Setting up a compression where the composer was: the prompt, the
/// model, and Compress. The summary streams into the transcript and waits
/// for review before anything changes.
struct CompressCard: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        MKSlotCard(ring: SK.orange.opacity(0.4)) {
            VStack(alignment: .leading, spacing: 0) {
                SlotHead(systemImage: "wand.and.stars", title: "Compress into a new context", detail: summaryLine, tint: SK.orange)
                SKTextArea(text: $model.compactPromptDraft, lines: 3)
                    .padding(.vertical, 10)
                if let err = model.compactError {
                    Text("Last attempt: \(err)").sk(12, SK.red).padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    Text("Model").sk(12.5, SK.secondary)
                    compressionModelMenu
                    Spacer(minLength: 0)
                    Text("Return to compress · Escape to cancel").sk(11.5, SK.tertiary).lineLimit(1)
                    Button("Cancel") { model.showingCompactView = false }
                        .skButton()
                        .keyboardShortcut(.cancelAction)
                    Button("Compress") { compress() }
                        .skButton(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!formValid || model.isCompacting || model.sending)
                }
            }
        }
        .task {
            await app.profiles.loadAvailableModels()
            await model.prepareCompactView()
        }
    }

    private var summaryLine: String {
        let replies = model.messages.filter { $0.role == .assistant }.count
        var s = "\(replies) repl\(replies == 1 ? "y" : "ies")"
        if let n = model.tokenCount { s += ", \(n.formatted()) tokens" }
        return s + ". You review the summary before anything changes."
    }

    private var selected: PsmithUserModel? {
        app.profiles.availableModels.first { $0.providerID == model.compactProviderID && $0.modelID == model.compactModelID }
    }

    private var compressionModelMenu: some View {
        let byProvider = Dictionary(grouping: app.profiles.availableModels, by: \.providerID)
            .map { (label: app.profiles.providerLabels[$0.key] ?? $0.key, models: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.label < $1.label }
        return Menu {
            ForEach(byProvider, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.models, id: \.self) { m in
                        Button {
                            model.compactProviderID = m.providerID
                            model.compactModelID = m.modelID
                        } label: {
                            if m.providerID == model.compactProviderID && m.modelID == model.compactModelID {
                                Label(m.displayName, systemImage: "checkmark")
                            } else {
                                Text(m.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let s = selected { ProviderLogo(slug: app.profiles.providerTypes[s.providerID], size: 16) }
                Text(selected?.displayName ?? "Choose a model").sk(13).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SK.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.controlRing, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var formValid: Bool {
        let trimmed = model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, selected != nil else { return false }
        return true
    }

    private func compress() {
        guard formValid else { return }
        let providerID = model.compactProviderID
        let modelID = model.compactModelID
        let trimmed = model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.showingCompactView = false
        Task { await model.compact(guide: trimmed, providerID: providerID, modelID: modelID) }
    }
}
