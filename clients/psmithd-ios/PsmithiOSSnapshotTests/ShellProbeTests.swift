import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Renders sign in, launch and onboarding with the boards' content
/// (boards SignInServer, SignInCredentials, Launching, LaunchOffline,
/// OnboardProvider, OnboardKey, OnboardModels).
@MainActor
final class ShellProbeTests: XCTestCase {
    func testSignInServer() {
        IKRender.shoot("SignInServer") {
            LoginView(seed: .init(urlText: "https://psmith.hom.arpa",
                                  status: .unreachable("no server answered at psmith.hom.arpa.")))
                .environment(Shell.accounts(other: false))
        }
    }

    /// Pushed from the account menu: the system back button, no app header.
    func testSignInCredentials() {
        IKRender.shoot("SignInCredentials") {
            ShellPushedHost {
                LoginView(initialUsername: "jdp", serverVersion: "0.14.2",
                          seed: .init(password: "correct-horse-staple", credentialsHost: Shell.labHost))
            }
            .environment(Shell.accounts(other: true))
        }
    }

    func testSignInServerPushed() {
        IKRender.shoot("SignInServerPushed", sizes: [IKRender.sizes[1]]) {
            ShellPushedHost { LoginView(seed: .init(urlText: "https://lab.psmith.dev", status: .ok(version: "0.14.2"))) }
                .environment(Shell.accounts(other: false))
        }
    }

    func testLaunching() {
        IKRender.shoot("Launching") { LaunchingScreen(host: Shell.homeHost) }
    }

    func testLaunchOffline() {
        IKRender.shoot("LaunchOffline") {
            let app = Shell.appModel(offline: true)
            return LaunchOfflineScreen(user: Board.user, retry: {}, open: { _ in })
                .environment(app)
                .environment(Shell.accounts(other: false))
        }
    }

    private func onboarding(_ screen: OnboardingScreen) -> some View {
        let app = Shell.appModel()
        app.providers.templates = Shell.templates
        app.providers.templatesLoaded = true
        return screen.environment(app)
    }

    func testOnboardProvider() {
        IKRender.shoot("OnboardProvider") { onboarding(OnboardingScreen()) }
    }

    func testOnboardKey() {
        IKRender.shoot("OnboardKey") {
            onboarding(OnboardingScreen(step: .key, template: Shell.templates[0], apiKey: "sk-ant-api03-7fQ2xLm9"))
        }
    }

    func testOnboardModels() {
        IKRender.shoot("OnboardModels") {
            onboarding(OnboardingScreen(step: .models, template: Shell.templates[0], createdProviderID: "prov-1",
                                        discovered: Shell.discovered,
                                        selected: ["claude-opus-4-7", "claude-haiku-4-5"]))
        }
    }
}

/// A one-page stack with the view pushed, so it gets the system bar and
/// back button it has in the app.
struct ShellPushedHost<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var path = ["pushed"]
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            theme.well
                .navigationDestination(for: String.self) { _ in content }
        }
    }
}
