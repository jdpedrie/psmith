import SwiftUI
import ReeveKit

/// Custom config form for the `component_builder` plugin. Edits
/// a structured list of definitions instead of a JSON textarea.
///
/// Persisted shape (in the plugin's config blob):
/// ```json
/// {
///   "components": [
///     {
///       "component": "choice_list",
///       "open_tag": "<choices>",
///       "close_tag": "</choices>",
///       "position": "end",
///       "instructions": "…",
///       "user_reminder_enabled": true,
///       "user_reminder": "…"
///     }
///   ]
/// }
/// ```
///
/// The editor reads + writes that shape directly through the
/// shared `[String: Any]` config binding. Each row is a card
/// with the typed fields; "Add definition" appends; trash
/// removes; reorder is a future polish item.
public struct ComponentBuilderConfigForm: View {
    @Binding var config: [String: Any]
    /// Local mirror of the parsed definitions list. The form
    /// edits this in-place; `save` happens on every mutation
    /// (writes through to `config["components"]` as JSON-
    /// serialisable data so the host's save flow round-trips
    /// cleanly).
    @State private var definitions: [Definition] = []

    public init(config: Binding<[String: Any]>) {
        self._config = config
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach($definitions) { $def in
                DefinitionEditor(definition: $def, onRemove: {
                    if let idx = definitions.firstIndex(where: { $0.id == def.id }) {
                        definitions.remove(at: idx)
                        persist()
                    }
                })
            }
            Button {
                definitions.append(Definition.fresh())
                persist()
            } label: {
                Label("Add component definition", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.glass)
        }
        .onAppear { load() }
        .onChange(of: definitions) { _, _ in persist() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Component definitions")
                .font(.callout.weight(.semibold))
            Text("Each definition teaches the model to wrap structured output in your tags. The Content Renderer pipeline parses the tags + emits a UIFragment the client renders natively.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Persistence

    /// Decode the current `config["components"]` blob into the
    /// local `definitions` array. Tolerant of missing/malformed
    /// data — falls back to an empty list rather than throwing
    /// so the form always renders.
    private func load() {
        guard let raw = config["components"] else { return }
        // Two shapes possible at load: the runtime data
        // structure (`[[String: Any]]`) when the host already
        // unmarshalled into `Any`, or a raw JSON string when
        // a previous save round-tripped via JSON.
        if let arr = raw as? [[String: Any]] {
            definitions = arr.compactMap(Definition.init(dict:))
            return
        }
        if let str = raw as? String, let data = str.data(using: .utf8) {
            if let decoded = try? JSONDecoder().decode([Definition].self, from: data) {
                definitions = decoded
            }
        }
    }

    /// Re-encode the in-memory definitions into the
    /// `[[String: Any]]` shape JSONSerialization writes cleanly.
    /// Empty list clears the key entirely so the saved blob stays
    /// `{}` rather than `{"components":[]}`.
    private func persist() {
        if definitions.isEmpty {
            config.removeValue(forKey: "components")
            return
        }
        config["components"] = definitions.map { $0.toDict() }
    }
}

// MARK: - Definition row

/// One component-definition row's editable state. Mirrors the
/// server-side `componentDef` struct; field names match so
/// (de)serialisation is mechanical.
struct Definition: Identifiable, Hashable, Codable {
    let id: UUID
    var component: String
    var openTag: String
    var closeTag: String
    var position: String
    var instructions: String
    var userReminderEnabled: Bool
    var userReminder: String

    enum CodingKeys: String, CodingKey {
        case component
        case openTag = "open_tag"
        case closeTag = "close_tag"
        case position
        case instructions
        case userReminderEnabled = "user_reminder_enabled"
        case userReminder = "user_reminder"
    }

    init(
        id: UUID = UUID(),
        component: String = "choice_list",
        openTag: String = "<choices>",
        closeTag: String = "</choices>",
        position: String = "end",
        instructions: String = "",
        userReminderEnabled: Bool = false,
        userReminder: String = ""
    ) {
        self.id = id
        self.component = component
        self.openTag = openTag
        self.closeTag = closeTag
        self.position = position
        self.instructions = instructions
        self.userReminderEnabled = userReminderEnabled
        self.userReminder = userReminder
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()  // not persisted; freshly minted on every load
        self.component = (try? c.decode(String.self, forKey: .component)) ?? ""
        self.openTag = (try? c.decode(String.self, forKey: .openTag)) ?? ""
        self.closeTag = (try? c.decode(String.self, forKey: .closeTag)) ?? ""
        self.position = (try? c.decode(String.self, forKey: .position)) ?? "anywhere"
        self.instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        self.userReminderEnabled = (try? c.decode(Bool.self, forKey: .userReminderEnabled)) ?? false
        self.userReminder = (try? c.decode(String.self, forKey: .userReminder)) ?? ""
    }

    init?(dict: [String: Any]) {
        self.id = UUID()
        self.component = dict["component"] as? String ?? ""
        self.openTag = dict["open_tag"] as? String ?? ""
        self.closeTag = dict["close_tag"] as? String ?? ""
        self.position = dict["position"] as? String ?? "anywhere"
        self.instructions = dict["instructions"] as? String ?? ""
        self.userReminderEnabled = dict["user_reminder_enabled"] as? Bool ?? false
        self.userReminder = dict["user_reminder"] as? String ?? ""
    }

    func toDict() -> [String: Any] {
        [
            "component": component,
            "open_tag": openTag,
            "close_tag": closeTag,
            "position": position,
            "instructions": instructions,
            "user_reminder_enabled": userReminderEnabled,
            "user_reminder": userReminder,
        ]
    }

    static func fresh() -> Definition {
        Definition()
    }

    /// Components the shipped renderers know how to display.
    /// Picker shows these by name; users can type any string —
    /// unknown components fall back to UnknownComponentRenderer.
    static let knownComponents: [String] = [
        "card_list", "choice_list", "key_value", "image", "image_grid", "error", "raw_json",
    ]

    static let positions: [String] = ["start", "end", "anywhere"]
}

private struct DefinitionEditor: View {
    @Binding var definition: Definition
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            componentRow
            tagRow
            positionRow
            instructionsRow
            reminderRow
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack {
            Text(definition.component.isEmpty ? "(unnamed)" : definition.component)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this definition")
        }
    }

    private var componentRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Component").font(.caption.weight(.medium))
            HStack(spacing: 6) {
                TextField("component_name", text: $definition.component)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $definition.component) {
                    ForEach(Definition.knownComponents, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Text("A name from the shipped renderer set, or any custom string (custom names render via the unknown-component fallback).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open tag").font(.caption.weight(.medium))
                TextField("<choices>", text: $definition.openTag)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Close tag").font(.caption.weight(.medium))
                TextField("</choices>", text: $definition.closeTag)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var positionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Position hint").font(.caption.weight(.medium))
            Picker("", selection: $definition.position) {
                ForEach(Definition.positions, id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Hint for the system instructions only — the parser doesn't enforce position.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var instructionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Instructions").font(.caption.weight(.medium))
            TextEditor(text: $definition.instructions)
                .font(.callout.monospaced())
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            Text("Free-form system-message snippet teaching the model when + how to use this component (the body shape it should emit, when to choose it).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Per-turn user reminder", isOn: $definition.userReminderEnabled)
                .font(.caption.weight(.medium))
            if definition.userReminderEnabled {
                TextEditor(text: $definition.userReminder)
                    .font(.callout)
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                Text("Riden on the most-recent user message every turn (not persisted) wrapped in [system_reminder ...]. Empty = generic 'use the {component} component when appropriate.'")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
