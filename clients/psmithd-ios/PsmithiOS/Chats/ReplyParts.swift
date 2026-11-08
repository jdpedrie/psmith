import SwiftUI
import PsmithKit
import PsmithUI

// The pills above a reply (thinking, tools), the reply while it streams,
// and the compression summary in the transcript. Boards Conversation,
// Thinking, Streaming, MessageUsage, Elicit, SystemStrip, Review,
// ReviewTruncated, Compacting, CompressFailed.

// MARK: - Pills

/// A thinking or tool pill. `running` swaps the icon for a spinner.
struct ReplyPill: View {
    let systemImage: String
    let label: String
    var color: Color = IK.secondary
    var running = false
    var pulsing = false
    var chevron: IKPillChevron = .none
    @State private var dim = false

    var body: some View {
        HStack(spacing: 6) {
            if running {
                IKSpinner()
            } else {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
            }
            Text(label).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
            switch chevron {
            case .none: EmptyView()
            case .closed: Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(IK.tertiary)
            case .open: Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(IK.tertiary)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(IK.wash(0.05)))
        .overlay(Capsule().strokeBorder(IK.ring(0.08), lineWidth: 0.5))
        .opacity(pulsing && dim ? 0.55 : 1)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// The left-ruled block a pill opens into.
struct PillDisclosure<Content: View>: View {
    var maxHeight: CGFloat = 260
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(IK.wash(0.18)).frame(width: 3)
            }
    }
}

/// INPUT / OUTPUT / ERROR sections of a tool call.
struct ToolCallDetail: View {
    let input: String
    let output: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            caps("INPUT")
            mono(input, wraps: false)
            if let error {
                caps("ERROR", color: IK.orange).padding(.top, 4)
                mono(error, color: IK.orange, wraps: true)
            } else if let output {
                caps("OUTPUT").padding(.top, 4)
                mono(output, wraps: false)
            }
        }
    }

    private func caps(_ s: String, color: Color = IK.tertiary) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(color)
    }

    /// JSON keeps its lines, clipped at the edge like code; an error
    /// message wraps.
    @ViewBuilder
    private func mono(_ s: String, color: Color = IK.secondary, wraps: Bool) -> some View {
        let text = Text(s).cssLines(size: 12.5, lineHeight: 18).fontDesign(.monospaced).foregroundStyle(color)
            .textSelection(.enabled)
        if wraps {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            UnwrappedLines { text.fixedSize() }.clipped()
        }
    }

    /// A short flat object stays on one line, the way people write it;
    /// anything bigger is indented.
    static func pretty(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return String(data: data, encoding: .utf8) ?? "(\(data.count) bytes)"
        }
        if let dict = obj as? [String: Any], dict.values.allSatisfy({ !($0 is [Any]) && !($0 is [String: Any]) }) {
            let parts = dict.keys.sorted().compactMap { k -> String? in
                guard let v = try? JSONSerialization.data(withJSONObject: dict[k]!, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                      let vs = String(data: v, encoding: .utf8) else { return nil }
                return "\"\(k)\": \(vs)"
            }
            let line = "{ " + parts.joined(separator: ", ") + " }"
            if line.count <= 44 { return line }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8) else { return "(\(data.count) bytes)" }
        return s.replacingOccurrences(of: "\" : ", with: "\": ")
    }
}

enum PillText {
    static func seconds(_ s: Double) -> String { String(format: "%.1fs", max(0, s)) }

    static func done(_ name: String, seconds: Double?, failed: Bool) -> String {
        let dur = seconds.flatMap { $0 > 0 ? " (\(self.seconds($0)))" : nil } ?? ""
        return failed ? "\(name) failed\(dur)" : "Used \(name)\(dur)"
    }
}

/// A settled reply's pills: thinking first, then each tool call. Side by
/// side while closed; an opened one drops its detail under itself.
struct ReplyPills: View {
    let message: PsmithMessage
    let model: ConversationViewModel

