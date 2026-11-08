import SwiftUI
import PsmithKit
import PsmithUI

/// A long reply read in full (board FullTextPage). The reader sets its own
/// type (16/23 body, 24 and 20.5 headings, 14 between blocks) rather than
/// the transcript's MarkdownUI theme, so a long document reads like a page.
/// Headings, paragraphs, lists and fenced code render here; anything else
/// (tables, quotes) falls back to the shared Markdown view.
struct FullTextScreen: View {
    let title: String
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let blocks = ReaderBlock.parse(markdown)
                ForEach(blocks.indices, id: \.self) { i in
                    ReaderBlockView(block: blocks[i])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.top, -2)
            .padding(.bottom, 34)
        }
        .environment(\.markdownTextSelectable, true)
        .environment(\.fontScale, 16.0 / 17.0)
        .ikConversationPage(title)
    }
}

enum ReaderBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String)
    case list(ordered: Bool, items: [String])
    case other(String)

    static func parse(_ md: String) -> [ReaderBlock] {
        var out: [ReaderBlock] = []
        var para: [String] = []
        var list: (ordered: Bool, items: [String])?
        var other: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if let l = list { out.append(.list(ordered: l.ordered, items: l.items)); list = nil }
            if !other.isEmpty { out.append(.other(other.joined(separator: "\n"))); other = [] }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil }
                else { c.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[h] == " ", line.distance(from: line.startIndex, to: h) <= 6 {
                flush()
                out.append(.heading(level: line.distance(from: line.startIndex, to: h),
                                    text: String(line[line.index(after: h)...])))
                continue
            }
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            let numbered = line.range(of: #"^\d+[.)] "#, options: .regularExpression)
            if bullet || numbered != nil {
                if !para.isEmpty || !other.isEmpty || (list != nil && list!.ordered != (numbered != nil)) { flush() }
                let item = bullet ? String(line.dropFirst(2)) : String(line[numbered!.upperBound...])
                if list == nil { list = (numbered != nil, []) }
                list!.items.append(item)
                continue
            }
            if line.hasPrefix(">") || line.hasPrefix("|") {
                if !para.isEmpty || list != nil { flush() }
                other.append(raw)
                continue
            }
            if list != nil, raw.hasPrefix("  "), let last = list!.items.indices.last {
                list!.items[last] += " " + line
                continue
            }
            if list != nil || !other.isEmpty { flush() }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}

/// One block at the board's sizes. CSS line height centres the glyphs,
/// so each line's extra leading is split above and below.
private struct ReaderBlockView: View {
    let block: ReaderBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let (size, lh): (CGFloat, CGFloat) = level == 1 ? (24, 30) : level == 2 ? (20.5, 26) : (17, 22)
            styled(text, size: size, weight: .semibold, lineHeight: lh)
                .padding(.top, level == 1 ? 0 : 4)
        case .paragraph(let text):
            styled(text, size: 16, lineHeight: 23)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 13.5, design: .monospaced))
                    .lineSpacing(19 - UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular).lineHeight)
                    .foregroundStyle(IK.strong)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10 + (19 - UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular).lineHeight) / 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.06)))
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(ordered ? "\(i + 1)." : "•").font(.system(size: 16)).foregroundStyle(IK.text)
                            .scaleEffect(ordered ? 1 : 1.4)
                            .frame(width: ordered ? 16 : 22, alignment: ordered ? .trailing : .center)
                            .padding(.trailing, ordered ? 6 : 0)
                        styled(items[i], size: 16, lineHeight: 23)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                }
            }
        case .other(let text):
            MarkdownText(text)
        }
    }

    private func styled(_ md: String, size: CGFloat, weight: Font.Weight = .regular, lineHeight: CGFloat) -> some View {
        let natural = UIFont.systemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular).lineHeight
        let attr = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
        return Text(attr)
            .font(.system(size: size, weight: weight))
            .lineSpacing(max(lineHeight - natural, 0))
            .foregroundStyle(IK.text)
            .padding(.vertical, max(lineHeight - natural, 0) / 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An attached image, full screen on black (board ImageViewer). Fit to
/// width; double-tap or pinch to zoom, drag down to close.
struct ImageViewerScreen: View {
    let model: ConversationViewModel
    let messageID: String
    let fileID: String
    let filename: String
    /// Snapshot tests hand the image in rather than fetching it.
    var preloaded: UIImage?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var drag: CGFloat = 0

    init(model: ConversationViewModel, messageID: String, fileID: String, filename: String, preloaded: UIImage? = nil) {
        self.model = model
        self.messageID = messageID
        self.fileID = fileID
        self.filename = filename
        self.preloaded = preloaded
        _image = State(initialValue: preloaded)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(max(0, 1 - abs(drag) / 400)).ignoresSafeArea()
            content
                .scaleEffect(scale * pinch)
                .offset(y: drag)
                .padding(.bottom, 18)
        }
        .ignoresSafeArea()
        .gesture(dismissDrag)
        .simultaneousGesture(MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { v in
                scale = min(max(scale * v.magnification, 1), 4)
                pinch = 1
            })
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(IK.text)
                }
                .accessibilityLabel("Close image")
            }
        }
        .accessibilityLabel(filename)
        .task(id: fileID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.18)) { scale = scale > 1 ? 1 : 2 }
                }
                .accessibilityLabel(filename)
        } else if failed {
            VStack(spacing: 10) {
                Image(systemName: "photo").font(.system(size: 36, weight: .light))
                Text(filename).font(.system(size: 13))
                Text("Couldn’t load the image").font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
            }
            .foregroundStyle(Color(white: 0.62))
        } else {
            ProgressView().tint(.white).controlSize(.large)
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard scale <= 1, v.translation.height > 0 else { return }
                drag = v.translation.height
            }
            .onEnded { v in
                guard scale <= 1 else { return }
                if v.translation.height > 120 { dismiss() } else {
                    withAnimation(.spring(duration: 0.25)) { drag = 0 }
                }
            }
    }

    private func load() async {
        guard image == nil else { return }
        do {
            let url = try await app.client.files.signedURL(fileID: fileID)
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) { image = img } else { failed = true }
        } catch {
            if !PsmithError.isCancellation(error) { failed = true }
        }
    }
}
