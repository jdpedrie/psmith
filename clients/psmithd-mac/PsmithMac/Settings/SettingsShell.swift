import SwiftUI
import AppKit

/// The Settings window's header: the pane's name, then a row of pane
/// tabs, drawn here rather than by an NSToolbar so it matches the boards
/// and renders the same in any window. The title bar above it is
/// transparent; the traffic lights sit over the header.
struct SettingsToolbar: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            Text(navigator.settingsCategory.label)
                .sk(13, weight: .semibold)
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            HStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { pane in
                    tab(pane)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
            // Below the tabs, not over them: the boards' border-bottom adds
            // a point to the header's height.
            Rectangle().fill(SK.line).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .background(SK.bar)
        .gesture(WindowDragGesture())
    }

    private func tab(_ pane: SettingsCategory) -> some View {
        let on = navigator.settingsCategory == pane
        return Button {
            navigator.settingsCategory = pane
        } label: {
            VStack(spacing: 4) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20, height: 20)
                Text(pane.label).sk(11, on ? .white : Color(hex: 0xB9C3CE))
            }
            .foregroundStyle(on ? .white : Color(hex: 0xB9C3CE))
            .frame(width: 74, height: 50)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white.opacity(0.1) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .keyboardShortcut(KeyEquivalent(Character("\(min(SettingsCategory.allCases.firstIndex(of: pane)! + 1, 9))")), modifiers: .command)
    }
}

/// Configures the hosting window the way the boards draw it: content
/// under a transparent title bar, dark, titled after the pane.
struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let title = title
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            // The boards are dark only; light mode isn't designed yet.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(SK.window)
            window.title = title
        }
    }
}

/// A pane that lists records on the left and shows the selected one on
/// the right, with an optional bar pinned under the detail.
struct SKSplit<Side: View, Detail: View, Bottom: View>: View {
    var sideWidth: CGFloat = 230
    /// false when the detail is an SKDetailPage with its own scroll and bar.
    var scrollsDetail = true
    @ViewBuilder var side: Side
    @ViewBuilder var detail: Detail
    @ViewBuilder var bottom: Bottom

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { side }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            .frame(width: sideWidth)
            .background(SK.side)
            .overlay(alignment: .trailing) { Rectangle().fill(SK.line).frame(width: 1) }
            if !scrollsDetail {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            VStack(spacing: 0) {
                ScrollView {
                    // Past the boards' width the detail stops growing and
                    // stays beside the list ("Wide windows keep their measure").
                    VStack(alignment: .leading, spacing: 0) { detail }
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                bottom
            }
            }
        }
    }
}

extension SKSplit where Bottom == EmptyView {
    init(sideWidth: CGFloat = 230, scrollsDetail: Bool = true, @ViewBuilder side: () -> Side, @ViewBuilder detail: () -> Detail) {
        self.sideWidth = sideWidth
        self.scrollsDetail = scrollsDetail
        self.side = side()
        self.detail = detail()
        self.bottom = EmptyView()
    }
}

// MARK: - List column parts

struct SKListHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .sk(11, SK.tertiary, weight: .semibold)
            .padding(.top, 10)
            .padding(.bottom, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SKListItem<Lead: View, Trail: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var muted = false
    let action: () -> Void
    @ViewBuilder var lead: Lead
    @ViewBuilder var trail: Trail

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                lead
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).sk(13, selected ? .white : (muted ? SK.secondary : SK.text)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).sk(11, selected ? Color.white.opacity(0.75) : SK.tertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trail
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? SK.selection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The last row of a list: adds a record.
struct SKAddItem: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(SK.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 16, height: 16)
                Text(title).sk(13, selected ? .white : SK.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? SK.selection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// A list pane's detail that scrolls on its own and pins a bar under it:
/// for pages whose save bar belongs to the page, not the pane.
struct SKDetailPage<Content: View, Bottom: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottom
        }
    }
}

extension SKDetailPage where Bottom == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.bottom = EmptyView()
    }
}

/// Underlined section tabs under a page head.
struct SKSubtabs<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .sk(13, on ? .white : SK.secondary)
                        .padding(.horizontal, 2)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            if on { Rectangle().fill(SK.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(SK.line).frame(height: 1) }
        .padding(.bottom, 18)
    }
}

/// "‹ Anthropic › Claude Opus 4.7": every part but the last goes back.
struct SKBreadcrumb: View {
    let parts: [(String, () -> Void)]
    let current: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("›").sk(12.5, SK.tertiary) }
                Button(action: part.1) {
                    HStack(spacing: 3) {
                        if i == 0 { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                        Text(part.0).sk(12.5, SK.link)
                    }
                    .foregroundStyle(SK.link)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(i == parts.count - 1 ? KeyboardShortcut("[", modifiers: .command) : nil)
            }
            Text("›").sk(12.5, SK.tertiary)
            Text(current).sk(12.5, SK.secondary)
        }
        .padding(.bottom, 10)
        .onExitCommand { parts.last?.1() }
    }
}

/// The boards' search field at the top of a list or table.
struct SKSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SK.tertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty { Text(placeholder).sk(12.5, SK.tertiary).allowsHitTesting(false) }
                TextField("", text: $text).textFieldStyle(.plain).scaledFont(size: 12.5).foregroundStyle(SK.text)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .accessibilityLabel(placeholder)
    }
}
