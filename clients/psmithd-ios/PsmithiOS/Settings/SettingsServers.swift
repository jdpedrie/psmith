import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Servers (board SettingsServers): the MCP server registry.
/// A registered server shows up as a plugin in every plugin picker, so
/// attaching happens there; this page only manages the entries. Status
/// comes from the last test.
struct SettingsServers: View {
    @Environment(AppModel.self) private var app
    @State private var loaded = false
    @State private var confirmingDelete: String?

    var body: some View {
        let model = app.mcpServers
        Group {
            if !loaded && model.servers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsServersScreen(
                    servers: model.servers,
                    states: model.testStates,
                    error: model.error,
                    confirmingDelete: $confirmingDelete,
                    onDelete: { id in Task { _ = await model.delete(id: id) } },
                    onRetry: { Task { await model.load() } }
                )
            }
        }
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
            loaded = true
        }
        .refreshable { await model.load() }
    }
}

struct SettingsServersScreen: View {
    let servers: [PsmithMCPServer]
    let states: [String: MCPServersViewModel.TestState]
    let error: String?
    @Binding var confirmingDelete: String?
    let onDelete: (String) -> Void
    let onRetry: () -> Void
    @State private var openID: String?

    var body: some View {
        List {
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    IKSError(text: error)
                    if servers.isEmpty { Button("Retry", action: onRetry).ikButton() }
                }
                .padding(.bottom, 8)
                .iksListRow()
            }
            if servers.isEmpty && error == nil {
                IKSRow(vertical: 12) {
                    IKSTitleNote(title: "No servers yet",
                                 note: "Register a server once and it appears as a plugin in every profile and conversation.")
                }
                .iksGroupRow(first: true, last: true)
                .iksListRow()
            }
            ForEach(Array(servers.enumerated()), id: \.element.id) { i, server in
                Group {
                    if confirmingDelete == server.id {
                        IKSInsetConfirm(question: "Delete \(server.name)?",
                                        detail: "Profiles that attach it keep the attachment but stop getting its tools.",
                                        onCancel: { confirmingDelete = nil },
                                        onConfirm: { confirmingDelete = nil; onDelete(server.id) })
                    } else {
                        Button { openID = server.id } label: {
                            SettingsServerRow(server: server, state: states[server.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .iksGroupRow(first: i == 0, last: i == servers.count - 1)
                .iksListRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { confirmingDelete = server.id } label: { Label("Delete", systemImage: "trash") }
                        .tint(IK.destructiveFill)
                }
            }
            IKSFooter("Registered servers appear as plugins you can attach to any profile or conversation. Credentials stay here, encrypted. Status comes from the last test.")
                .iksListRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, -2, for: .scrollContent)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationDestination(item: $openID) { SettingsServerDetail(serverID: $0) }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsAddServer(server: nil) } label: {
                    Text("Add").foregroundStyle(IK.text)
                }
                .accessibilityLabel("Add server")
            }
        }
    }
}

/// What the last test said about a server.
enum MCPServerStatus {
    static func line(_ state: MCPServersViewModel.TestState?) -> (String, Color) {
        switch state {
        case .testing: ("Testing…", IK.tertiary)
        case .result(let r) where r.ok:
            ("Connected · \(r.toolNames.count) tool\(r.toolNames.count == 1 ? "" : "s")", IK.green)
        case .result(let r): ("Failed · \(r.errorMessage)", IK.red)
        case nil: ("Not tested", IK.tertiary)
        }
    }
}

struct SettingsServerRow: View {
    let server: PsmithMCPServer
    let state: MCPServersViewModel.TestState?

    var body: some View {
        let status = MCPServerStatus.line(state)
        IKSRow(vertical: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 14))
                .foregroundStyle(IK.strong)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).fontWeight(.semibold)
                HStack(spacing: 6) {
                    IKDot(color: status.1, size: 7)
                    Text(status.0).lineLimit(1)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(IK.secondary)
                Text(server.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(IK.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IKChevron()
        }
    }
}

// MARK: - Detail

