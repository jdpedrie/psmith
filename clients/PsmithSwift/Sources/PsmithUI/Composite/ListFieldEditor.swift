import PsmithKit
import SwiftUI

/// Editor for a `.list` config field: a repeating group of records.
///
/// Generic on purpose. It knows nothing about any plugin — it reads the
/// element schema off the field and renders each property with the same
/// controls the flat form uses. A plugin that needs a list of things declares
/// one, and every client gets an editor for it without shipping a form.
///
/// This is what the field vocabulary existed to avoid: before it, "a list of
/// records" could only be expressed as a textarea of raw JSON, which is a
/// hostile thing to hand a user and pushes plugins toward bespoke editors that
/// every client then has to compile in.
struct ListFieldEditor: View {
    let field: PsmithConfigField
    @Binding var config: [String: Any]
    /// Profiles offered by `.profilePicker` item fields, as (id, name).
    /// Empty degrades to a text field: a raw uuid the user can still edit
    /// beats a chooser with nothing in it.
    var availableProfiles: [(id: String, name: String)] = []

    /// Which row is expanded. One at a time: rows can carry long text, and a
    /// form with every row open is unreadable past about three entries.
    @State private var expanded: String?
    @State private var showingPaste = false
    @State private var pasteText = ""
    @State private var pasteError: String?

