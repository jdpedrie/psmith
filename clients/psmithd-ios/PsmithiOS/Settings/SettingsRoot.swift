import SwiftUI
import PsmithKit
import PsmithUI

/// Settings, pushed onto the chats stack (board SettingsRoot). The account
/// card leads to Accounts; search filters the rows; each row shows the
/// state behind it so most questions are answered without opening anything.
/// The version footer answers "am I running the latest build?"
struct SettingsRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accounts
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs
    @Environment(iOSNavigator.self) private var navigator

    @State private var search = ""
    @State private var monthSpend: Double?
    @State private var langfuse: PsmithLangfuseConfig?
    @State private var embedder: PsmithEmbedderConfig?
    @State private var speech: PsmithSpeechConfig?
    @State private var serverVersion = "…"
    @State private var openProfiles = false

    var body: some View {
        SettingsRootScreen(summary: summary, search: $search)
            .navigationDestination(isPresented: $openProfiles) { SettingsProfilesList() }
            .task { await loadSummary() }
            .onAppear { if navigator.pendingProfileSelection != nil { openProfiles = true } }
            .onChange(of: navigator.pendingProfileSelection) { _, id in if id != nil { openProfiles = true } }
    }

    private var summary: SettingsRootSummary {
        let active = accounts.accounts.first { $0.id == accounts.activeAccountID }
        let user = app.authState.currentUser
        var s = SettingsRootSummary()
        s.accountName = user?.displayName ?? user?.username ?? active?.username ?? ""
        s.accountHost = app.serverURL.host ?? app.serverURL.absoluteString
        s.accountCount = accounts.accounts.count
        s.theme = themeStore.current.name
        s.notifications = prefs.notifyOnUnfocusedCompletion ? "On" : "Off"
        s.privacy = LocationFactPreference.enabled ? "Location on" : "Location off"
        s.fillCounts(from: app)
        if let monthSpend { s.usage = "\(SettingsFormat.usd(monthSpend)) in \(Date.now.formatted(.dateTime.month(.abbreviated)))" }
        if let langfuse {
            s.langfuse = langfuse.enabled ? "On" : "Off"
            s.langfuseDot = langfuse.enabled ? IK.green : nil
        }
        if let embedder { s.embedder = embedder.enabled ? "On" : "Off" }
        if let speech { s.speech = SettingsFormat.speechSummary(speech) }
        s.files = FilesFolderBookmark.isSet ? (SettingsFiles.displayPath() ?? "On") : nil
        s.version = "Psmith \(BuildInfo.commit) · Server \(serverVersion)"
        return s
    }

    private func loadSummary() async {
        async let version: Void = loadVersion()
        async let cost: Void = loadCost()
        async let lf: Void = { langfuse = try? await app.client.langfuse.get() }()
        async let em: Void = { embedder = try? await app.client.embedder.get() }()
        async let sp: Void = { speech = try? await app.client.speech.get() }()
        async let lists: Void = loadLists()
        _ = await (version, cost, lf, em, sp, lists)
    }

    private func loadVersion() async {
        switch await app.client.auth.probe() {
        case .ok(_, let v): serverVersion = v.isEmpty ? "dev" : v
        case .wrongServer, .unreachable: serverVersion = "unreachable"
        }
    }

    private func loadCost() async {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start
        if let result = try? await app.client.modelProviders.listProviderCosts(since: start, until: nil) {
            monthSpend = result.grandTotal
        }
    }

    private func loadLists() async {
        if app.profiles.pluginTypes.isEmpty { await app.profiles.loadPluginTypes() }
        if app.mcpServers.servers.isEmpty { await app.mcpServers.load() }
    }
}

/// What the root rows show. Plain values so a probe can set the board's.
struct SettingsRootSummary {
    /// The rows counted from what the app already holds: models, profiles,
    /// plugins (built in plus MCP servers) and servers up after their last test.
    @MainActor
    mutating func fillCounts(from app: AppModel) {
        let providers = app.providers.providers.count
        models = providers == 0 ? nil : "\(providers) provider\(providers == 1 ? "" : "s") · \(app.providers.enabledModels.count)"
        profiles = app.profiles.profiles.isEmpty ? nil : "\(app.profiles.profiles.count)"
        let pluginCount = app.profiles.pluginTypes.filter { !$0.name.hasPrefix("mcp:") }.count + app.mcpServers.servers.count
        plugins = pluginCount == 0 ? nil : "\(pluginCount)"
        let all = app.mcpServers.servers
        let results = all.compactMap { s -> Bool? in
            if case .result(let r) = app.mcpServers.testStates[s.id] { return r.ok }
            return nil
        }
        let up = results.filter { $0 }.count
        if !all.isEmpty {
            servers = results.isEmpty ? "\(all.count)" : "\(up) of \(all.count) up"
            serversDot = results.isEmpty ? nil : (up == all.count ? IK.green : IK.orange)
        }
    }

    var accountName = ""
    var accountHost = ""
    var accountCount = 1
    var theme = ""
    var notifications = ""
    var privacy = ""
    var models: String?
    var profiles: String?
    var plugins: String?
    var servers: String?
    var serversDot: Color?
    var usage: String?
    var langfuse: String?
    var langfuseDot: Color?
    var embedder: String?
    var speech: String?
    var files: String?
    var version = ""
}

struct SettingsRootScreen: View {
    let summary: SettingsRootSummary
    @Binding var search: String
    @Environment(\.theme) private var theme

