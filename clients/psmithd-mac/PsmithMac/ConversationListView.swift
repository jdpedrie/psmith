import SwiftUI
import PsmithKit
import PsmithUI

/// The conversation list's content: offline note, search, filter chips,
/// then the date-grouped rows (or search results, or the archive). Drawn
/// to the main-window boards (AppConversation, AppList*): no system list,
/// so a row measures what the board says. Rename and delete happen in the
/// row; nothing opens a dialog.
struct ConversationListView: View {
    @Environment(ConversationsModel.self) private var convos
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Binding var showingArchived: Bool

    @State private var searchText = ""
    @State private var filter: SidebarFilter = .all
    @State private var renamingID: String?
    @State private var renameDraft = ""
    @State private var deletingID: String?
    @State private var lastClick: (id: String, at: Date)?
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if showingArchived {
                            archivedContent
                        } else if isSearching {
                            searchContent
                        } else {
                            groupedContent
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .scrollEdgeEffectHidden(true, for: .top)
                .overlay { emptyState }
            }
            // Focusable as a whole, so clicking a row hands the arrow keys
            // to the list; the key handlers sit on the focused view.
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.downArrow) { move(1, proxy) }
        }
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                guard convos.listMode != .allChats else { return }
                convos.listMode = .allChats
                convos.searchQuery = ""
                await convos.refresh()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            convos.listMode = .search
            convos.searchQuery = query
            await convos.refresh()
        }
        .task(id: showingArchived) {
            if showingArchived { await convos.loadArchived() }
        }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.connectivity.state == .offline {
                HStack(spacing: 7) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 11, weight: .medium))
                    Text(convos.conversations.isEmpty ? "Offline." : "Offline. Showing saved conversations.")
                        .sk(12, SK.orange).skOneLine(12)
                }
                .foregroundStyle(SK.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(SK.orange.opacity(0.12)))
                .padding(.bottom, 8)
            }
            if showingArchived {
                archiveHeader
            } else {
                MKSearchField(text: $searchText)
                if !isSearching {
                    filterBar.padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        @Bindable var convos = convos
        let pickable = convos.profiles.filter { !$0.parentOnly }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let profileOn: Bool = { if case .profile = filter { return true }; return false }()
        return HStack(spacing: 6) {
            Button("All") { filter = .all }.buttonStyle(MKChipStyle(on: filter == .all))
            Button("Pinned") { filter = .pinned }.buttonStyle(MKChipStyle(on: filter == .pinned))
            Menu {
                ForEach(pickable) { p in
                    Button(p.name) { filter = .profile(p.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(profileFilterTitle(pickable))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .modifier(MKChipLook(on: profileOn))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
            Menu {
                Picker("Sort By", selection: Binding(
                    get: { convos.listOrder },
                    set: { order in
                        convos.listOrder = order
                        Task { await convos.refresh() }
                    }
                )) {
                    Text("Last Activity").tag(PsmithConversationOrder.recentlyUsed)
                    Text("Date Created").tag(PsmithConversationOrder.recentlyCreated)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SK.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort conversations")
        }
    }

    private func profileFilterTitle(_ profiles: [PsmithProfile]) -> String {
        if case .profile(let id) = filter, let p = profiles.first(where: { $0.id == id }) {
            return p.name
        }
        return "Profile"
    }

    private var archiveHeader: some View {
        HStack(spacing: 0) {
            Button {
                showingArchived = false
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold))
                    Text("Conversations")
                }
            }
            .skButton(.plain)
            Text("Archived").sk(13, weight: .semibold).frame(maxWidth: .infinity).padding(.trailing, 88)
        }
    }

    // MARK: Content

    private var visible: [PsmithConversation] {
        switch filter {
        case .all: return convos.conversations
        case .pinned: return convos.conversations.filter { $0.pinnedAt != nil }
        case .profile(let id): return convos.conversations.filter { $0.profileID == id }
        }
    }

    /// Rows in display order, for the arrow keys.
    private var ordered: [PsmithConversation] {
        if showingArchived { return convos.archivedConversations }
        if isSearching { return convos.conversations }
        return SidebarSections.group(visible, by: convos.listOrder, now: Date()).flatMap(\.conversations)
    }

    @ViewBuilder
    private var groupedContent: some View {
        let sections = SidebarSections.group(visible, by: convos.listOrder, now: Date())
        ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
            MKSectionLabel(text: section.title, first: i == 0)
            ForEach(section.conversations) { row($0) }
        }
        LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
            .padding(.vertical, 8)
        if !sections.isEmpty {
            Button {
                showingArchived = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox").font(.system(size: 11.5)).frame(width: 10)
                    Text("Archived").sk(13, SK.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SK.secondary)
            .padding(.top, 6)
            .help("Browse archived conversations")
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        MKSectionLabel(text: "Titles matching “\(searchText.trimmingCharacters(in: .whitespaces))”", first: true)
        ForEach(convos.conversations) { row($0) }
        LoadMoreFooter(token: convos.nextPageToken) { await convos.loadMore() }
    }

    @ViewBuilder
    private var archivedContent: some View {
        MKSectionLabel(text: "Archived", first: true)
        ForEach(convos.archivedConversations) { c in
            if deletingID == c.id {
                deleteCard(c)
            } else {
                rowView(c, generating: false, unseen: false, muted: true)
                    .contextMenu { archivedRowActions(c) }
                    // Context menus aren't reachable through accessibility;
                    // the same actions are, for VoiceOver and the keyboard.
                    .accessibilityActions { archivedRowActions(c) }
            }
        }
        LoadMoreFooter(token: convos.archivedNextPageToken) { await convos.loadMoreArchived() }
    }

    @ViewBuilder
    private func row(_ c: PsmithConversation) -> some View {
        if renamingID == c.id {
            renameRow(c)
        } else if deletingID == c.id {
            deleteCard(c)
        } else {
            rowView(c,
                    generating: app.streamHub.activeConversationIDs.contains(c.id),
                    unseen: app.streamHub.unseenConversationIDs.contains(c.id))
                .contextMenu { rowActions(c) }
                .accessibilityActions { rowActions(c) }
        }
    }

    @ViewBuilder
    private func rowActions(_ c: PsmithConversation) -> some View {
        Button(c.pinnedAt == nil ? "Pin" : "Unpin") { Task { await convos.togglePin(c.id) } }
        Button("Rename") { startRename(c) }
        Button("Archive") { Task { await convos.archive(c.id) } }
        Divider()
        Button("Delete…", role: .destructive) { deletingID = c.id }
    }

    @ViewBuilder
    private func archivedRowActions(_ c: PsmithConversation) -> some View {
        Button("Unarchive") { Task { await convos.unarchive(c.id) } }
        Divider()
        Button("Delete…", role: .destructive) { deletingID = c.id }
    }

    private func rowView(_ c: PsmithConversation, generating: Bool, unseen: Bool, muted: Bool = false) -> some View {
        // A button, not a tap gesture: inside the scroll view a gesture
        // never saw the click. A second click on the same row within the
        // system's double-click interval renames it; by the time a button's
        // action runs, NSApp.currentEvent no longer has the click count.
        Button {
            let now = Date()
            if let last = lastClick, last.id == c.id, now.timeIntervalSince(last.at) < NSEvent.doubleClickInterval, !showingArchived {
                lastClick = nil
                startRename(c)
            } else {
                lastClick = (c.id, now)
                convos.selectedID = c.id
                listFocused = true
            }
        } label: {
            SidebarRow(
                conversation: c,
                profile: convos.profiles.first { $0.id == c.profileID },
                isGenerating: generating,
                isUnseen: unseen,
                order: convos.listOrder,
                selected: convos.selectedID == c.id,
                muted: muted
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(c.id)
    }

    private func startRename(_ c: PsmithConversation) {
        deletingID = nil
        renameDraft = c.title ?? ""
        renamingID = c.id
    }

    private func renameRow(_ c: PsmithConversation) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: 10, height: 1)
            VStack(alignment: .leading, spacing: 3) {
                MKRenameField(text: $renameDraft) {
                    let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, title != c.title { Task { await convos.rename(id: c.id, title: title) } }
                    renamingID = nil
                } onCancel: {
                    renamingID = nil
                }
                Text("Return to rename · Escape to cancel").sk(11, SK.secondary).skOneLine(11)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.highlight))
    }

    private func deleteCard(_ c: PsmithConversation) -> some View {
        let title = (c.title?.isEmpty == false) ? c.title! : "Untitled"
        let fromArchive = showingArchived
        return MKConfirmCard(question: "Delete “\(title)”?", detail: "Every message goes. This can’t be undone.", confirmLabel: "Delete") {
            deletingID = nil
        } onConfirm: {
            deletingID = nil
            Task { if fromArchive { await convos.deleteArchived(c.id) } else { await convos.delete(c.id) } }
        }
        .padding(.vertical, 2)
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = ordered
        guard !rows.isEmpty, renamingID == nil else { return .ignored }
        let i = rows.firstIndex { $0.id == convos.selectedID }
        let next = i.map { min(max($0 + by, 0), rows.count - 1) } ?? (by > 0 ? 0 : rows.count - 1)
        convos.selectedID = rows[next].id
        proxy.scrollTo(rows[next].id)
        return .handled
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if let err = convos.loadError, convos.conversations.isEmpty {
            MKEmptyList(systemImage: "exclamationmark.triangle", title: "Couldn’t load", detail: err) {
                Button("Try Again") { Task { await convos.refresh() } }.skButton(small: true)
            }
        } else if convos.isLoading && convos.conversations.isEmpty && !showingArchived {
            VStack { MKSpinner(size: 16).padding(.top, 60); Spacer() }
        } else if showingArchived, convos.archivedConversations.isEmpty, !convos.archivedLoading {
            MKEmptyList(systemImage: "archivebox", title: "Nothing archived", detail: "Archived conversations show here.")
        } else if !showingArchived, isSearching, convos.conversations.isEmpty, !convos.isLoading {
            MKEmptyList(systemImage: "magnifyingglass", title: "No titles match “\(searchText.trimmingCharacters(in: .whitespaces))”", detail: "Search looks at titles only.", top: 40)
        } else if !showingArchived, !isSearching, visible.isEmpty, !convos.isLoading {
            if app.connectivity.state == .offline {
                MKEmptyList(systemImage: "wifi.exclamationmark", title: "Can’t reach the server", detail: "No saved conversations to show.")
            } else if filter != .all {
                MKEmptyList(systemImage: "line.3.horizontal.decrease", title: "No matches", detail: "No conversations fit this filter.")
            } else if !convos.archivedConversations.isEmpty {
                // Board AppListEmptyArchive: the filters (and the Archived
                // row under them) only draw with rows, so the way in is here.
                MKEmptyList(systemImage: "bubble.left.and.bubble.right", title: "No active conversations", detail: "Start one with ⌘N.") {
                    Button { showingArchived = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox").font(.system(size: 11))
                            Text("Archived")
                            Text("\(convos.archivedConversations.count)\(convos.archivedNextPageToken != nil ? "+" : "")")
                                .foregroundStyle(SK.secondary)
                        }
                    }
                    .skButton(small: true)
                    .accessibilityLabel("Archived, \(convos.archivedConversations.count)\(convos.archivedNextPageToken != nil ? " or more" : "")")
                }
            } else {
                MKEmptyList(systemImage: "bubble.left.and.bubble.right", title: "No conversations yet", detail: "Start one with ⌘N.")
                    // The count needs the archive; it isn't loaded until asked for.
                    .task { await convos.loadArchived() }
            }
        }
    }
}

// MARK: - Parts

enum SidebarFilter: Equatable {
    case all
    case pinned
    case profile(String)
}

typealias SidebarSections = ConversationSections

/// One conversation: unread dot in a fixed gutter, title and time, the
/// profile under it. 46pt tall; the selected row takes the theme's
/// highlight.
struct SidebarRow: View {
    let conversation: PsmithConversation
    let profile: PsmithProfile?
    let isGenerating: Bool
    let isUnseen: Bool
    let order: PsmithConversationOrder
    var selected = false
    var muted = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack {
                if isUnseen {
                    Circle().fill(theme.accent).frame(width: 8, height: 8)
                        .accessibilityLabel("Unread reply")
                }
            }
            .frame(width: 10, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .sk(13, muted ? SK.secondary : SK.text, weight: isUnseen ? .semibold : .medium)
                        .skOneLine(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isGenerating {
                        HStack(spacing: 5) {
                            Circle().fill(theme.accentInk).frame(width: 6, height: 6)
                            Text("Replying").sk(11, theme.accentInk).skOneLine(11)
                        }
                        .fixedSize()
                    } else {
                        Text(stamp).sk(11, selected ? SK.secondary : SK.tertiary).monospacedDigit().skOneLine(11).fixedSize()
                    }
                }
                if let profile {
                    Text(profile.name).sk(12, SK.secondary).skOneLine(12)
                }
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 7)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.highlight : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var title: String {
        let t = conversation.title ?? ""
        return t.isEmpty ? "Untitled" : t
    }

    private var stamp: String {
        let d = SidebarSections.date(of: conversation, by: order)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct MKSectionLabel: View {
    let text: String
    var first = false
    var body: some View {
        Text(text).sk(11, SK.tertiary, weight: .semibold).skOneLine(11)
            .padding(.top, first ? 8 : 14)
            .padding(.bottom, 4)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A 22pt filter chip: the accent when on.
struct MKChipLook: ViewModifier {
    let on: Bool
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .sk(12, on ? .white : SK.text, weight: on ? .semibold : nil)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(on ? theme.accent : Color.white.opacity(0.07)))
            .contentShape(Capsule())
    }
}

struct MKChipStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MKChipLook(on: on)).opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The list's search: the Settings search field, with a clear button and
/// the accent ring while focused. Escape clears it.
struct MKSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SK.tertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty { Text("Search").sk(12.5, SK.tertiary).allowsHitTesting(false) }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 12.5)
                    .foregroundStyle(SK.text)
                    .focused($focused)
                    .onKeyPress(.escape) {
                        text = ""
                        focused = false
                        return .handled
                    }
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SK.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
        .accessibilityLabel("Search conversations")
    }
}

/// The title field a row turns into while renaming. Takes focus on
/// appear; Return commits, Escape and losing focus cancel.
struct MKRenameField: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .scaledFont(size: 13)
            .foregroundStyle(SK.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.fieldRing, lineWidth: 0.5))
            .focused($focused)
            .onSubmit(onCommit)
            .onKeyPress(.escape) { onCancel(); return .handled }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in if !now { onCancel() } }
            .accessibilityLabel("Title")
    }
}

/// An empty list: icon, title, a line of detail, maybe a button.
struct MKEmptyList<Action: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    var top: CGFloat = 60
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage).font(.system(size: 24, weight: .light)).foregroundStyle(SK.tertiary).frame(height: 30)
            Text(title).sk(13, SK.secondary, weight: .semibold).multilineTextAlignment(.center).padding(.top, 10)
            Text(detail).sk(12, SK.tertiary).multilineTextAlignment(.center).padding(.top, 4)
            action.padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.top, top)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

extension MKEmptyList where Action == EmptyView {
    init(systemImage: String, title: String, detail: String, top: CGFloat = 60) {
        self.init(systemImage: systemImage, title: title, detail: detail, top: top) { EmptyView() }
    }
}
