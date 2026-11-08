import Foundation
import SwiftUI
import UIKit
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The shell boards' content: sign in, launch, onboarding and the list's
/// other states.
@MainActor
enum Shell {
    static let homeHost = URL(string: "https://psmith.home.arpa")!
    static let labHost = URL(string: "https://lab.psmith.dev")!

    static func appModel(host: URL = homeHost, offline: Bool = false,
                         profiles: [PsmithProfile] = Board.profiles) -> AppModel {
        let app = AppModel(host: host, tokenStore: InMemoryTokenStore(), authState: AuthState(),
                           connectivityState: offline ? .offline : .online)
        app.profiles.profiles = profiles
        return app
    }

    /// An account manager on its own defaults. With `other`, a second
    /// account is signed in so "Or continue as" has a row.
    static func accounts(other: Bool) -> AccountManager {
        let suite = "psmith-shell-accounts-\(other)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AccountStore(defaults: defaults)
        guard other else { return AccountManager(store: store) }
        let me = Account(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, host: labHost, username: "jdp")
        let john = Account(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, host: homeHost,
                           username: "john", displayLabel: "John")
        store.append(john, makeActive: false)
        store.append(me, makeActive: true)
        let m = AccountManager(store: store)
        m.appModel(for: john.id)?.authState.setAuthenticated(Board.user)
        return m
    }

    // MARK: Onboarding

    static var templates: [PsmithProviderTemplate] {
        func t(_ id: String, _ name: String, _ driver: String = "openai-compatible", base: String? = nil,
               env: String? = nil, logo: String? = nil) -> PsmithProviderTemplate {
            PsmithProviderTemplate(catalogProviderID: id, name: name, driverType: driver, apiBase: base,
                                   envKey: env, presetID: driver == "openai-compatible" ? id : nil, logoSlug: logo ?? id)
        }
        return [
            t("anthropic", "Anthropic", "anthropic", base: "https://api.anthropic.com", env: "ANTHROPIC_API_KEY"),
            t("google", "Google Gemini", "google", env: "GEMINI_API_KEY"),
            t("openai", "OpenAI", base: "https://api.openai.com/v1", env: "OPENAI_API_KEY"),
            t("openrouter", "OpenRouter", base: "https://openrouter.ai/api/v1"),
            t("xai", "xAI Grok", base: "https://api.x.ai/v1"),
            t("mistral", "Mistral", base: "https://api.mistral.ai/v1"),
            t("deepseek", "DeepSeek", base: "https://api.deepseek.com"),
            t("groq", "Groq", base: "https://api.groq.com/openai/v1"),
            t("ollama", "Ollama (local)", base: "http://localhost:11434/v1"),
            t("perplexity", "Perplexity", base: "https://api.perplexity.ai"),
        ]
    }

    static var discovered: [PsmithDiscoveredModel] {
        func m(_ id: String, _ name: String, _ i: Double, _ o: Double, thinks: Bool = false,
               enabled: Bool = false) -> PsmithDiscoveredModel {
            PsmithDiscoveredModel(
                modelID: id, displayName: name, contextWindow: 200_000,
                pricing: PsmithModelPricing(inputPerMillion: i, outputPerMillion: o,
                                            cacheReadPerMillion: nil, cacheWritePerMillion: nil),
                capabilities: PsmithModelCapabilities(streaming: true, thinking: thinks, toolUse: true,
                                                      vision: true, promptCaching: true),
                alreadyEnabled: enabled)
        }
        return [
            m("claude-opus-4-7", "Claude Opus 4.7", 15, 75, thinks: true),
            m("claude-sonnet-4-5", "Claude Sonnet 4.5", 3, 15, enabled: true),
            m("claude-haiku-4-5", "Claude Haiku 4.5", 1, 5),
            m("claude-opus-4-1", "Claude Opus 4.1", 15, 75),
            m("claude-sonnet-4", "Claude Sonnet 4", 3, 15),
            m("claude-haiku-3-5", "Claude Haiku 3.5", 0.8, 4),
        ]
    }

    // MARK: List states

    /// ListSearch, Active: two active titles match "vacuum".
    static var searchActive: [PsmithConversation] {
        [
            Board.conversation("c-vacuum", "Postgres vacuum tuning", Board.chief, at: Board.today(10, 51)),
            Board.conversation("c-autovac", "Autovacuum on the events table", Board.demo, at: Board.daysAgo(4)),
        ]
    }

    static var searchArchived: [PsmithConversation] {
        [Board.conversation("c-freeze", "Vacuum freeze runbook", Board.chief, at: Board.daysAgo(80),
                            archived: Board.daysAgo(70))]
    }

    /// ListArchived's archive, newest first.
    static var archived: [PsmithConversation] {
        func a(_ id: String, _ title: String, _ p: PsmithProfile, _ daysAgo: Int) -> PsmithConversation {
            Board.conversation(id, title, p, at: Board.daysAgo(daysAgo + 3), archived: Board.daysAgo(daysAgo))
        }
        return [
            a("a-q3", "Q3 board memo draft", Board.chief, 5),
            a("a-k8s", "Kubernetes ingress notes", Board.demo, 9),
            a("a-div", "Pirate tutor: long division", Board.pirate, 17),
            a("a-hire", "Council: hiring a second engineer", Board.council, 24),
            a("a-lisbon", "Lisbon flights, first pass", Board.chief, 38),
            a("a-pg16", "Postgres 16 upgrade checklist", Board.demo, 56),
            a("a-grant", "Grant application outline", Board.chief, 72),
        ]
    }

    /// ListOffline: the Lisbon send waits in the queue.
    static var offlineList: [PsmithConversation] {
        [
            Board.conversation("c-weekly", "Weekly planning", Board.chief, at: Board.today(7, 30), pinned: true),
            Board.conversation("c-lisbon", "Trip to Lisbon in May", Board.chief, at: Board.today(10, 55)),
            Board.conversation("c-scroll", "Scroll architecture review", Board.demo, at: Board.today(10, 42)),
            Board.conversation("c-vacuum", "Postgres vacuum tuning", Board.chief, at: Board.today(9, 58)),
            Board.conversation("c-pirate", "Pirate tutor: fractions", Board.pirate, at: Board.today(9, 15)),
            Board.conversation("c-council", "Council: pricing debate", Board.council, at: Board.today(8, 3)),
            Board.conversation("c-swift", "Swift 6 concurrency errors", Board.demo, at: Board.daysAgo(1)),
        ]
    }

    /// Board Main: Postgres replies (its time hidden), so it sits under Scroll.
    static var mainList: [PsmithConversation] {
        Board.mainList.map {
            $0.id == "c-vacuum" ? Board.conversation("c-vacuum", "Postgres vacuum tuning", Board.chief, at: Board.today(10, 30)) : $0
        }
    }

    /// ListSwipe: the rows around the open swipe, the confirm and the rename.
    static var swipeList: [PsmithConversation] {
        [
            Board.conversation("c-scroll", "Scroll architecture review", Board.demo, at: Board.today(10, 42)),
            Board.conversation("c-vacuum", "Postgres vacuum tuning", Board.chief, at: Board.today(10, 30)),
            Board.conversation("c-pirate", "Pirate tutor: fractions", Board.pirate, at: Board.today(9, 15)),
            Board.conversation("c-council", "Council: pricing debate", Board.council, at: Board.today(8, 3)),
            Board.conversation("c-swift", "Swift 6 concurrency errors", Board.demo, at: Board.daysAgo(1)),
        ]
    }
}
