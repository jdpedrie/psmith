import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Accounts (board SettingsAccounts): every account on this
/// iPhone, switch in place, swipe to remove (confirmed in place), add one,
/// sign out of the active one.
struct SettingsAccounts: View {
    @Environment(AccountManager.self) private var manager
    @Environment(AppModel.self) private var app
    @State private var confirmingRemove: UUID?

    var body: some View {
        SettingsAccountsScreen(
            items: items,
            activeName: activeName,
            confirmingRemove: $confirmingRemove,
            onSwitch: { manager.switchAccount(to: $0) },
            onRemove: { id in Task { await manager.removeAccount(id: id) } },
            onSignOut: { Task { await manager.signOutActive() } }
        )
    }

    private var activeName: String {
        let u = app.authState.currentUser
        return u?.displayName ?? u?.username ?? manager.accounts.first { $0.id == manager.activeAccountID }?.username ?? ""
    }

    private var items: [SettingsAccountItem] {
        manager.accounts.map { a in
            let active = a.id == manager.activeAccountID
            return SettingsAccountItem(
                id: a.id,
                name: active ? activeName : (a.displayLabel ?? a.username),
                host: a.host.absoluteString,
                shortHost: a.host.host ?? a.host.absoluteString,
                isActive: active,
                signedIn: manager.isSignedIn(a.id)
            )
        }
    }
}

struct SettingsAccountItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let host: String
    let shortHost: String
    let isActive: Bool
    let signedIn: Bool
}

struct SettingsAccountsScreen: View {
    let items: [SettingsAccountItem]
    let activeName: String
    @Binding var confirmingRemove: UUID?
    let onSwitch: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onSignOut: () -> Void
    @Environment(\.theme) private var theme
    @State private var addingAccount = false

    var body: some View {
        List {
            IKSHead("On this iPhone", first: true).iksListRow()
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                accountRow(item)
                    .iksGroupRow(first: i == 0, last: i == items.count - 1)
                    .iksListRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !item.isActive {
                            Button { confirmingRemove = item.id } label: { Label("Remove", systemImage: "trash") }
                                .tint(IK.destructiveFill)
                        }
                    }
            }
            IKSFooter("Swipe an account to remove it. Sign out of \(activeName) before removing it.").iksListRow()

            IKSActionRow(title: "Add Account", systemImage: "plus") { addingAccount = true }
            .iksGroupRow(first: true, last: true)
            .padding(.top, 18)
            .iksListRow()
            IKSFooter("Another server, or another user on this one.").iksListRow()

            IKSActionRow(title: "Sign Out of \(activeName)", color: IK.red, centered: true, action: onSignOut)
                .iksGroupRow(first: true, last: true)
                .padding(.top, 18)
                .iksListRow()
            IKSFooter("Ends this session on the server. \(activeName) stays in the list, so signing back in takes only the password.")
                .iksListRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, 13, for: .scrollContent)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationDestination(isPresented: $addingAccount) { LoginView() }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func accountRow(_ item: SettingsAccountItem) -> some View {
        if confirmingRemove == item.id {
            IKSInsetConfirm(
                question: "Remove \(item.name) · \(item.shortHost)?",
                detail: "Signs out on the server and forgets it on this iPhone. Its conversations stay on that server.",
                confirmLabel: "Remove",
                onCancel: { confirmingRemove = nil },
                onConfirm: {
                    confirmingRemove = nil
                    Haptics.notify(.warning)
                    onRemove(item.id)
                }
            )
        } else {
            IKSRow(vertical: 10) {
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(item.isActive ? theme.accent : ProfileColor.color(for: item.id.uuidString, theme: theme)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).fontWeight(.semibold)
                    HStack(spacing: 6) {
                        if item.isActive && item.signedIn { IKDot(color: IK.green, size: 7) }
                        Text(item.host).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(IK.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .accessibilityLabel("Current account")
                } else {
                    Button(item.signedIn ? "Switch" : "Sign in") { onSwitch(item.id) }
                        .font(.system(size: 15))
                        .foregroundStyle(IK.text)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .buttonStyle(.plain)
                        .ikGlass(in: Capsule(), ground: .settings)
                        .accessibilityLabel("Switch to \(item.name)")
                }
            }
            .contextMenu {
                if !item.isActive {
                    Button(role: .destructive) { confirmingRemove = item.id } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }
}
