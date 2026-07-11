import SwiftUI
import PsmithKit

/// Modal form for an in-flight MCP elicitation request. Presented from
/// the conversation surface when `streamHub.activeStream.pendingElicitations`
/// is non-empty. Submits to `ElicitationsRepository.respond(...)` and
/// dismisses on success (or surfaces an error inline on failure).
///
/// Schema handling is intentionally narrow for v1:
///   - object with one or more string / boolean / integer properties
///   - string properties with `"format": "password"` render as SecureField
///   - everything else falls back to a plain TextField
///
/// Cancelling sends `action: "cancel"`. Declining sends
/// `action: "decline"`. Both let the server's tool branch on user
/// intent (e.g. a refused secret can return a helpful tool result
/// to the LLM instead of timing out silently).
public struct ElicitSheet: View {
    public let conversationID: String
    public let pending: StreamHub.PendingElicit
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var fields: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var working = false
    @State private var error: String?

    public init(conversationID: String, pending: StreamHub.PendingElicit) {
        self.conversationID = conversationID
        self.pending = pending
    }

    public var body: some View {
        let schema = parseSchema(pending.schemaJSON)
        return VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 12) {
                ForEach(schema.fields, id: \.name) { field in
                    fieldView(for: field, required: schema.required.contains(field.name))
                }
            }
            if let error {
                Text(error)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer(schema: schema)
        }
        .padding(20)
        .frame(maxWidth: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                Text("Psmith needs input")
                    .scaledFont(.headline)
            }
            Text(pending.message)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldView(for field: SchemaField, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.displayLabel)
                    .scaledFont(.caption, weight: .medium)
                if required {
                    Text("required")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            switch field.kind {
            case .password:
                SecureField(field.placeholder, text: binding(for: field.name))
                    .textFieldStyle(.roundedBorder)
            case .string:
                TextField(field.placeholder, text: binding(for: field.name))
                    .textFieldStyle(.roundedBorder)
            case .boolean:
                Toggle("", isOn: boolBinding(for: field.name))
                    .toggleStyle(.switch)
                    .labelsHidden()
            case .integer:
                TextField(field.placeholder, text: binding(for: field.name))
                    .textFieldStyle(.roundedBorder)
            }
            if let desc = field.description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(schema: Schema) -> some View {
        HStack(spacing: 8) {
            Button("Cancel") { Task { await submit(.cancel, schema: schema) } }
                .buttonStyle(.bordered)
                .disabled(working)
            Button("Decline") { Task { await submit(.decline, schema: schema) } }
                .buttonStyle(.bordered)
                .disabled(working)
            Spacer()
            Button {
                Task { await submit(.accept, schema: schema) }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Submit").fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || !requiredsFilled(schema: schema))
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { fields[name] ?? "" },
            set: { fields[name] = $0 }
        )
    }
    private func boolBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { bools[name] ?? false },
            set: { bools[name] = $0 }
        )
    }

    private func requiredsFilled(schema: Schema) -> Bool {
        for name in schema.required {
            if let f = schema.fields.first(where: { $0.name == name }) {
                switch f.kind {
                case .password, .string, .integer:
                    if (fields[name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                        return false
                    }
                case .boolean:
                    break // booleans are always set (default false)
                }
            }
        }
        return true
    }

    private func submit(_ action: PsmithElicitAction, schema: Schema) async {
        working = true
        error = nil
        defer { working = false }

        var content: Data?
        if action == .accept {
            var payload: [String: Any] = [:]
            for f in schema.fields {
                switch f.kind {
                case .password, .string:
                    payload[f.name] = fields[f.name] ?? ""
                case .integer:
                    payload[f.name] = Int(fields[f.name] ?? "") ?? 0
                case .boolean:
                    payload[f.name] = bools[f.name] ?? false
                }
            }
            content = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }

        do {
            try await app.elicitations.respond(
                conversationID: conversationID,
                elicitationID: pending.id,
                action: action,
                content: content
            )
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: pending.id)
            dismiss()
        } catch PsmithElicitationError.notFound {
            // Already drained server-side (timeout or cancelled). Clear
            // local state and dismiss so the user isn't stuck on a
            // dead form.
            app.streamHub.clearPendingElicitation(conversationID: conversationID, elicitationID: pending.id)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - Schema parsing

    private struct Schema {
        let fields: [SchemaField]
        let required: Set<String>
    }
    private struct SchemaField {
        let name: String
        let kind: Kind
        let description: String?
        let placeholder: String

        enum Kind { case string, password, boolean, integer }
        var displayLabel: String {
            // Snake-case → Title Case.
            name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    private func parseSchema(_ data: Data) -> Schema {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Schema(fields: [], required: [])
        }
        let properties = obj["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set((obj["required"] as? [String]) ?? [])
        var fields: [SchemaField] = []
        // Iterate `properties` in a stable order — JSON Schema doesn't
        // guarantee key order, but a sorted render keeps tests + UX
        // consistent across runs.
        for name in properties.keys.sorted() {
            let prop = properties[name] ?? [:]
            let type = prop["type"] as? String ?? "string"
            let format = prop["format"] as? String
            let description = prop["description"] as? String
            let placeholder = description ?? ""
            let kind: SchemaField.Kind
            switch type {
            case "string":  kind = (format == "password") ? .password : .string
            case "boolean": kind = .boolean
            case "integer", "number": kind = .integer
            default:        kind = .string
            }
            fields.append(SchemaField(name: name, kind: kind, description: description, placeholder: placeholder))
        }
        return Schema(fields: fields, required: required)
    }
}