    private var hasThinking: Bool {
        if let t = message.thinkingRenderedText, !t.isEmpty { return true }
        if let ms = message.thinkingDurationMs, ms > 0 { return true }
        return false
    }

    private var thinkingOpen: Bool { model.expandedThinkingMessageIDs.contains(message.id) }
    private func toolKey(_ i: Int) -> String { "\(message.id):\(i)" }
    private var anyOpen: Bool {
        thinkingOpen || message.toolCalls.indices.contains { model.expandedToolCallKeys.contains(toolKey($0)) }
    }

    var body: some View {
        if message.role == .assistant, hasThinking || !message.toolCalls.isEmpty {
            if anyOpen {
                VStack(alignment: .leading, spacing: 10) {
                    if hasThinking {
                        thinkingPill
                        if thinkingOpen, let t = message.thinkingRenderedText, !t.isEmpty {
                            PillDisclosure(maxHeight: 220) {
                                Text(t).cssLines(size: 14, lineHeight: 20).foregroundStyle(IK.secondary)
                            }
                        }
                    }
                    ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { i, call in
                        toolPill(call, index: i)
                        if model.expandedToolCallKeys.contains(toolKey(i)) {
                            PillDisclosure {
                                ToolCallDetail(input: ToolCallDetail.pretty(call.input),
                                               output: ToolCallDetail.pretty(call.output), error: call.error)
                            }
                        }
                    }
                }
            } else {
                FlowRow(spacing: 8) {
                    if hasThinking { thinkingPill }
                    ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { i, call in toolPill(call, index: i) }
                }
            }
        }
    }

    private var thinkingPill: some View {
        let ms = message.thinkingDurationMs ?? 0
        let label = ms > 0 ? "Thought for \(PillText.seconds(Double(ms) / 1000))" : "Thought"
        let expandable = !(message.thinkingRenderedText ?? "").isEmpty
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if thinkingOpen { model.expandedThinkingMessageIDs.remove(message.id) } else { model.expandedThinkingMessageIDs.insert(message.id) }
            }
        } label: {
            ReplyPill(systemImage: "brain", label: label, chevron: expandable ? (thinkingOpen ? .open : .closed) : .none)
        }
        .buttonStyle(.plain)
        .disabled(!expandable)
    }

    private func toolPill(_ call: PsmithToolCall, index: Int) -> some View {
        let open = model.expandedToolCallKeys.contains(toolKey(index))
        let failed = call.error != nil
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if open { model.expandedToolCallKeys.remove(toolKey(index)) } else { model.expandedToolCallKeys.insert(toolKey(index)) }
            }
        } label: {
            ReplyPill(systemImage: failed ? "exclamationmark.triangle" : "checkmark",
                      label: PillText.done(call.name, seconds: Double(call.elapsedMs) / 1000, failed: failed),
                      color: failed ? IK.orange : (open ? IK.strong : IK.secondary),
                      chevron: open ? .open : .closed)
        }
        .buttonStyle(.plain)
    }
}

/// Lays children left to right, wrapping to a new line when full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Streaming

