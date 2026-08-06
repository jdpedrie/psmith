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

    /// Which row is expanded. One at a time: rows can carry long text, and a
    /// form with every row open is unreadable past about three entries.
    @State private var expanded: String?

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

            Button {
                addRow()
            } label: {
                Label("Add", systemImage: "plus.circle")
                    .scaledFont(.callout)
            }
            .buttonStyle(.borderless)
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
