import SwiftUI
import PsmithKit
import PsmithUI

// Settings → MCP Servers. Registry CRUD only: attaching a registered
// server to a profile or conversation happens in the normal plugin
// pickers, where each server appears as its own entry ("Firecrawl"),
// courtesy of the ListPluginTypes pseudo-plugin composition.

// MARK: - Middle column (server list)

struct MCPServersMiddleColumn: View {
    @Bindable var model: MCPServersViewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsListHeader(
                title: "MCP Servers",
                count: model.servers.count,
                countNoun: "registered",
                onBack: onBack,
                onCreate: { model.startAdding() },
                createDisabled: model.isAddingNew
            )

            if model.isLoading, model.servers.isEmpty {
                ProgressView().padding()
                Spacer()
            } else {
                List(selection: Binding(
                    get: { model.isAddingNew ? nil : model.selectedID },
                    set: { id in if let id { model.select(id) } }
                )) {
                    ForEach(model.servers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .scaledFont(.callout, weight: .medium)
                            Text(server.summary)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(server.id)
                    }
                    if model.servers.isEmpty {
                        Text("No servers yet. Register one and it shows up in every plugin picker.")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Detail (form)

struct MCPServersDetail: View {
    @Bindable var model: MCPServersViewModel

    var body: some View {
        Group {
            if model.isAddingNew {
                MCPServerForm(model: model, server: nil)
                    .id("__adding__")
            } else if let server = model.selected {
                MCPServerForm(model: model, server: server)
                    .id(server.id)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Select a server, or register a new one")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
            Text("Registered servers appear as plugins you can attach to any profile or conversation. Credentials stay here, encrypted.")
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline create/edit form (identity-keyed by the host so drafts reset
/// per server). Secret fields are write-only round-trip: blank input
/// keeps the stored value; the caption says whether one exists.
struct MCPServerForm: View {
    @Bindable var model: MCPServersViewModel
    let server: PsmithMCPServer?

    @State private var name: String
    @State private var transport: String
    @State private var command: String
    @State private var args: String
    @State private var env: String = ""
    @State private var url: String
    @State private var headers: String = ""
    @State private var toolPrefix: String
    @State private var isSaving = false
    @State private var showingDeleteConfirm = false

    init(model: MCPServersViewModel, server: PsmithMCPServer?) {
        self.model = model
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _transport = State(initialValue: server?.transport ?? "http")
        _command = State(initialValue: server?.command ?? "")
        _args = State(initialValue: server?.args ?? "")
        _url = State(initialValue: server?.url ?? "")
        _toolPrefix = State(initialValue: server?.toolPrefix ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                identitySection
                transportSection
                toolsSection
                if let err = model.error {
                    Text(err)
                        .scaledFont(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actionBar
                if server != nil {
                    Divider().padding(.vertical, 8)
                    dangerZone
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.top, 28)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server == nil ? "Register MCP server" : (server?.name ?? ""))
                .scaledFont(.title2, weight: .semibold)
            Text("One entry per server. Attach it from any profile's or conversation's plugin picker; the credentials below never leave this page.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identitySection: some View {
        sectionCard("Server") {
            VStack(alignment: .leading, spacing: 14) {
                fieldRow(
                    title: "Name",
                    description: "Shown as the plugin's name in every picker."
                ) {
                    TextField("Server name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow(
                    title: "Transport",
                    description: "How psmithd reaches the server."
                ) {
                    Picker("", selection: $transport) {
                        Text("HTTP (remote URL)").tag("http")
                        Text("Stdio (subprocess)").tag("stdio")
                        Text("In-process").tag("inproc")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var transportSection: some View {
        if transport == "http" {
            sectionCard("Endpoint") {
                VStack(alignment: .leading, spacing: 14) {
                    fieldRow(
                        title: "URL",
                        description: "JSON-RPC endpoint (Streamable HTTP transport)."
                    ) {
                        TextField("https://example.com/mcp", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    fieldRow(
                        title: "HTTP headers",
                        description: "KEY: VALUE per line — usually the auth header. "
                            + secretHint(server?.hasHeaders ?? false)
                    ) {
                        TextEditor(text: $headers)
                            .frame(minHeight: 48, maxHeight: 90)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        } else if transport == "stdio" {
            sectionCard("Subprocess") {
                VStack(alignment: .leading, spacing: 14) {
                    fieldRow(
                        title: "Command",
                        description: "Executable, resolved against PATH."
                    ) {
                        TextField("npx", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    fieldRow(
                        title: "Arguments",
                        description: "One CLI argument per line."
                    ) {
                        TextEditor(text: $args)
                            .frame(minHeight: 48, maxHeight: 90)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                    fieldRow(
                        title: "Environment variables",
                        description: "KEY=VALUE per line; the subprocess inherits nothing else. "
                            + secretHint(server?.hasEnv ?? false)
                    ) {
                        TextEditor(text: $env)
                            .frame(minHeight: 48, maxHeight: 90)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        } else {
            sectionCard("In-process") {
                Text("Dispatches to this Psmith instance's own MCP surface. No configuration needed.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toolsSection: some View {
        sectionCard("Tools") {
            fieldRow(
                title: "Tool name prefix",
                description: "Optional. Prepended to every tool name so two servers with identical tools don't collide. Overridable per attachment."
            ) {
                TextField("Optional", text: $toolPrefix)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
        }
    }

    private var actionBar: some View {
        HStack {
            if let state = server.flatMap({ model.testStates[$0.id] }) {
                testBanner(state)
            }
            Spacer()
            if let server {
                Button {
                    Task { await model.test(id: server.id) }
                } label: {
                    if case .testing = model.testStates[server.id] {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.glass)
                .disabled(isSaving || model.testStates[server.id] == .testing)
                .help("Dial the server, run the MCP handshake, and list its tools")
            }
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(server == nil ? "Register" : "Save")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
    }

    @ViewBuilder
    private func testBanner(_ state: MCPServersViewModel.TestState) -> some View {
        switch state {
        case .testing:
            Text("Probing…")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        case .result(let r):
            if r.ok {
                Label {
                    Text(r.toolNames.isEmpty
                        ? "Connected — no tools advertised"
                        : "Connected — \(r.toolNames.count) tools: \(r.toolNames.joined(separator: ", "))")
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .scaledFont(.caption)
            } else {
                Label {
                    Text(r.errorMessage).lineLimit(2)
                } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var dangerZone: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete this server")
                    .scaledFont(.callout, weight: .medium)
                Text("Profiles referencing it keep their attachment but stop exposing its tools.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete…", role: .destructive) {
                showingDeleteConfirm = true
            }
            .confirmationDialog(
                "Delete \(server?.name ?? "server")?",
                isPresented: $showingDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        if let id = server?.id, await model.delete(id: id) {
                            model.selectedID = nil
                        }
                    }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmedEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeaders = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = await model.upsert(
            id: server?.id,
            name: name.trimmingCharacters(in: .whitespaces),
            transport: transport,
            command: command,
            args: args,
            // Blank secret input = keep what's stored (the form never
            // echoes secrets back, so blank is the common case).
            env: trimmedEnv.isEmpty ? nil : env,
            url: url.trimmingCharacters(in: .whitespaces),
            headers: trimmedHeaders.isEmpty ? nil : headers,
            toolPrefix: toolPrefix.trimmingCharacters(in: .whitespaces)
        )
        if let saved {
            model.isAddingNew = false
            model.selectedID = saved.id
            env = ""
            headers = ""
        }
    }

    private func secretHint(_ set: Bool) -> String {
        set ? "A value is stored; leave blank to keep it." : "Stored encrypted."
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func fieldRow<Field: View>(title: String, description: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).scaledFont(.callout, weight: .medium)
            Text(description).scaledFont(.caption2).foregroundStyle(.tertiary)
            field()
        }
    }
}
