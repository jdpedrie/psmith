import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithUI

/// Probe for the kit: renders the shared parts so they can be compared
/// with the Tokens and parts board.
@MainActor
final class KitProbeTests: XCTestCase {
    func testKitParts() {
        IKRender.shoot("kit", sizes: [IKRender.sizes[1]]) { KitSampler() }
    }
}

private struct KitSampler: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack(alignment: .top) {
            theme.chrome.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                IKNavRow(title: "Info", onBack: {}) { IKGlassCapsule(title: "Edit", action: {}) }
                HStack {
                    IKPill(systemImage: "brain", label: "Thought for 12.4s")
                    IKPill(systemImage: "checkmark", label: "Used read_file")
                }
                .padding(.horizontal, 16)
                HStack {
                    IKChip(title: "All", isOn: true, action: {})
                    IKChip(title: "Demo", dot: .teal, action: {})
                }
                .padding(.horizontal, 16)
                IKConfirmCard(question: "Delete this message?", detail: "Its replies attach to the message before it.",
                              onCancel: {}, onConfirm: {})
                    .padding(.horizontal, 16)
                IKBanner(systemImage: "exclamationmark.triangle", text: "This context is 86% full.")
                    .padding(.horizontal, 16)
                IKGroup(ground: .themed) {
                    IKRow("Cache hits", value: "91%")
                    IKRow("Branches", value: "3 at message 14", chevron: true)
                }
                .padding(.horizontal, 16)
                Text("The lazy stack is the cause. Rows above the viewport report estimated heights.")
                    .font(.system(size: 16)).lineSpacing(7).foregroundStyle(IK.text)
                    .padding(.horizontal, 16)
                IKSlotCard {
                    HStack {
                        Text("Compress into a new context").font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                        Spacer()
                        Button("Compress") {}.ikButton(.primary, height: 40)
                    }
                }
                .padding(.horizontal, 12)
                IKSaveBar(summary: "2 unsaved changes", ground: .themed, onRevert: {}, onSave: {})
            }
        }
    }
}

@MainActor
final class NavProbeTests: XCTestCase {
    func testSystemNavBar() {
        IKRender.shoot("navbar", sizes: [IKRender.sizes[1]]) { NavSampler() }
    }
}

private struct NavSampler: View {
    @State private var path = ["info"]
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack(path: $path) {
            Color.red
                .navigationDestination(for: String.self) { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(0..<30) { i in
                                Text("Row \(i) of the transcript that scrolls under the bar").foregroundStyle(IK.text)
                            }
                        }
                        .padding(16)
                    }
                    .background(theme.chrome)
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .navigationTitle("Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Edit") {} }
                    }
                }
        }
    }
}
