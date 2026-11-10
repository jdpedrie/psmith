import SwiftUI
import PsmithKit
import PsmithUI

/// A chosen model as a button: logo, name, a chevron that flips while
/// its list is open (boards "Profiles · Model tab", "Automation").
struct SKModelChip: View {
    let name: String
    var logo: String?
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let logo { ProviderLogo(slug: logo, size: 16) }
                Text(name).sk(13).lineLimit(1)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SK.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.controlRing, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(name)")
    }
}

/// The models a choice can land on, grouped by provider, opened inline
/// under the row that chose it. The first row clears the choice.
struct SKModelPickerList: View {
    let models: [PsmithUserModel]
    let providerLabels: [String: String]
    let providerLogos: [String: String]
    let selectedProviderID: String?
    let selectedModelID: String?
    /// "Inherit: Claude Opus 4.7 from Coding", or nil to offer no clear row.
    let inheritLabel: String?
    var requires: PsmithModelPickerFilter?
    let pick: (String?, String?) -> Void
    @State private var filter = ""

    private var groups: [(String, [PsmithUserModel])] {
        let q = filter.lowercased()
        let shown = models.filter { q.isEmpty || $0.displayName.lowercased().contains(q) || $0.modelID.lowercased().contains(q) }
        return Dictionary(grouping: shown, by: \.providerID)
            .map { ($0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { (providerLabels[$0.0] ?? $0.0) < (providerLabels[$1.0] ?? $1.0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKSearchField(placeholder: "Filter models", text: $filter)
                .padding(.top, 8).padding(.bottom, 2)
            if let inheritLabel {
                Button { pick(nil, nil) } label: {
                    HStack(spacing: 8) {
                        Group {
                            if selectedModelID == nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) } else { Color.clear }
                        }
                        .frame(width: 14)
                        Text(inheritLabel).sk(12.5, SK.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if models.isEmpty {
                Text("No models are on yet. Turn some on in Models.").sk(12.5, SK.secondary).padding(10)
            }
            ForEach(groups, id: \.0) { providerID, ms in
                HStack(spacing: 7) {
                    ProviderLogo(slug: providerLogos[providerID], size: 16)
                    Text(providerLabels[providerID] ?? providerID).sk(11, SK.tertiary, weight: .semibold)
                }
                .padding(.top, 8).padding(.bottom, 3).padding(.horizontal, 10)
                ForEach(ms, id: \.modelID) { m in
                    row(m, providerID: providerID)
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SK.line, lineWidth: 1))
        .padding(.top, 9)
    }

    private func missing(_ m: PsmithUserModel) -> [String] {
        guard let r = requires, let c = m.capabilities else { return [] }
        var out: [String] = []
        if r.requiresToolUse && !c.toolUse { out.append("tools") }
        if r.requiresVision && !c.vision { out.append("vision") }
        if r.requiresThinking && !c.thinking { out.append("thinking") }
        if r.requiresGeneratesImages && !c.generatesImages { out.append("image output") }
        return out
    }

    private func row(_ m: PsmithUserModel, providerID: String) -> some View {
        let on = m.modelID == selectedModelID && providerID == selectedProviderID
        let lacks = missing(m)
        return Button { pick(providerID, m.modelID) } label: {
            HStack(spacing: 8) {
                Group {
                    if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } else { Color.clear }
                }
                .frame(width: 14)
                Text(m.displayName).sk(12.5, on ? .white : SK.text, weight: .semibold).lineLimit(1)
                Spacer(minLength: 8)
                Text(lacks.isEmpty ? Self.meta(m) : "Needs \(lacks.joined(separator: ", "))")
                    .sk(11.5, on ? Color.white.opacity(0.75) : (lacks.isEmpty ? SK.tertiary : SK.orange))
                    .lineLimit(1)
            }
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? SK.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lacks.isEmpty)
    }

    /// "200K · $15 / $75 · think · see · tools"
    static func meta(_ m: PsmithUserModel) -> String {
        var parts: [String] = []
        if let c = m.contextWindow { parts.append(c >= 1_000_000 ? "\(c / 1_000_000)M" : "\(c / 1_000)K") }
        if let p = m.pricing, p.inputPerMillion != nil || p.outputPerMillion != nil {
            func d(_ v: Double?) -> String { guard let v else { return "—" }; return v == v.rounded() ? "$\(Int(v))" : String(format: "$%.2f", v) }
            parts.append("\(d(p.inputPerMillion)) / \(d(p.outputPerMillion))")
        }
        if let c = m.capabilities {
            var w: [String] = []
            if c.thinking { w.append("think") }
            if c.vision { w.append("see") }
            if c.toolUse { w.append("tools") }
            if !w.isEmpty { parts.append(w.joined(separator: " · ")) }
        }
        return parts.joined(separator: " · ")
    }
}

/// A row that chooses a model: label, chip, and the list opening under it.
struct SKModelRow: View {
    let title: String
    var detail: String?
    let models: [PsmithUserModel]
    let providerLabels: [String: String]
    let providerLogos: [String: String]
    let providerID: String?
    let modelID: String?
    let inheritLabel: String?
    var unsetName = "Inherit"
    var requires: PsmithModelPickerFilter?
    @Binding var openRow: String?
    let pick: (String?, String?) -> Void

    private var open: Bool { openRow == title }

    var body: some View {
        SKRawRow(vertical: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SKLabel(title: title, detail: detail)
                    let name = models.first { $0.modelID == modelID && $0.providerID == providerID }?.displayName ?? modelID ?? unsetName
                    SKModelChip(name: name, logo: providerID.flatMap { providerLogos[$0] }, open: open) {
                        withAnimation(.easeOut(duration: 0.15)) { openRow = open ? nil : title }
                    }
                }
                if open {
                    SKModelPickerList(models: models, providerLabels: providerLabels, providerLogos: providerLogos,
                                      selectedProviderID: providerID, selectedModelID: modelID,
                                      inheritLabel: inheritLabel, requires: requires) { p, m in
                        pick(p, m)
                        withAnimation(.easeOut(duration: 0.15)) { openRow = nil }
                    }
                }
            }
        }
    }
}

// MARK: - Plugin config fields

/// A plugin's settings, drawn in the boards' rows: grouped by category,
/// list fields in their own group, menus for selects, models inline.
struct SKPluginFields: View {
    let fields: [PsmithConfigField]
    @Binding var values: [String: Any]
    var models: [PsmithUserModel] = []
    var providerLabels: [String: String] = [:]
    var providerLogos: [String: String] = [:]
    var profiles: [PsmithProfile] = []
    /// The group uncategorized fields go in.
    var mainTitle = "Settings"
    var trailing: AnyView?
    @State private var openRow: String?

    private var visible: [PsmithConfigField] { fields.filter { $0.type != .autoID } }

    private var sections: [(String, [PsmithConfigField])] {
        var order: [String] = []
        var byCat: [String: [PsmithConfigField]] = [:]
        for f in visible where f.type != .list {
            let c = f.category.isEmpty ? mainTitle : f.category
            if byCat[c] == nil { order.append(c) }
            byCat[c, default: []].append(f)
        }
        return order.map { ($0, byCat[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                SKGroup(section.0) {
                    ForEach(section.1) { field($0) }
                } trailing: {
                    if i == 0, let trailing { trailing }
                }
            }
            ForEach(visible.filter { $0.type == .list }) { f in
                SKListFieldGroup(field: f, rows: Binding(
                    get: { values[f.name] as? [[String: Any]] ?? [] },
                    set: { values[f.name] = $0 }
                ))
            }
        }
    }

    private func detail(_ f: PsmithConfigField) -> String? {
        var d = f.description
        if f.merge == .appendString { d += (d.isEmpty ? "" : " ") + "Adds to the parent's instead of replacing it." }
        return d.isEmpty ? nil : d
    }

    private func required(_ f: PsmithConfigField) -> some View {
        Group {
            if f.required, f.isUnsatisfied(by: values[f.name]) {
                SKChip(text: "Required", color: SK.orange, fill: SK.orange.opacity(0.14))
            }
        }
    }

    private func string(_ f: PsmithConfigField) -> Binding<String> {
        Binding(
            get: {
                if let s = values[f.name] as? String { return s }
                if let n = values[f.name] as? NSNumber { return n.stringValue }
                return ""
            },
            set: { values[f.name] = $0.isEmpty ? nil : $0 }
        )
    }

    private func defaultValue(_ f: PsmithConfigField) -> Any? {
        guard let d = f.defaultJSON.data(using: .utf8), !f.defaultJSON.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    @ViewBuilder
    private func field(_ f: PsmithConfigField) -> some View {
        let title = f.display.isEmpty ? f.name : f.display
        switch f.type {
        case .number:
            SKRow(title, detail: detail(f)) {
                HStack(spacing: 8) {
                    required(f)
                    SKTextField(label: title, text: Binding(
                        get: { (values[f.name] as? NSNumber)?.stringValue ?? (values[f.name] as? String) ?? "" },
                        set: { s in
                            let t = s.trimmingCharacters(in: .whitespaces)
                            if t.isEmpty { values[f.name] = nil }
                            else if let i = Int(t) { values[f.name] = i }
                            else if let d = Double(t) { values[f.name] = d }
                            else { values[f.name] = t }
                        }
                    ), placeholder: (defaultValue(f) as? NSNumber)?.stringValue ?? "", width: 100, mono: true)
                }
            }
        case .text:
            SKRow(title, detail: detail(f)) {
                HStack(spacing: 8) { required(f); SKTextField(label: title, text: string(f), placeholder: defaultValue(f) as? String ?? "", width: 240) }
            }
        case .textarea:
            SKRawRow {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { SKLabel(title: title, detail: detail(f)); required(f) }
                    SKTextArea(text: string(f), lines: 3)
                }
            }
        case .boolean:
            SKRow(title, detail: detail(f)) {
                Toggle(title, isOn: Binding(
                    get: { (values[f.name] as? Bool) ?? (defaultValue(f) as? Bool) ?? false },
                    set: { values[f.name] = $0 }
                )).skSwitch()
            }
        case .select:
            let current = values[f.name] as? String ?? defaultValue(f) as? String ?? f.options.first?.value
            SKRow(title, detail: detail(f)) {
                SKPopup(value: f.options.first { $0.value == current }?.label ?? (current ?? "Choose"), minWidth: 140) {
                    ForEach(f.options, id: \.value) { o in Button(o.label) { values[f.name] = o.value } }
                }
            }
        case .profilePicker:
            let current = values[f.name] as? String
            SKRow(title, detail: detail(f)) {
                SKPopup(value: profiles.first { $0.id == current }?.name ?? "Choose a profile", minWidth: 160) {
                    ForEach(profiles) { p in Button(p.name) { values[f.name] = p.id } }
                }
            }
        case .modelPicker:
            let obj = values[f.name] as? [String: Any]
            SKModelRow(title: title, detail: detail(f), models: models, providerLabels: providerLabels, providerLogos: providerLogos,
                       providerID: obj?["provider_id"] as? String, modelID: obj?["model_id"] as? String,
                       inheritLabel: nil, unsetName: "Choose", requires: f.modelPickerFilter, openRow: $openRow) { p, m in
                if let p, let m { values[f.name] = ["provider_id": p, "model_id": m] } else { values[f.name] = nil }
            }
        case .list, .autoID:
            EmptyView()
        }
    }
}

/// A list field: one row per item, one open at a time, Add and Paste JSON.
struct SKListFieldGroup: View {
    let field: PsmithConfigField
    @Binding var rows: [[String: Any]]
    @State private var open: Int?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var pasteError: String?

    private func summary(_ row: [String: Any]) -> String {
        for f in field.itemFields where f.type != .autoID {
            if let s = row[f.name] as? String, !s.isEmpty { return s }
        }
        return "Untitled"
    }

    var body: some View {
        SKGroup(field.display.isEmpty ? field.name : field.display) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                SKRawRow(vertical: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Button { open = open == i ? nil : i } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: open == i ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(SK.tertiary).frame(width: 12)
                                    Text(summary(row)).sk(13)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Delete") { rows.remove(at: i); open = nil }.skButton(.plainQuiet)
                        }
                        if open == i {
                            SKPluginFields(fields: field.itemFields, values: Binding(
                                get: { rows.indices.contains(i) ? rows[i] : [:] },
                                set: { if rows.indices.contains(i) { rows[i] = $0 } }
                            ), mainTitle: "")
                            .padding(.top, 8)
                        }
                    }
                }
            }
            if pasting {
                SKRawRow {
                    VStack(alignment: .leading, spacing: 7) {
                        SKLabel(title: "Paste JSON", detail: "An array of rows. Replaces everything above.")
                        SKTextArea(text: $pasted, lines: 4, mono: true)
                        if let pasteError { Text(pasteError).sk(11.5, SK.red) }
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Button("Cancel") { pasting = false; pasted = ""; pasteError = nil }.skButton(small: true)
                            Button("Replace Rows") { applyPaste() }.skButton(.primary, small: true).disabled(pasted.isEmpty)
                        }
                    }
                }
            }
            SKRawRow {
                HStack(spacing: 8) {
                    Button { rows.append(newRow()); open = rows.count - 1 } label: {
                        HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("Add") }
                    }
                    .skButton(small: true)
                    Button("Paste JSON") { pasting = true }.skButton(small: true)
                }
            }
        } footer: {
            Text("One row open at a time.")
        }
    }

    private func newRow() -> [String: Any] {
        var row: [String: Any] = [:]
        for f in field.itemFields where f.type == .autoID { row[f.name] = UUID().uuidString.lowercased() }
        return row
    }

    private func applyPaste() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(pasted.utf8)) else { pasteError = "Doesn't parse as JSON."; return }
        var list = obj as? [[String: Any]]
        if list == nil, let dict = obj as? [String: Any] { list = dict[field.name] as? [[String: Any]] }
        guard var list else { pasteError = "Expected a list of rows."; return }
        for i in list.indices {
            for f in field.itemFields where f.type == .autoID && list[i][f.name] == nil { list[i][f.name] = UUID().uuidString.lowercased() }
        }
        rows = list
        pasting = false
        pasted = ""
        pasteError = nil
    }
}