    private struct Entry: Identifiable {
        let id: String
        let section: String
        let icon: String
        var value: String?
        var dot: Color?
        var keywords = ""
        let destination: () -> AnyView
    }

    private var entries: [Entry] {
        [
            Entry(id: "General", section: "", icon: "gearshape", keywords: "cache context warning") { AnyView(SettingsGeneral()) },
            Entry(id: "Appearance", section: "", icon: "paintpalette", value: summary.theme,
                  keywords: "theme turn details text") { AnyView(SettingsAppearance()) },
            Entry(id: "Notifications", section: "", icon: "bell", value: summary.notifications) { AnyView(SettingsNotifications()) },
            Entry(id: "Privacy", section: "", icon: "hand.raised", value: summary.privacy, keywords: "location") { AnyView(SettingsPrivacy()) },
            Entry(id: "Models", section: "Data", icon: "cpu", value: summary.models, keywords: "providers") { AnyView(ModelsSettingsScreen()) },
            Entry(id: "Profiles", section: "Data", icon: "person.crop.rectangle", value: summary.profiles) { AnyView(SettingsProfilesList()) },
            Entry(id: "Plugins", section: "Data", icon: "puzzlepiece.extension", value: summary.plugins) { AnyView(SettingsPlugins()) },
            Entry(id: "Servers", section: "Data", icon: "server.rack", value: summary.servers, dot: summary.serversDot,
                  keywords: "mcp") { AnyView(SettingsServers()) },
            Entry(id: "Usage", section: "Data", icon: "dollarsign.circle", value: summary.usage, keywords: "cost spend") { AnyView(SettingsUsage()) },
            Entry(id: "Langfuse", section: "Integrations", icon: "chart.line.uptrend.xyaxis", value: summary.langfuse,
                  dot: summary.langfuseDot, keywords: "traces") { AnyView(SettingsLangfuse()) },
            Entry(id: "Embedder", section: "Integrations", icon: "point.3.connected.trianglepath.dotted", value: summary.embedder,
                  keywords: "memory embeddings") { AnyView(SettingsEmbedder()) },
            Entry(id: "Speech", section: "Integrations", icon: "speaker.wave.2", value: summary.speech,
                  keywords: "voice read aloud") { AnyView(SettingsSpeech()) },
            Entry(id: "Files and Device Tools", section: "Integrations", icon: "folder", value: summary.files,
                  keywords: "folder calendar reminders obsidian activity") { AnyView(SettingsFiles()) },
        ]
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var visible: [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(IK.text)
                    .frame(height: 36)
                    .padding(.top, -10)
                    .padding(.bottom, 10)
                accountCard
                searchField.padding(.top, 14)
                let rows = visible
                ForEach(["", "Data", "Integrations"], id: \.self) { section in
                    let inSection = rows.filter { $0.section == section }
                    if !inSection.isEmpty {
                        if section.isEmpty {
                            Color.clear.frame(height: 14)
                        } else {
                            IKSHead(section)
                        }
                        IKGroup(separatorInset: 52) {
                            ForEach(inSection) { row($0) }
                        }
                    }
                }
                if rows.isEmpty {
                    Text("No settings match “\(query)”.")
                        .font(.system(size: 15))
                        .foregroundStyle(IK.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                Text(summary.version)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IK.tertiary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }

    private var accountCard: some View {
        NavigationLink { SettingsAccounts() } label: {
            HStack(spacing: 12) {
                Text(String(summary.accountName.prefix(1)).uppercased())
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.accent))
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary.accountName).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                    Text("\(summary.accountHost) · \(summary.accountCount) account\(summary.accountCount == 1 ? "" : "s")")
                        .font(.system(size: 13.5))
                        .foregroundStyle(IK.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                IKChevron()
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Accounts, \(summary.accountName)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(IK.secondary)
            TextField("Search settings", text: $search)
                .font(.system(size: 16))
                .foregroundStyle(IK.text)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IK.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11).fill(IK.wash(0.07)))
    }

    private func row(_ e: Entry) -> some View {
        NavigationLink(destination: e.destination) {
            HStack(spacing: 12) {
                Image(systemName: e.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(IK.strong)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
                Text(e.id).font(.system(size: 16)).foregroundStyle(IK.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value = e.value {
                    HStack(spacing: 6) {
                        if let dot = e.dot { IKDot(color: dot, size: 7) }
                        Text(value)
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(IK.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                }
                IKChevron()
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Formatting shared by the Settings rows.
enum SettingsFormat {
    static func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func speechKind(_ kind: String) -> String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal: "On-device (Apple)"
        case "grok": "Grok (xAI)"
        case "openai-compatible": "OpenAI-compatible"
        default: kind
        }
    }

    static func speechSummary(_ c: PsmithSpeechConfig) -> String {
        if c.isAppleLocal { return "On-device" }
        let kind = c.kind == "openai-compatible" ? "OpenAI" : (c.kind == "grok" ? "Grok" : c.kind)
        return c.voice.isEmpty ? kind : "\(kind) · \(c.voice)"
    }

    static func bytes(_ n: Int) -> String {
        let mb = Double(n) / (1024 * 1024)
        if mb < 1 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", mb)
    }

    /// "Just now", "4 min ago", "3 hr ago", "Yesterday", then the date.
    static func relative(_ d: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "Just now" }
        if s < 3_600 { return "\(Int(s / 60)) min ago" }
        if Calendar.current.isDate(d, inSameDayAs: now) { return "\(Int(s / 3_600)) hr ago" }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: now), Calendar.current.isDate(d, inSameDayAs: y) {
            return "Yesterday"
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
