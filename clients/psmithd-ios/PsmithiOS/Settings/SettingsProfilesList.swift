import SwiftUI
import UniformTypeIdentifiers
import PsmithKit
import PsmithUI

/// Settings › Profiles (board SettingsProfilesList). Favorites sort first.
/// Swipe right to make a profile the default; swipe left to favorite or
/// delete it, the delete confirmed in place. Always re-fetched on open so
/// an edit made elsewhere shows up.
struct SettingsProfilesList: View {
    @Environment(AppModel.self) private var app
    @Environment(iOSNavigator.self) private var navigator
    @State private var confirmingDelete: String?
    @State private var importing = false
    @State private var opened: String?

    var body: some View {
        let profiles = app.profiles
        SettingsProfilesListScreen(
            profiles: profiles,
            confirmingDelete: $confirmingDelete,
            onImport: { importing = true },
            onDelete: { p in
                Haptics.notify(.warning)
                profiles.selectedID = p.id
                Task { await profiles.deleteSelected() }
            }
        )
        .navigationDestination(item: $opened) { id in SettingsProfile(profileID: id) }
        .profileImporter(isPresented: $importing, profiles: profiles)
        .task {
            await profiles.load()
            consumePending()
        }
        .refreshable { await profiles.load() }
        .onChange(of: navigator.pendingProfileSelection) { _, _ in consumePending() }
    }

    /// "Open in Settings" from elsewhere lands here with a profile to show.
    private func consumePending() {
        guard let id = navigator.pendingProfileSelection else { return }
        navigator.pendingProfileSelection = nil
        if app.profiles.profiles.contains(where: { $0.id == id }) { opened = id }
    }
}

struct SettingsProfilesListScreen: View {
    @Bindable var profiles: ProfilesViewModel
    @Binding var confirmingDelete: String?
    let onImport: () -> Void
    let onDelete: (PsmithProfile) -> Void
    @Environment(\.theme) private var theme
    @State private var creating = false
    @State private var openID: String?

    private var sorted: [PsmithProfile] {
        profiles.profiles.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let rows = sorted
        List {
            if let err = profiles.error, profiles.pendingImport == nil {
                IKBanner(systemImage: "exclamationmark.triangle", text: err, color: IK.orange) { profiles.error = nil }
                    .padding(.bottom, 12)
                    .iksListRow()
            }
            if !profiles.importWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    IKSHead("Imported. Still needs setting up", first: true)
                    ForEach(profiles.importWarnings) { w in
                        IKBanner(systemImage: "exclamationmark.circle", text: w.message, color: IK.orange)
                            .padding(.bottom, 6)
                    }
                    Button("Dismiss") { profiles.importWarnings = [] }.ikButton().padding(.bottom, 12)
                }
                .iksListRow()
            }
            if let pending = profiles.pendingImport {
                ProfileImportReviewCard(result: pending, filename: ProfileImportFile.name, error: profiles.error,
                                        busy: profiles.isSharing,
                                        onCancel: { profiles.cancelImport() },
                                        onImport: { Task { await profiles.confirmImport() } })
                    .padding(.bottom, 18)
                    .iksListRow()
            }
            if rows.isEmpty {
                IKSRow(vertical: 12) {
                    IKSTitleNote(title: "No profiles yet", note: "A profile holds a prompt, models and plugins. Make one below.")
                }
                .iksGroupRow(first: true, last: true)
                .iksListRow()
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                row(p)
                    .iksGroupRow(first: i == 0, last: i == rows.count - 1)
                    .iksListRow()
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if !p.parentOnly {
                            Button { Task { await profiles.setDefault(p.isDefault ? nil : p.id) } } label: {
                                Label(p.isDefault ? "Clear Default" : "Make Default", systemImage: p.isDefault ? "pin.slash" : "pin")
                            }
                            .tint(theme.accent)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { confirmingDelete = p.id } label: { Label("Delete", systemImage: "trash") }
                            .tint(IK.destructiveFill)
                        Button { Task { await profiles.toggleFavorite(p.id) } } label: {
                            Label(p.favorite ? "Unfavorite" : "Favorite", systemImage: p.favorite ? "star.slash" : "star")
                        }
                        .tint(IK.orange)
                    }
            }
            LoadMoreFooter(token: profiles.nextPageToken) { await profiles.loadMore() }.iksListRow()
            IKSFooter("Favorites sort first. Swipe right to make a profile the default; swipe left to favorite or delete it. Parent-only profiles never appear when you start a chat.")
                .iksListRow()

