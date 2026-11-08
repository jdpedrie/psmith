import SwiftUI
import PsmithKit
import PsmithUI

/// The pages a conversation pushes onto the root stack.
enum ConversationPage: Hashable {
    case info, models, callSettings
    case fullText(title: String, markdown: String)
    case image(messageID: String, fileID: String, filename: String)
}

/// View state for one open conversation that isn't the view model's:
/// which message is asking to be deleted, whose usage is open, the tray.
/// One observable object so the transcript rows, the composer and the
/// slot cards agree on it, and so tests drive the same methods the
/// buttons call.
@MainActor
@Observable
final class ConversationUIState {
    struct DeleteRequest: Equatable {
        let messageID: String
        let cascade: Bool
    }

    var confirmingDelete: DeleteRequest?
    var usageExpanded: Set<String> = []
    var trayOpen = false
    var renaming = false
    var renameDraft = ""
    /// Delete of the pending summary asked from the review card.
    var confirmingSummaryDelete = false
    /// A `send:` fragment choice on an earlier message, waiting on the
    /// fork confirm that replaces the choice in place.
    var pendingFork: (messageID: String, text: String)?
    var page: ConversationPage?

    func requestDelete(_ message: PsmithMessage, cascade: Bool = false) {
        confirmingDelete = DeleteRequest(messageID: message.id, cascade: cascade)
    }

    func cancelDelete() { confirmingDelete = nil }

    func confirmDelete(model: ConversationViewModel) {
        guard let req = confirmingDelete else { return }
        confirmingDelete = nil
        Haptics.notify(.warning)
        Task { await model.deleteMessage(id: req.messageID, cascade: req.cascade) }
    }

    func toggleUsage(_ id: String) {
        if usageExpanded.contains(id) { usageExpanded.remove(id) } else { usageExpanded.insert(id) }
    }

    func openCompress(model: ConversationViewModel) {
        trayOpen = false
        model.compactError = nil
        model.showingCompactView = true
        Task { await model.prepareCompactView() }
    }

    func cancelCompress(model: ConversationViewModel) {
        model.showingCompactView = false
    }

    func startCompress(model: ConversationViewModel) {
        let guide = model.compactPromptDraft
        let provider = model.compactProviderID
        let mid = model.compactModelID
        model.showingCompactView = false
        Task { await model.compact(guide: guide, providerID: provider, modelID: mid) }
    }

    func beginEdit(_ message: PsmithMessage, model: ConversationViewModel) {
        model.selectingTextMessageID = nil
        model.editingMessage = message
    }
}

extension EnvironmentValues {
    /// Pushes a conversation page; set by the conversation screen so
    /// views deep in the transcript (an image tile, "Show full text")
    /// can open one.
    @Entry var openConversationPage: (ConversationPage) -> Void = { _ in }
}

// MARK: - Colors only these screens use

extension Theme {
    /// The composer tray's ground: chrome lifted toward white.
    var trayGround: Color { chrome.ikBlend(dark: (.white, 0.025), light: (.white, 0.7)) }
    /// Behind the long-press menu: the transcript's chrome, dimmed.
    var menuBackdrop: Color { chrome.ikBlend(dark: (.black, 0.47), light: (.black, 0.118)) }
}

extension IK {
    /// Text fields sunk into a glass card.
    static let well = Color.dynamic(light: Color(red: 16 / 255, green: 32 / 255, blue: 52 / 255).opacity(0.088),
                                    dark: Color.black.opacity(0.22))
    /// The "Confirm" fill on a summary waiting for review.
    static let amberFill = Color.dynamic(light: .hex("#A85808"), dark: .hex("#C7782F"))
}

// MARK: - Small parts

/// The boards' role caps: 11.5pt semibold, tracked.
struct RoleCaps: View {
    let text: String
    var color: Color = IK.secondary
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).tracking(0.3).foregroundStyle(color)
    }
}

