import SwiftUI
import SpaltKit

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
    @State private var pasteExpanded: Bool = false
    @State private var pasteText: String = ""
    @State private var pasteError: String?

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

            pasteJSONSection
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

    // MARK: - Paste JSON

    /// Power-user escape hatch — accepts a pasted JSON blob in either of
    /// the two shapes the rest of the system uses (raw `[…]` array, or
    /// `{"components":[…]}` wrapper) and replaces the current definition
    /// list. Useful when seeding from an AI-generated config or copying
    /// between profiles. Validation errors render inline; nothing is
    /// applied until parsing fully succeeds.
    @ViewBuilder
    private var pasteJSONSection: some View {
        DisclosureGroup(isExpanded: $pasteExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste a JSON array of definitions, or a `{\"components\": [...]}` wrapper. Replaces the entire list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $pasteText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                if let err = pasteError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Replace from JSON") { applyPaste() }
                        .buttonStyle(.glassProminent)
                        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Load current") { loadCurrentIntoPaste() }
                        .buttonStyle(.glass)
                    Spacer()
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Paste JSON")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func applyPaste() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            pasteError = "Could not encode as UTF-8."
            return
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            pasteError = "JSON parse error: \(error.localizedDescription)"
            return
        }
        let arr: [[String: Any]]?
        if let direct = parsed as? [[String: Any]] {
            arr = direct
        } else if let wrapper = parsed as? [String: Any], let nested = wrapper["components"] as? [[String: Any]] {
            arr = nested
        } else {
            arr = nil
        }
        guard let entries = arr else {
            pasteError = "Expected an array of definitions or a {\"components\": [...]} wrapper."
            return
        }
        let decoded = entries.compactMap(Definition.init(dict:))
        guard decoded.count == entries.count else {
            pasteError = "One or more entries failed to decode."
            return
        }
        definitions = decoded
        pasteError = nil
        pasteText = ""
        pasteExpanded = false
        persist()
    }

    private func loadCurrentIntoPaste() {
        let wrapper: [String: Any] = ["components": definitions.map { $0.toDict() }]
        guard let data = try? JSONSerialization.data(
            withJSONObject: wrapper,
            options: [.prettyPrinted, .sortedKeys]
        ),
        let str = String(data: data, encoding: .utf8) else {
            return
        }
        pasteText = str
        pasteError = nil
    }
}

// MARK: - Definition row

/// One component-definition row's editable state. Mirrors the
/// server-side `componentDef` struct; field names match so
/// (de)serialisation is mechanical.
struct Definition: Identifiable, Hashable, Codable {
    let id: UUID
    /// Per-definition identifier. Referenced by the system
    /// reminder ("Always generate the {name} component.") and
    /// disambiguates two definitions sharing the same Component.
    var name: String
    var component: String
    var openTag: String
    var closeTag: String
    var position: String
    var instructions: String
    /// Three-state reminder mode. "none" / "always" /
    /// "when_appropriate". The actual reminder text is derived
    /// from the mode + name on the server side; this form just
    /// chooses which mode applies.
    var reminderMode: String

    enum CodingKeys: String, CodingKey {
        case name
        case component
        case openTag = "open_tag"
        case closeTag = "close_tag"
        case position
        case instructions
        case reminderMode = "reminder_mode"
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        component: String = "choice_list",
        openTag: String = "<choices>",
        closeTag: String = "</choices>",
        position: String = "end",
        instructions: String = "",
        reminderMode: String = "none"
    ) {
        self.id = id
        self.name = name
        self.component = component
        self.openTag = openTag
        self.closeTag = closeTag
        self.position = position
        self.instructions = instructions
        self.reminderMode = reminderMode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()  // not persisted; freshly minted on every load
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.component = (try? c.decode(String.self, forKey: .component)) ?? ""
        self.openTag = (try? c.decode(String.self, forKey: .openTag)) ?? ""
        self.closeTag = (try? c.decode(String.self, forKey: .closeTag)) ?? ""
        self.position = (try? c.decode(String.self, forKey: .position)) ?? "anywhere"
        self.instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        self.reminderMode = (try? c.decode(String.self, forKey: .reminderMode)) ?? "none"
    }

    init?(dict: [String: Any]) {
        self.id = UUID()
        self.name = dict["name"] as? String ?? ""
        self.component = dict["component"] as? String ?? ""
        self.openTag = dict["open_tag"] as? String ?? ""
        self.closeTag = dict["close_tag"] as? String ?? ""
        self.position = dict["position"] as? String ?? "anywhere"
        self.instructions = dict["instructions"] as? String ?? ""
        self.reminderMode = dict["reminder_mode"] as? String ?? "none"
    }

    func toDict() -> [String: Any] {
        [
            "name": name,
            "component": component,
            "open_tag": openTag,
            "close_tag": closeTag,
            "position": position,
            "instructions": instructions,
            "reminder_mode": reminderMode,
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
    static let reminderModes: [(value: String, label: String)] = [
        ("none", "No reminder"),
        ("when_appropriate", "Generate when appropriate"),
        ("always", "Always generate"),
    ]
}

private struct DefinitionEditor: View {
    @Binding var definition: Definition
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            nameRow
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
            Text(definition.name.isEmpty ? "(unnamed)" : definition.name)
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

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.caption.weight(.medium))
            TextField("e.g. combat_choices", text: $definition.name)
                .textFieldStyle(.roundedBorder)
            Text("Identifier the system message + reminders reference. Must be unique within this plugin instance.")
                .font(.caption2).foregroundStyle(.tertiary)
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
            Text("Per-turn user reminder").font(.caption.weight(.medium))
            Picker("", selection: $definition.reminderMode) {
                ForEach(Definition.reminderModes, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Wraps a [system_reminder] tail onto the most-recent user message (not persisted) — re-grounds the convention every turn. The reminder text is auto-generated from the component name.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
