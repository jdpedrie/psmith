import SwiftUI
import ReeveKit

/// Renders one row per `ReeveConfigField` against a shared `[String: Any]`
/// config dict. The dict is the source of truth — fields with no entry
/// fall back to the field's `defaultJSON` literal at render time.
///
/// Per-field controls:
/// - `.number`   → TextField with String backing; blank entry means "default"
/// - `.text`     → TextField (single line)
/// - `.textarea` → TextEditor (multi-line, ~80pt min height, bordered)
/// - `.boolean`  → Toggle
/// - `.select`   → Picker(.menu) for >4 options; popover-with-buttons
///                 for ≤4 (matches ConversationListView.sortMenu — SwiftUI
///                 macOS Menu / 2-item Picker is buggy on macOS 26).
public struct PluginConfigForm: View {
    let fields: [ReeveConfigField]
    @Binding var config: [String: Any]
    /// Available user_models for `.modelPicker` fields. Empty when
    /// the host doesn't pass any — in that case the picker
    /// renders a "no models configured" hint instead of an empty
    /// chooser.
    let availableModels: [ReeveUserModel]

    public init(
        fields: [ReeveConfigField],
        config: Binding<[String: Any]>,
        availableModels: [ReeveUserModel] = []
    ) {
        self.fields = fields
        self._config = config
        self.availableModels = availableModels
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(fields) { field in
                fieldRow(field)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ReeveConfigField) -> some View {
        let unsatisfied = field.isUnsatisfied(by: config[field.name])
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.display.isEmpty ? field.name : field.display)
                    .font(.callout.weight(.medium))
                if field.required {
                    Text("*")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(unsatisfied ? .red : .secondary)
                        .help("Required")
                }
            }
            control(for: field)
            if unsatisfied {
                Text("Required.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
            }
            if !field.description.isEmpty {
                Text(field.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func control(for field: ReeveConfigField) -> some View {
        switch field.type {
        case .number:      numberField(field)
        case .text:        textField(field)
        case .textarea:    textareaField(field)
        case .boolean:     booleanField(field)
        case .select:      selectField(field)
        case .modelPicker: modelPickerField(field)
        }
    }

    // MARK: model picker

    private func modelPickerField(_ field: ReeveConfigField) -> some View {
        ModelPickerFieldControl(
            field: field,
            allModels: availableModels,
            current: pickerSelection(for: field),
            onPick: { ref in
                config[field.name] = [
                    "provider_id": ref.providerID,
                    "model_id": ref.modelID,
                ]
            }
        )
    }

    private func pickerSelection(for field: ReeveConfigField) -> (providerID: String, modelID: String)? {
        if let dict = config[field.name] as? [String: Any],
           let pid = dict["provider_id"] as? String,
           let mid = dict["model_id"] as? String,
           !pid.isEmpty, !mid.isEmpty {
            return (pid, mid)
        }
        return nil
    }

    // MARK: number

    private func numberField(_ field: ReeveConfigField) -> some View {
        let binding = Binding<String>(
            get: {
                if let v = config[field.name] {
                    if let d = v as? Double { return formatNumber(d) }
                    if let i = v as? Int    { return String(i) }
                    if let s = v as? String { return s }
                }
                return decodeDefaultString(field) ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    // Clearing reverts to the field's default.
                    config.removeValue(forKey: field.name)
                } else if let d = Double(trimmed) {
                    if d.rounded() == d, abs(d) < Double(Int.max) {
                        config[field.name] = Int(d)
                    } else {
                        config[field.name] = d
                    }
                } else {
                    config[field.name] = trimmed
                }
            }
        )
        return TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
    }

    private func formatNumber(_ d: Double) -> String {
        if d.rounded() == d, abs(d) < Double(Int.max) { return String(Int(d)) }
        return String(d)
    }

    // MARK: text

    private func textField(_ field: ReeveConfigField) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = config[field.name] as? String { return s }
                return decodeDefaultString(field) ?? ""
            },
            set: { newValue in
                config[field.name] = newValue
            }
        )
        return TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: textarea

