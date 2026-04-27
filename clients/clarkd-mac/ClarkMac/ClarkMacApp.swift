import SwiftUI
import AppKit
import ClarkKit

@main
struct ClarkMacApp: App {
    @State private var appModel = AppModel()

    init() {
        // SwiftPM-built executables aren't a proper .app bundle on their own;
        // when the host hasn't promoted us to a regular dock-bearing app,
        // force the policy and pull the window to the front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Clark") {
            RootView()
                .environment(appModel)
                .frame(minWidth: 720, minHeight: 560)
                .task { await appModel.bootstrap() }
        }
    }
}