/// A 12pt ring spinner, the boards' `.spin`.
struct IKSpinner: View {
    var size: CGFloat = 12
    var color: Color? = nil
    @Environment(\.theme) private var theme
    @State private var turning = false
    var body: some View {
        ZStack {
            Circle().stroke(IK.wash(0.15), lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.25).stroke(color ?? theme.accentInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size - 1.5, height: size - 1.5)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

/// An inline status strip above the composer: offline, load errors.
struct StatusBanner: View {
    let systemImage: String
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(IK.orange)
                .padding(.top, 2)
            Text(text).cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(IK.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onDismiss == nil ? 12 : 0)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(IK.orange.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

/// The context gauge in the header: a ring and the percent used.
struct ContextGauge: View {
    let fraction: Double?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(IK.ring(0.12), lineWidth: 2.5)
            if let fraction {
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color(fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IK.strong)
            }
        }
        .frame(width: 22, height: 22)
        .frame(width: 28, height: 28)
    }

    private func color(_ f: Double) -> Color {
        if f >= 0.9 { return IK.red }
        if f >= 0.75 { return IK.orange }
        return theme.accent
    }
}

/// The cache line at the right of a reply's action row.
struct CacheGrade {
    let color: Color
    let percent: Int
    let label: String

    /// Below this prompt size providers don't cache, so a grade is noise.
    static let floorTokens: Int32 = 4_096

    static func grade(_ u: PsmithMessageUsage, isFirstMetered: Bool) -> CacheGrade? {
        guard let input = u.inputTokens, input > 0 else { return nil }
        guard u.cacheReadTokens != nil || u.cacheWriteTokens != nil else { return nil }
        let read = u.cacheReadTokens ?? 0
        if read == 0 && isFirstMetered { return nil }
        // Providers split on whether input counts the cached tokens.
        let prompt: Int32 = read > input ? read + input : input
        guard prompt >= floorTokens else { return nil }
        let ratio = Double(read) / Double(prompt)
        let pct = Int((ratio * 100).rounded())
        switch ratio {
        case 0.8...: return CacheGrade(color: IK.green, percent: pct, label: "Excellent")
        case 0.3..<0.8: return CacheGrade(color: IK.orange, percent: pct, label: "Partial")
        default: return CacheGrade(color: IK.red, percent: pct, label: "Poor")
        }
    }
}

enum UsageFormat {
    /// "in: 118,420 (96,000 cached) · out: 1,412 · $0.0391"
    static func line(_ u: PsmithMessageUsage) -> String? {
        var parts: [String] = []
        if let n = u.inputTokens {
            var s = "in: \(n.formatted())"
            if let cr = u.cacheReadTokens, cr > 0 { s += " (\(cr.formatted()) cached)" }
            parts.append(s)
        }
        if let cw = u.cacheWriteTokens, cw > 0 { parts.append("cw: \(cw.formatted())") }
        if let n = u.outputTokens { parts.append("out: \(n.formatted())") }
        if let c = u.totalCostUsd { parts.append(String(format: "$%.4f", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 82.1k, 1,204.
    static func tokens(_ n: Int32) -> String {
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return n.formatted()
    }

    static func price(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.2f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        return String(format: "$%.4f", v)
    }

    static func time(_ d: Date) -> String? {
        guard d.timeIntervalSince1970 > 0 else { return nil }
        let t = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return t }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday \(t)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())) · \(t)"
    }

    /// 812 bytes, 6.8 KB, 48 KB, 1.2 MB.
    static func bytes(_ n: Int) -> String {
        let kb = Double(n) / 1024
        if kb < 1 { return "\(n) bytes" }
        if kb < 100 {
            let one = String(format: "%.1f", kb)
            return (one.hasSuffix(".0") ? String(one.dropLast(2)) : one) + " KB"
        }
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }
}

extension ConversationViewModel {
    func modelDisplayName(providerID: String?, modelID: String?) -> String? {
        guard let mid = modelID, !mid.isEmpty else { return nil }
        return availableModels.first(where: { $0.modelID == mid && (providerID == nil || $0.providerID == providerID) })?
            .displayName ?? mid
    }

    func modelInfo(providerID: String?, modelID: String?) -> PsmithUserModel? {
        guard let mid = modelID else { return nil }
        return availableModels.first(where: { $0.modelID == mid && (providerID == nil || $0.providerID == providerID) })
    }

    /// The named speakers in the transcript, by palette slot, first
    /// appearance first.
    var councilVoices: [Int] {
        var seen: [Int] = []
        for m in messages where m.role == .assistant {
            if let slot = m.personaSlot, m.persona != nil, !seen.contains(slot) { seen.append(slot) }
        }
        return seen
    }
}

extension View {
    /// Text set like the boards' CSS: `size` on `lineHeight` lines. CSS
    /// puts half the leading above the first line and half below the
    /// last; SwiftUI only spaces between lines, so the halves are padding.
    func cssLines(size: CGFloat, lineHeight: CGFloat, weight: Font.Weight = .regular) -> some View {
        let leading = max(0, lineHeight - size * 1.193)
        return font(.system(size: size, weight: weight))
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
    }
}

/// A notice above the composer: the context warning, a failed
/// compaction. IKBanner's look, with the boards' 19pt lines.
struct NoticeBanner: View {
    let systemImage: String
    let text: String
    var color: Color = IK.orange
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
                .padding(.top, onDismiss == nil ? 3 : 12)
            Text(text).cssLines(size: 13.5, lineHeight: 19).foregroundStyle(IK.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, onDismiss == nil ? 0 : 11)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(IK.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onDismiss == nil ? 12 : 0)
        .padding(.vertical, onDismiss == nil ? 9 : 0)
        .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.33), lineWidth: 1))
    }
}