    private func textareaField(_ field: ReeveConfigField) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = config[field.name] as? String { return s }
                return decodeDefaultString(field) ?? ""
            },
            set: { newValue in
                config[field.name] = newValue
            }
        )
        return TextEditor(text: binding)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 80)
    }

    // MARK: boolean

    private func booleanField(_ field: ReeveConfigField) -> some View {
        let binding = Binding<Bool>(
            get: {
                if let b = config[field.name] as? Bool { return b }
                return decodeDefaultBool(field) ?? false
            },
            set: { config[field.name] = $0 }
        )
        return Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
    }

    // MARK: select

    @ViewBuilder
    private func selectField(_ field: ReeveConfigField) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = config[field.name] as? String { return s }
                return decodeDefaultString(field) ?? (field.options.first?.value ?? "")
            },
            set: { config[field.name] = $0 }
        )
        if field.options.count <= 4 {
            SelectFieldPopover(field: field, selection: binding)
        } else {
            Picker("", selection: binding) {
                ForEach(field.options, id: \.value) { opt in
                    Text(opt.label.isEmpty ? opt.value : opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
        }
    }

    // MARK: defaults decoding

    private func decodeDefaultString(_ field: ReeveConfigField) -> String? {
        guard !field.defaultJSON.isEmpty,
              let data = field.defaultJSON.data(using: .utf8) else { return nil }
        if let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        if let i = try? JSONDecoder().decode(Int.self, from: data)    { return String(i) }
        if let d = try? JSONDecoder().decode(Double.self, from: data) {
            if d.rounded() == d, abs(d) < Double(Int.max) { return String(Int(d)) }
            return String(d)
        }
        if let b = try? JSONDecoder().decode(Bool.self, from: data)   { return String(b) }
        return nil
    }

    private func decodeDefaultBool(_ field: ReeveConfigField) -> Bool? {
        guard !field.defaultJSON.isEmpty,
              let data = field.defaultJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }
}

/// Model-picker control for `.modelPicker` config fields.
/// Surfaces the user_models that satisfy the field's
/// ModelPickerFilter (e.g. only image-generating models for
/// imagegen), grouped by provider for legibility. Stores the
/// chosen `(provider_id, model_id)` pair via the `onPick`
/// callback; the host owns the JSON-shaped storage in the
/// per-plugin config dict.
private struct ModelPickerFieldControl: View {
    let field: ReeveConfigField
    let allModels: [ReeveUserModel]
    let current: (providerID: String, modelID: String)?
    let onPick: ((providerID: String, modelID: String)) -> Void

    @State private var shown = false

    private var matchingModels: [ReeveUserModel] {
        guard let f = field.modelPickerFilter else { return allModels }
        return allModels.filter { m in
            // Each filter flag is "must be true on the model";
            // unset flag = no constraint. Models without
            // capability metadata fall through (treated as "we
            // don't know" → not surfaced when a constraint is on).
            let caps = m.capabilities
            if f.requiresStreaming       && !(caps?.streaming       ?? false) { return false }
            if f.requiresThinking        && !(caps?.thinking        ?? false) { return false }
            if f.requiresToolUse         && !(caps?.toolUse         ?? false) { return false }
            if f.requiresVision          && !(caps?.vision          ?? false) { return false }
            if f.requiresPromptCaching   && !(caps?.promptCaching   ?? false) { return false }
            if f.requiresGeneratesImages && !(caps?.generatesImages ?? false) { return false }
            return true
        }
    }

    private var currentLabel: String {
        if let cur = current,
           let m = allModels.first(where: { $0.providerID == cur.providerID && $0.modelID == cur.modelID }) {
            return m.displayName
        }
        if let cur = current { return cur.modelID }
        return "(choose model)"
    }

    var body: some View {
        let models = matchingModels
        if models.isEmpty {
            Text(emptyHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            Button {
                shown = true
            } label: {
                HStack(spacing: 4) {
                    Text(currentLabel)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                modelList(models)
            }
        }
    }

    @ViewBuilder
    private func modelList(_ models: [ReeveUserModel]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(models) { m in
                    Button {
                        onPick((providerID: m.providerID, modelID: m.modelID))
                        shown = false
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName)
                                    .foregroundStyle(.primary)
                                Text(m.modelID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let cur = current,
                               cur.providerID == m.providerID,
                               cur.modelID == m.modelID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 280, maxHeight: 380)
    }

    private var emptyHint: String {
        if let f = field.modelPickerFilter, f.requiresGeneratesImages {
            return "No image-generating models configured. Add one under Providers (e.g. OpenAI gpt-image-1, Google gemini-2.5-flash-image-preview)."
        }
        return "No models configured. Add one under Providers."
    }
}

/// Popover-with-buttons select. SwiftUI's `Menu` and 2-item `Picker(.menu)`
/// render empty on macOS 26 — see feedback_swiftui_menu_macos_bug.md and
/// ConversationListView.sortMenu for the same shape.
private struct SelectFieldPopover: View {
    let field: ReeveConfigField
    @Binding var selection: String
    @State private var shown = false

    private var currentLabel: String {
        if let opt = field.options.first(where: { $0.value == selection }) {
            return opt.label.isEmpty ? opt.value : opt.label
        }
        return selection.isEmpty ? "(choose)" : selection
    }

    var body: some View {
        Button {
            shown = true
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(field.options, id: \.value) { opt in
                    Button {
                        selection = opt.value
                        shown = false
                    } label: {
                        HStack {
                            Text(opt.label.isEmpty ? opt.value : opt.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if opt.value == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 200)
            .padding(.vertical, 4)
        }
    }
}