/// The reply while it streams: a ticking thinking pill, live tool pills
/// and the text so far (Streaming, Thinking, Elicit).
struct StreamingReply: View {
    let model: ConversationViewModel
    /// The tool waiting on an answer from the user, if one is.
    var waitingOnInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let calls = model.streamingToolCalls
            if model.streamingThinkingStartedAt != nil || !calls.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FlowRow(spacing: 8) {
                        if let started = model.streamingThinkingStartedAt { thinkingPill(started) }
                        ForEach(calls) { call in livePill(call) }
                    }
                    if model.streamingThinkingExpanded, !model.streamingThinking.isEmpty {
                        PillDisclosure(maxHeight: 220) {
                            Text(model.streamingThinking).cssLines(size: 14, lineHeight: 20).foregroundStyle(IK.secondary)
                        }
                    }
                    ForEach(calls.filter { model.expandedLiveToolCallIDs.contains($0.id) }) { call in
                        PillDisclosure {
                            ToolCallDetail(input: call.input.isEmpty ? "(streaming)" : call.input,
                                           output: call.output.map(ToolCallDetail.pretty), error: call.error)
                        }
                    }
                }
            }
            let text = model.streamingText
            if text.isEmpty {
                if model.streamingThinkingStartedAt == nil && calls.isEmpty || model.streamingThinkingFinishedAt == nil && model.streamingThinkingStartedAt != nil {
                    Text("…").font(.system(size: 16)).foregroundStyle(IK.secondary)
                }
            } else {
                StreamingText(text: text, components: model.conversation.streamingComponents)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thinkingPill(_ started: Date) -> some View {
        let open = model.streamingThinkingExpanded
        let expandable = !model.streamingThinking.isEmpty
        Button {
            withAnimation(.snappy(duration: 0.2)) { model.streamingThinkingExpanded.toggle() }
        } label: {
            if let finished = model.streamingThinkingFinishedAt {
                ReplyPill(systemImage: "brain", label: "Thought for \(PillText.seconds(finished.timeIntervalSince(started)))",
                          chevron: expandable ? (open ? .open : .closed) : .none)
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    ReplyPill(systemImage: "brain",
                              label: "Thinking… (\(PillText.seconds(ctx.date.timeIntervalSince(started))))",
                              color: IK.strong, pulsing: true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!expandable)
    }

    @ViewBuilder
    private func livePill(_ call: LiveToolCall) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if model.expandedLiveToolCallIDs.contains(call.id) { model.expandedLiveToolCallIDs.remove(call.id) } else { model.expandedLiveToolCallIDs.insert(call.id) }
            }
        } label: {
            switch call.phase {
            case .generating(let since):
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    ReplyPill(systemImage: "wrench.and.screwdriver",
                              label: "Using \(call.name) (\(PillText.seconds(ctx.date.timeIntervalSince(since))))",
                              color: IK.strong, running: true)
                }
            case .executing(let since):
                if waitingOnInput {
                    ReplyPill(systemImage: "hourglass", label: "Waiting on \(call.name)", color: IK.strong, running: true)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        ReplyPill(systemImage: "gearshape.2",
                                  label: "Processing \(call.name) (\(PillText.seconds(ctx.date.timeIntervalSince(since))))",
                                  color: IK.strong, running: true)
                    }
                }
            case .done(let dur, let failed):
                ReplyPill(systemImage: failed ? "exclamationmark.triangle" : "checkmark",
                          label: PillText.done(call.name, seconds: dur, failed: failed),
                          color: failed ? IK.orange : IK.secondary,
                          chevron: model.expandedLiveToolCallIDs.contains(call.id) ? .open : .closed)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Streamed text, with any server fragments the profile streams inline
/// rendered as they close.
struct StreamingText: View {
    let text: String
    let components: [PsmithStreamingComponentTag]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(StreamingSegments.parse(text, components: components).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let s):
                    if ProseText.isPlain(s) { ProseText(text: s) } else { ChunkedMarkdownText(s) }
                case .fragment(let f): FragmentView(fragments: [f], onAction: { _ in })
                case .pending: Text("…").foregroundStyle(IK.secondary)
                }
            }
        }
        .environment(\.fontScale, 16.0 / 17)
        .lineSpacing(23 - 19.09)
        .environment(\.markdownTextSelectable, false)
        .foregroundStyle(IK.text)
    }
}

/// Splits streamed text at the profile's streaming component tags:
/// prose stays markdown, a closed `<tag>{json}</tag>` becomes a
/// fragment, an unclosed one waits as an ellipsis.
enum StreamingSegments {
    enum Segment { case text(String), fragment(PsmithUIFragment), pending }