    private var rows: [[String: Any]] {
        (config[field.name] as? [[String: Any]]) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("None yet.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                rowView(index: index, row: row)
            }

            HStack(spacing: 16) {
                Button {
                    addRow()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .scaledFont(.callout)
                }
                .buttonStyle(.borderless)

                Button {
                    showingPaste.toggle()
                    pasteError = nil
                } label: {
                    Label("Paste JSON", systemImage: "doc.on.clipboard")
                        .scaledFont(.callout)
                }
                .buttonStyle(.borderless)
            }

            if showingPaste {
                pasteBox
            }
        }
    }

    /// Bulk-replace escape hatch.
    ///
    /// Kept generic rather than per-plugin: seeding a list from a
    /// model-generated config, or copying one between profiles, is plausible
    /// for any list field, and hand-editing twenty rows through a form is not
    /// something to force on someone who already has the JSON.
    @ViewBuilder
    private var pasteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste a JSON array of rows. Replaces everything above.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteText)
                .frame(minHeight: 100)
                .scaledFont(.caption)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
            if let pasteError {
                Text(pasteError)
                    .scaledFont(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Apply") { applyPaste() }
                    .buttonStyle(.borderless)
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    showingPaste = false
                    pasteText = ""
                    pasteError = nil
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Accepts a bare array or a `{"<field>": [...]}` wrapper, since both
    /// shapes circulate: the first is what someone copies out of a config
    /// blob, the second is what they copy out of a whole plugin config.
    /// Nothing is applied unless parsing fully succeeds.
    private func applyPaste() {
        guard let data = pasteText.data(using: .utf8) else {
            pasteError = "Could not read that text."
            return
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            var array: [[String: Any]]
            if let direct = parsed as? [[String: Any]] {
                array = direct
            } else if let wrapper = parsed as? [String: Any],
                      let inner = wrapper[field.name] as? [[String: Any]] {
                array = inner
            } else {
                pasteError = "Expected a JSON array of objects."
                return
            }
            // Backfill identity for rows that arrived without one, so pasted
            // content is indistinguishable from content added through the form.
            if let idField = field.itemFields.first(where: { $0.type == .autoID }) {
                for i in array.indices {
                    if (array[i][idField.name] as? String)?.isEmpty ?? true {
                        array[i][idField.name] = UUID().uuidString
                    }
                }
            }
            config[field.name] = array
            showingPaste = false
            pasteText = ""
            pasteError = nil
        } catch {
            pasteError = "Not valid JSON: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func rowView(index: Int, row: [String: Any]) -> some View {
        let key = rowKey(row, index: index)
        let isOpen = expanded == key

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    expanded = isOpen ? nil : key
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(summary(row))
                            .scaledFont(.callout, weight: .medium)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    removeRow(at: index)
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(summary(row))")
            }

            if isOpen {
                // Editable properties only. An auto id is machine state the
                // user has no way to reason about, so it is filled on create
                // and never surfaced.
                ForEach(field.itemFields.filter { $0.type != .autoID }, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.display.isEmpty ? item.name : item.display)
                            .scaledFont(.caption, weight: .medium)
                        itemControl(item, index: index)
                        if !item.description.isEmpty {
                            Text(item.description)
                                .scaledFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func itemControl(_ item: PsmithConfigField, index: Int) -> some View {
        switch item.type {
        case .textarea:
            TextEditor(text: stringBinding(item, index: index))
                .frame(minHeight: 90)
                .scaledFont(.callout)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                )
        case .boolean:
            Toggle("", isOn: boolBinding(item, index: index))
                .labelsHidden()
        case .select:
            Picker("", selection: stringBinding(item, index: index)) {
                ForEach(item.options, id: \.value) { option in
                    Text(option.label.isEmpty ? option.value : option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .profilePicker where !availableProfiles.isEmpty:
            Picker("", selection: stringBinding(item, index: index)) {
                Text("Choose a profile").tag("")
                ForEach(availableProfiles, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        default:
            // text, number, select and anything a newer server sends all edit
            // as text. Losing a purpose-built control is better than losing
            // the ability to edit the value at all.
            TextField("", text: stringBinding(item, index: index))
                .textFieldStyle(.roundedBorder)
                .scaledFont(.callout)
        }
    }

    // MARK: - Row identity and display

    /// A stable key for `ForEach` and the expansion state.
    ///
    /// Prefers the auto id, so expanding a row survives edits to its visible
    /// fields. Falls back to the index for rows written before the schema had
    /// one.
    private func rowKey(_ row: [String: Any], index: Int) -> String {
        if let idField = field.itemFields.first(where: { $0.type == .autoID }),
           let id = row[idField.name] as? String, !id.isEmpty {
            return id
        }
        return "index-\(index)"
    }

    /// First non-empty visible text value, so a collapsed row is recognisable.
    private func summary(_ row: [String: Any]) -> String {
        for item in field.itemFields where item.type != .autoID {
            if let v = row[item.name] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return v
            }
        }
        return "Untitled"
    }

    // MARK: - Mutation

    private func addRow() {
        var row: [String: Any] = [:]
        for item in field.itemFields {
            switch item.type {
            case .autoID:
                // Filled once, here. The plugin keys state to it, so it has to
                // outlive renames and reordering.
                row[item.name] = UUID().uuidString
            case .boolean:
                row[item.name] = false
            default:
                row[item.name] = ""
            }
        }
        var next = rows
        next.append(row)
        config[field.name] = next
        expanded = rowKey(row, index: next.count - 1)
    }

    private func removeRow(at index: Int) {
        var next = rows
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        config[field.name] = next
    }

    private func stringBinding(_ item: PsmithConfigField, index: Int) -> Binding<String> {
        Binding(
            get: {
                guard rows.indices.contains(index) else { return "" }
                if let s = rows[index][item.name] as? String { return s }
                if let n = rows[index][item.name] as? Int { return String(n) }
                if let d = rows[index][item.name] as? Double { return String(d) }
                return ""
            },
            set: { newValue in
                var next = rows
                guard next.indices.contains(index) else { return }
                next[index][item.name] = newValue
                config[field.name] = next
            }
        )
    }

    private func boolBinding(_ item: PsmithConfigField, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard rows.indices.contains(index) else { return false }
                return rows[index][item.name] as? Bool ?? false
            },
            set: { newValue in
                var next = rows
                guard next.indices.contains(index) else { return }
                next[index][item.name] = newValue
                config[field.name] = next
            }
        )
    }
}