/// A server's page (board SettingsServerDetail): its last test, connection,
/// advertised tools, and delete confirmed in place.
struct SettingsServerDetail: View {
    let serverID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        let model = app.mcpServers
        if let server = model.servers.first(where: { $0.id == serverID }) {
            SettingsServerDetailScreen(
                server: server,
                state: model.testStates[server.id],
                error: model.error,
                confirmingDelete: $confirmingDelete,
                onTest: { Task { await model.test(id: server.id) } },
                onDelete: {
                    Task { if await model.delete(id: server.id) { dismiss() } }
                }
            )
            .onAppear { model.error = nil }
        } else {
            IKSettingsPage(title: "Server") {
                IKSFooter("This server is gone. It may have been deleted on another device.", top: 0)
            }
        }
    }
}

struct SettingsServerDetailScreen: View {
    let server: PsmithMCPServer
    let state: MCPServersViewModel.TestState?
    let error: String?
    @Binding var confirmingDelete: Bool
    let onTest: () -> Void
    let onDelete: () -> Void

    private var transportLabel: String {
        switch server.transport {
        case "http": "HTTP"
        case "stdio": "Stdio"
        case "inproc": "In-process"
        default: server.transport
        }
    }

    var body: some View {
        let status = MCPServerStatus.line(state)
        IKSettingsPage(title: server.name) {
            IKGroup {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundStyle(IK.strong)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.08)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                        HStack(spacing: 6) {
                            IKDot(color: status.1, size: 7)
                            Text(status.0).lineLimit(2)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(IK.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(state == .testing ? "Testing…" : "Test", action: onTest)
                        .ikButton()
                        .disabled(state == .testing)
                }
                .padding(14)
            }

            IKSHead("Connection")
            IKGroup {
                IKSValueRow(title: "Transport", value: transportLabel)
                switch server.transport {
                case "http":
                    block("URL", server.url)
                    secretRow("HTTP headers", set: server.hasHeaders)
                case "stdio":
                    block("Command", server.command)
                    if !server.args.isEmpty { block("Arguments", server.args) }
                    secretRow("Environment", set: server.hasEnv)
                default:
                    IKSRow { Text("Runs on this Psmith server. Nothing to configure.").font(.system(size: 15)).foregroundStyle(IK.secondary) }
                }
                IKSValueRow(title: "Tool prefix", value: server.toolPrefix.isEmpty ? "None" : server.toolPrefix,
                            mono: !server.toolPrefix.isEmpty)
            }

            if case .result(let r) = state, r.ok, !r.toolNames.isEmpty {
                IKSHead("Tools")
                IKGroup {
                    IKSFlow(spacing: 6) {
                        ForEach(r.toolNames, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(IK.text)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 8).fill(IKS.field))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(IK.ring(0.06), lineWidth: 1))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                IKSFooter("From the last test: Psmith dialed the server, ran the MCP handshake, and listed what it offers.")
            } else {
                IKSFooter("Test dials the server, runs the MCP handshake, and lists the tools it offers.")
            }
            if let error { IKSError(text: error) }

            IKSHead("Danger zone")
            if confirmingDelete {
                IKConfirmCard(question: "Delete \(server.name)?",
                              detail: "Profiles that attach it keep the attachment but stop getting its tools.",
                              onCancel: { confirmingDelete = false },
                              onConfirm: { confirmingDelete = false; onDelete() })
            } else {
                IKGroup {
                    IKSActionRow(title: "Delete server", color: IK.red) { confirmingDelete = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsAddServer(server: server) } label: { Text("Edit").foregroundStyle(IK.text) }
            }
        }
    }

    private func block(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 16)).foregroundStyle(IK.text)
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary).textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secretRow(_ title: String, set: Bool) -> some View {
        IKSRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if set { Image(systemName: "lock").font(.system(size: 12)) }
                Text(set ? "Stored encrypted" : "None")
            }
            .font(.system(size: 15))
            .foregroundStyle(IK.secondary)
        }
    }
}

/// Wraps children onto as many lines as they need.
struct IKSFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Add / edit

/// Register or edit a server (board SettingsAddServer). Secrets are write
/// only: left blank, the stored value stays.
struct SettingsAddServer: View {
    let server: PsmithMCPServer?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MCPServerDraft()
    @State private var seeded = false
    @State private var saving = false