    static func parse(_ text: String, components: [PsmithStreamingComponentTag]) -> [Segment] {
        guard !components.isEmpty else { return [.text(text)] }
        var byTag: [String: String] = [:]
        for c in components { byTag[c.tag] = c.component }
        var out: [Segment] = []
        var prose = ""
        var i = text.startIndex
        func flush() { if !prose.isEmpty { out.append(.text(prose)); prose = "" } }
        while i < text.endIndex {
            guard let lt = text[i...].firstIndex(of: "<") else { prose += text[i...]; break }
            prose += text[i..<lt]
            let afterLT = text.index(after: lt)
            guard let gt = text[afterLT...].firstIndex(of: ">") else { flush(); out.append(.pending); return out }
            let tag = String(text[afterLT..<gt])
            guard let component = byTag[tag] else {
                prose += text[lt..<text.index(after: gt)]
                i = text.index(after: gt)
                continue
            }
            let bodyStart = text.index(after: gt)
            guard let close = text.range(of: "</\(tag)>", range: bodyStart..<text.endIndex) else {
                flush(); out.append(.pending); return out
            }
            let raw = String(text[bodyStart..<close.lowerBound])
            if component == "text" { prose += raw; i = close.upperBound; continue }
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
                flush()
                out.append(.fragment(PsmithUIFragment(component: component, props: data, key: "")))
            } else {
                flush(); out.append(.pending)
            }
            i = close.upperBound
        }
        flush()
        return out
    }
}

// MARK: - Compression summary

