import SwiftUI
import PsmithKit
import PsmithUI

/// iOS Settings → MCP Servers. Registry CRUD; push from SettingsRoot.
/// Registered servers show up as pseudo-plugins in every plugin picker
/// (profile + conversation), so attachment lives there — this screen
/// only manages the entries themselves.
struct MCPServersListView: View {
    @Environment(AppModel.self) private var app
    @State private var loaded = false

    var body: some View {
        @Bindable var model = app.mcpServers
        Group {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.servers.isEmpty {
                EmptyStateView(
                    "No MCP servers",
                    systemImage: "server.rack",
                    description: "Register a server once and it appears as a plugin in every profile and conversation. Credentials stay on the server, encrypted."
                )
            } else {
                List {
                    ForEach(model.servers) { server in
                        NavigationLink {
                            MCPServerFormScreen(server: server)
                        } label: {
                            serverRow(server)
                        }
                    }
                    .onDelete { indexSet in
                        Task {
                            for idx in indexSet {
                                _ = await model.delete(id: model.servers[idx].id)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MCPServerFormScreen(server: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Register MCP server")
            }
        }
        .task {
            await app.mcpServers.load()
            loaded = true
        }
    }

    @ViewBuilder
    private func serverRow(_ server: PsmithMCPServer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .foregroundStyle(.primary)
                Text(server.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Create (server == nil) / edit form. Secret fields are write-only:
/// blank keeps the stored value, and the footer says whether one
/// exists.
struct MCPServerFormScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let server: PsmithMCPServer?

    @State private var name: String = ""
    @State private var transport: String = "http"
    @State private var command: String = ""
    @State private var args: String = ""
    @State private var env: String = ""
    @State private var url: String = ""
    @State private var headers: String = ""
    @State private var toolPrefix: String = ""
    @State private var isSaving = false
    @State private var seeded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                Picker("Transport", selection: $transport) {
                    Text("HTTP").tag("http")
                    Text("Stdio").tag("stdio")
                    Text("In-process").tag("inproc")
                }
            } footer: {
                Text("The name is what appears in plugin pickers.")
            }

            if transport == "http" {
                Section {
                    TextField("https://mcp.firecrawl.dev/v2/mcp", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("URL")
                }
                Section {
                    TextEditor(text: $headers)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 60)
                        .autocorrectionDisabled()
                } header: {
                    Text("HTTP headers")
                } footer: {
                    Text("KEY: VALUE per line — usually the auth header. " + secretHint(server?.hasHeaders ?? false))
                }
            } else if transport == "stdio" {
                Section {
                    TextField("npx", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Command")
                }
                Section {
                    TextEditor(text: $args)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 60)
                        .autocorrectionDisabled()
                } header: {
                    Text("Arguments")
                } footer: {
                    Text("One CLI argument per line.")
                }
                Section {
                    TextEditor(text: $env)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 60)
                        .autocorrectionDisabled()
                } header: {
                    Text("Environment variables")
                } footer: {
                    Text("KEY=VALUE per line; the subprocess inherits nothing else. " + secretHint(server?.hasEnv ?? false))
                }
            } else {
                Section {
                    Text("Dispatches to this Psmith instance's own MCP surface. No configuration needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Optional prefix", text: $toolPrefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Tool name prefix")
            } footer: {
                Text("Prepended to every tool name so two servers with identical tools don't collide. Overridable per attachment.")
            }

            if let err = app.mcpServers.error {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(server == nil ? "Register server" : (server?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .onAppear {
            guard !seeded, let server else { seeded = true; return }
            seeded = true
            name = server.name
            transport = server.transport
            command = server.command
            args = server.args
            url = server.url
            toolPrefix = server.toolPrefix
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmedEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeaders = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = await app.mcpServers.upsert(
            id: server?.id,
            name: name.trimmingCharacters(in: .whitespaces),
            transport: transport,
            command: command,
            args: args,
            env: trimmedEnv.isEmpty ? nil : env,
            url: url.trimmingCharacters(in: .whitespaces),
            headers: trimmedHeaders.isEmpty ? nil : headers,
            toolPrefix: toolPrefix.trimmingCharacters(in: .whitespaces)
        )
        if saved != nil {
            dismiss()
        }
    }

    private func secretHint(_ set: Bool) -> String {
        set ? "A value is stored; leave blank to keep it." : "Stored encrypted."
    }
}