/// The parent choice: None, then every profile that can be one, as cards.
/// A profile can't be its own parent, nor inherit from one of its own
/// descendants (the server refuses the loop on save).
struct SKParentCards: View {
    let profiles: [PsmithProfile]
    let excluding: String?
    @Binding var parentID: String?

    static func candidates(_ profiles: [PsmithProfile], for id: String?) -> [PsmithProfile] {
        guard let id else { return profiles }
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func descends(_ p: PsmithProfile) -> Bool {
            var seen: Set<String> = []
            var cur = p.parentProfileID
            while let c = cur, !seen.contains(c) {
                if c == id { return true }
                seen.insert(c)
                cur = byID[c]?.parentProfileID
            }
            return false
        }
        return profiles.filter { $0.id != id && !descends($0) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                card("None", "Standalone", selected: parentID == nil, dashed: true) { parentID = nil }
                ForEach(Self.candidates(profiles, for: excluding)) { p in
                    card(p.name, p.parentOnly ? "Parent only" : p.description, selected: parentID == p.id, dashed: false) { parentID = p.id }
                }
            }
        }
    }

    private func card(_ title: String, _ detail: String, selected: Bool, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).sk(12.5, weight: .semibold).lineLimit(1)
                Text(detail.isEmpty ? " " : detail).sk(11, SK.secondary).lineLimit(1)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(width: 150, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? SK.accent.opacity(0.12) : (dashed ? .clear : Color.white.opacity(0.03))))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(SK.accent, lineWidth: 2)
                } else if dashed {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(SK.line, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
