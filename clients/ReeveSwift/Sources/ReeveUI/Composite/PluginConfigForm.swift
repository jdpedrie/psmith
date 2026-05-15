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
    /// Provider metadata the shared `ModelPickerList` needs to
    /// render section headers + provider logos. Mirrors what
    /// `ConversationViewModel` holds — pass them through unchanged
    /// from the host. Optional: empty dicts produce a list with
    /// fallback labels and no logos.
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]

    public init(
        fields: [ReeveConfigField],
        config: Binding<[String: Any]>,
        availableModels: [ReeveUserModel] = [],
        providerLabels: [String: String] = [:],
        providerTypes: [String: String] = [:],
        providerPresetIDs: [String: String] = [:]
    ) {
        self.fields = fields
        self._config = config
        self.availableModels = availableModels
        self.providerLabels = providerLabels
        self.providerTypes = providerTypes
        self.providerPresetIDs = providerPresetIDs
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
            providerLabels: providerLabels,
            providerTypes: providerTypes,
            providerPresetIDs: providerPresetIDs,
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
/// Trigger button + sheet wrapping the shared `ModelPickerList` —
/// the same chooser the conversation composer uses, just filtered
/// by the field's `ModelPickerFilter`. Tapping a row commits the
/// `(provider_id, model_id)` selection to the host's config dict
/// via `onPick` and dismisses the sheet.
private struct ModelPickerFieldControl: View {
    let field: ReeveConfigField
    let allModels: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]
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
            .sheet(isPresented: $shown) {
                ModelPickerSheetContent(
                    models: models,
                    providerLabels: providerLabels,
                    providerTypes: providerTypes,
                    providerPresetIDs: providerPresetIDs,
                    current: current,
                    onPick: { providerID, modelID in
                        onPick((providerID: providerID, modelID: modelID))
                        shown = false
                    },
                    onDismiss: { shown = false }
                )
            }
        }
    }

    private var emptyHint: String {
        if let f = field.modelPickerFilter, f.requiresGeneratesImages {
            return "No image-generating models configured. Add one under Providers (e.g. OpenAI gpt-image-1, Google gemini-2.5-flash-image-preview)."
        }
        return "No models configured. Add one under Providers."
    }
}

/// Sheet content wrapping the shared `ModelPickerList` — same
/// look + behavior as the conversation composer's
/// `ModelPickerSheet`, but parameterised by an injected
/// pre-filtered model list and a host-owned commit callback.
private struct ModelPickerSheetContent: View {
    let models: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]
    let current: (providerID: String, modelID: String)?
    let onPick: (_ providerID: String, _ modelID: String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !models.isEmpty {
                        Text("\(models.count) model\(models.count == 1 ? "" : "s") across \(providerCount) provider\(providerCount == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                    }
                    ModelPickerList(
                        models: models,
                        providerLabels: providerLabels,
                        providerTypes: providerTypes,
                        providerPresetIDs: providerPresetIDs,
                        selectedProviderID: current?.providerID,
                        selectedModelID: current?.modelID,
                        onSelect: onPick
                    )
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            #if os(iOS)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            #else
            .navigationTitle("Model")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var providerCount: Int {
        Set(models.map(\.providerID)).count
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