    var body: some View {
        SettingsAddServerScreen(
            draft: $draft,
            editing: server,
            saving: saving,
            error: app.mcpServers.error,
            onCancel: { dismiss() },
            onSave: { Task { await save() } }
        )
        // The registry's error is shared with the list; an old list failure
        // shouldn't greet a fresh form.
        .onAppear {
            app.mcpServers.error = nil
            guard !seeded else { return }
            seeded = true
            if let server { draft = MCPServerDraft(server) }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let env = draft.env.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = draft.headers.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = await app.mcpServers.upsert(
            id: server?.id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            transport: draft.transport,
            command: draft.command,
            args: draft.args,
            env: env.isEmpty ? nil : draft.env,
            url: draft.url.trimmingCharacters(in: .whitespaces),
            headers: headers.isEmpty ? nil : draft.headers,
            toolPrefix: draft.toolPrefix.trimmingCharacters(in: .whitespaces)
        )
        if saved != nil { dismiss() }
    }
}

struct MCPServerDraft: Equatable {
    var name = ""
    var transport = "http"
    var command = ""
    var args = ""
    var env = ""
    var url = ""
    var headers = ""
    var toolPrefix = ""

    init() {}

    init(_ s: PsmithMCPServer) {
        name = s.name
        transport = s.transport
        command = s.command
        args = s.args
        url = s.url
        toolPrefix = s.toolPrefix
    }
}

struct SettingsAddServerScreen: View {
    @Binding var draft: MCPServerDraft
    let editing: PsmithMCPServer?
    let saving: Bool
    let error: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }
    private var dirty: Bool { editing.map { MCPServerDraft($0) != draft } ?? true }

    var body: some View {
        IKSettingsPage(title: editing == nil ? "Add server" : "Edit \(editing?.name ?? "")") {
            IKGroup {
                IKSStackedField(label: "Name", text: $draft.name, placeholder: "GitHub",
                                caption: "Shown as the plugin’s name in every picker.")
                    .padding(.horizontal, 14).padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transport").font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
                    IKSSegmented(options: [("http", "HTTP"), ("stdio", "Stdio"), ("inproc", "In-process")],
                                 selection: $draft.transport, height: 36, inset: true)
                        .padding(.top, 6)
                    Text("How psmithd reaches the server.").font(.system(size: 12.5)).foregroundStyle(IK.tertiary)
                        .padding(.top, 7).padding(.bottom, 1)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }

            switch draft.transport {
            case "http":
                IKSHead("Endpoint")
                IKGroup {
                    IKSStackedField(label: "URL", text: $draft.url, placeholder: "https://example.com/mcp",
                                    caption: "JSON-RPC endpoint (Streamable HTTP transport).", mono: true, monoSize: 14)
                        .keyboardType(.URL)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    IKSTextArea(label: "HTTP headers", text: $draft.headers,
                                placeholder: editing?.hasHeaders == true ? "Leave blank to keep the stored headers" : "Authorization: Bearer …",
                                caption: "KEY: VALUE per line, usually the auth header. " + secretHint(editing?.hasHeaders ?? false))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            case "stdio":
                IKSHead("Command")
                IKGroup {
                    IKSStackedField(label: "Command", text: $draft.command, placeholder: "npx", mono: true, monoSize: 14)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    IKSTextArea(label: "Arguments", text: $draft.args, placeholder: "One per line",
                                caption: "One CLI argument per line.")
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    IKSTextArea(label: "Environment variables", text: $draft.env,
                                placeholder: editing?.hasEnv == true ? "Leave blank to keep the stored values" : "KEY=VALUE",
                                caption: "KEY=VALUE per line; the process inherits nothing else. " + secretHint(editing?.hasEnv ?? false))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            default:
                IKSFooter("Dispatches to this Psmith server’s own MCP tools. Nothing to configure.")
            }

            IKSHead("Tools")
            IKGroup {
                IKSStackedField(label: "Tool name prefix", text: $draft.toolPrefix, placeholder: "Optional",
                                caption: "Prepended to every tool name so two servers with the same tools don’t collide. Each attachment can override it.",
                                mono: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            if let error { IKSError(text: error) }
            IKSFooter(editing == nil ? "Register it, then test the connection from the server’s page."
                                     : "Saving keeps any secret you left blank.")
        } bar: {
            if dirty {
                IKSaveBar(summary: editing == nil ? "New server" : "Unsaved changes",
                          saveLabel: editing == nil ? "Register" : "Save",
                          revertLabel: "Cancel", canSave: canSave, onRevert: onCancel, onSave: onSave)
            }
        }
    }

    private func secretHint(_ set: Bool) -> String {
        set ? "A value is stored; leave blank to keep it." : "Stored encrypted."
    }
}