/// The compression summary in the transcript. Pending review it shows in
/// full with a link to the whole text; once settled it folds to a
/// faded preview. A failed one says why and offers Retry.
struct SummaryCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @Environment(\.openConversationPage) private var open
    @Environment(\.theme) private var theme
    @State private var showPartial = false

    static let previewLimit = 1_500

    private var failed: Bool { message.errorText != nil }
    private var pending: Bool { model.pendingCompressionSummary?.id == message.id }
    private var modelName: String? { model.modelDisplayName(providerID: message.providerID, modelID: message.modelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "rectangle.expand.vertical").font(.system(size: 12))
                Text(failed ? "Compression failed" : "Compression summary").font(.system(size: pending || failed ? 13 : 12.5, weight: .semibold))
                Spacer(minLength: 0)
                if !failed && message.isTruncatedOutput {
                    Label("Truncated", systemImage: "scissors").font(.system(size: 12, weight: .semibold)).foregroundStyle(IK.red)
                        .labelStyle(TightLabel())
                }
                if let modelName { Text(modelName).font(.system(size: 12)).foregroundStyle(IK.tertiary).lineLimit(1) }
            }
            .foregroundStyle(IK.orange)
            if failed { failedBody } else { summaryBody }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.orange.opacity(failed ? 0.55 : (pending ? 0.4 : 0.35)), lineWidth: 1.5))
    }

    private var text: String { message.displayContent ?? message.content }

    @ViewBuilder
    private var summaryBody: some View {
        if pending {
            let head = MarkdownBudget.head(text, limit: Self.previewLimit)
            SummaryProse(text: head ?? text, cacheKey: MessageRow.markdownKey(id: message.id, body: text) + ":summary")
                .lineSpacing(21 - 17.9)
                .environment(\.markdownTextSelectable, false)
                .padding(.top, 8)
            Button {
                open(.fullText(title: "Compression summary", markdown: text))
            } label: {
                Text("Show full text (\(UsageFormat.bytes(text.utf8.count)))").font(.system(size: 14)).foregroundStyle(theme.accentInk)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
        } else {
            SummaryProse(text: MarkdownBudget.head(text, limit: Self.previewLimit) ?? text, cacheKey: nil)
                .lineSpacing(21 - 17.9)
                .environment(\.markdownTextSelectable, false)
                .frame(maxHeight: 132, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [fadeGround.opacity(0), fadeGround], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                        .allowsHitTesting(false)
                }
                .padding(.top, 8)
            FullTextButton(size: text.utf8.count) {
                open(.fullText(title: "Compression summary", markdown: text))
            }
            .padding(.top, 8)
        }
        if message.isTruncatedOutput {
            Text("Cut off at the model’s output limit. The tail of the summary is missing.")
                .cssLines(size: 13, lineHeight: 18).foregroundStyle(IK.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        if let u = message.usage, let line = UsageFormat.line(u) {
            Text(line).font(.system(size: 12)).monospacedDigit().foregroundStyle(IK.tertiary).lineLimit(1)
                .padding(.top, 4)
        }
    }

    /// The card's own ground under the fade: chrome under the orange wash.
    private var fadeGround: Color { theme.chrome.ikBlend(dark: (IK.orange, 0.08), light: (IK.orange, 0.08)) }

    @ViewBuilder
    private var failedBody: some View {
        if let err = message.errorText, !err.isEmpty {
            Text(err).cssLines(size: 15, lineHeight: 21).foregroundStyle(IK.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        if !text.isEmpty {
            Button { withAnimation(.snappy(duration: 0.2)) { showPartial.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showPartial ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold))
                    Text("Partial summary streamed before failure").font(.system(size: 13.5))
                }
                .foregroundStyle(IK.secondary)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
            if showPartial {
                ChunkedMarkdownText(text).environment(\.fontScale, 15.0 / 17)
                .lineSpacing(21 - 17.9).foregroundStyle(IK.secondary)
            }
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button { Task { await model.deleteMessage(id: message.id) } } label: {
                Text("Dismiss").font(.system(size: 15)).foregroundStyle(IK.secondary)
                    .padding(.horizontal, 14).frame(height: 36).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                Task { await model.compact() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise").labelStyle(TightLabel())
            }
            .ikButton(.primary)
            .disabled(model.isCompacting || model.sending || model.isStreaming)
        }
        .padding(.top, 4)
    }
}

/// The summary arriving: what has streamed so far under COMPACTING
/// (Compacting).
struct CompactingCard: View {
    let model: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.expand.vertical").font(.system(size: 12))
                Text("COMPACTING").font(.system(size: 11.5, weight: .semibold)).tracking(0.3)
                IKSpinner(color: IK.orange)
                Spacer(minLength: 0)
                if let name = model.modelDisplayName(providerID: model.compactProviderID, modelID: model.compactModelID) {
                    Text(name).font(.system(size: 12)).foregroundStyle(IK.tertiary).lineLimit(1)
                }
            }
            .foregroundStyle(IK.orange)
            if !model.streamingText.isEmpty {
                SummaryProse(text: model.streamingText, cacheKey: nil)
                .lineSpacing(21 - 17.9)
                    .environment(\.markdownTextSelectable, false)
                    .foregroundStyle(IK.strong)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.orange.opacity(0.3), lineWidth: 1))
    }
}

/// Icon and title 4pt apart, the boards' inline labels.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

/// A summary's 15pt text: board-exact prose when it's plain, markdown
/// otherwise.
struct SummaryProse: View {
    let text: String
    let cacheKey: String?
    var body: some View {
        if ProseText.isPlain(text) {
            ProseText(text: text, size: 15, lineHeight: 21, gap: 8)
        } else {
            Group {
                if let cacheKey { ChunkedMarkdownText(text, cacheKey: cacheKey) } else { ChunkedMarkdownText(text) }
            }
            .environment(\.fontScale, 15.0 / 17)
            .lineSpacing(21 - 17.9)
        }
    }
}

/// Lays its child out at its natural width but takes only the width it
/// is offered, so long lines run past the edge to be clipped instead of
/// widening the row.
struct UnwrappedLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width.map { min($0, ideal.width) } ?? ideal.width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}