            IKSActionRow(title: "New profile", systemImage: "plus") { creating = true }
            .iksGroupRow(first: true, last: false)
            .padding(.top, 18)
            .iksListRow()
            IKSActionRow(title: "Import from a file", systemImage: "arrow.down.to.line", action: onImport)
                .disabled(profiles.isSharing)
                .iksGroupRow(first: false, last: true)
                .iksListRow()
            IKSFooter("Imports open a review first. Nothing is created until you confirm.").iksListRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, -2, for: .scrollContent)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationDestination(isPresented: $creating) { SettingsProfile(profileID: nil) }
        .navigationDestination(item: $openID) { SettingsProfile(profileID: $0) }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ p: PsmithProfile) -> some View {
        if confirmingDelete == p.id {
            if profiles.hasChildren(p.id) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(p.name) can’t be deleted").font(.system(size: 15, weight: .semibold)).foregroundStyle(IK.text)
                    Text("Other profiles are based on it. Delete those or point them elsewhere first.")
                        .font(.system(size: 13)).lineSpacing(3).foregroundStyle(IK.secondary).padding(.top, 2)
                    HStack {
                        Spacer()
                        Button("OK") { confirmingDelete = nil }.ikButton()
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
                .padding(8)
            } else {
                IKSInsetConfirm(question: "Delete \(p.name)?",
                                detail: "Conversations that use it can’t send until you pick another profile for them.",
                                onCancel: { confirmingDelete = nil },
                                onConfirm: { confirmingDelete = nil; onDelete(p) })
            }
        } else {
            Button { openID = p.id } label: {
                IKSRow(vertical: 10) {
                    IKDot(color: ProfileLookup.color(p, theme: theme), size: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(p.name).fontWeight(.semibold).lineLimit(1)
                            if p.favorite {
                                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(IK.orange)
                                    .accessibilityLabel("Favorite")
                            }
                            if p.isDefault {
                                Text("Default")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(theme.accentInk)
                                    .padding(.horizontal, 7).padding(.vertical, 1)
                                    .background(Capsule().fill(theme.accent.opacity(0.18)))
                            }
                            if p.parentOnly {
                                Text("PARENT")
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(0.3)
                                    .foregroundStyle(IK.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(IK.wash(0.10)))
                            }
                        }
                        Text(subtitle(p)).font(.system(size: 12.5)).foregroundStyle(IK.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IKChevron()
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !p.parentOnly {
                    Button { Task { await profiles.setDefault(p.isDefault ? nil : p.id) } } label: {
                        Label(p.isDefault ? "Clear Default" : "Make Default", systemImage: "pin")
                    }
                }
                Button { Task { await profiles.toggleFavorite(p.id) } } label: {
                    Label(p.favorite ? "Unfavorite" : "Favorite", systemImage: "star")
                }
                Button(role: .destructive) { confirmingDelete = p.id } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func subtitle(_ p: PsmithProfile) -> String {
        if p.parentOnly {
            let children = profiles.profiles.filter { $0.parentProfileID == p.id }.map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            guard !children.isEmpty else { return "Template" }
            let list = children.count == 1 ? children[0]
                : children.dropLast().joined(separator: ", ") + " and " + children.last!
            return "Template for \(list)"
        }
        let chain = ProfileLookup.ancestors(of: p.parentProfileID, in: profiles.profiles).map(\.name)
        return chain.isEmpty ? "Standalone" : ([p.name] + chain).joined(separator: " ‹ ")
    }
}
