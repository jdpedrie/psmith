import Foundation
import PsmithKit

@MainActor
func run() async {
    let host = URL(string: "http://127.0.0.1:8080")!
    let tokenStore = InMemoryTokenStore()
    let authState = AuthState()
    let client = PsmithClient(host: host, tokenStore: tokenStore, authState: authState)

    var passed = 0
    var failed = 0

    func check(_ label: String, _ ok: Bool) {
        if ok {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            print("  ✗ \(label)")
        }
    }

    // ── 1. Login ──
    print("▸ Login")
    let user: PsmithUser
    do {
        user = try await client.auth.login(username: "john", password: "password", clientLabel: "verify-cli")
        check("login returns user", true)
        check("username is john", user.username == "john")
        check("authState.isAuthenticated", authState.isAuthenticated)
        check("authState.currentUser matches", authState.currentUser?.id == user.id)
    } catch {
        print("  ✗ login FAILED: \(error)")
        return
    }

    // ── 2. WhoAmI / restoreSession ──
    print("▸ WhoAmI")
    do {
        let me = try await client.auth.whoAmI()
        check("whoAmI matches login user", me.id == user.id)
    } catch {
        check("whoAmI", false); failed += 1
    }

    // ── 3. List providers & models ──
    print("▸ Providers")
    do {
        let providers = try await client.modelProviders.list()
        check("list providers succeeds", true)
        check("at least one provider", !providers.isEmpty)
        if let first = providers.first {
            print("    provider: \(first.label) (\(first.type))")
            let models = try await client.modelProviders.listModels(providerID: first.id)
            check("list models succeeds", true)
            check("at least one model", !models.isEmpty)
            if let m = models.first {
                print("    model: \(m.displayName) (ctx: \(m.contextWindow ?? 0))")
            }
        }
    } catch {
        check("providers: \(error)", false)
    }

    // ── 4. List profiles ──
    print("▸ Profiles")
    let profileID: String
    do {
        let profiles = try await client.profiles.list()
        check("list profiles succeeds", true)
        check("at least one profile", !profiles.isEmpty)
        profileID = profiles.first!.id
        print("    using profile: \(profiles.first!.name) (\(profileID.prefix(8))…)")
    } catch {
        print("  ✗ profiles FAILED: \(error)")
        return
    }

    // ── 5. List existing conversations ──
    print("▸ List conversations")
    do {
        let result = try await client.conversations.list()
        check("list conversations succeeds", true)
        print("    \(result.items.count) existing conversation(s)")
    } catch {
        check("list conversations: \(error)", false)
    }

    // ── 6. Create conversation ──
    print("▸ Create conversation")
    let convo: PsmithConversation
    do {
        convo = try await client.conversations.create(profileID: profileID, title: "Verify CLI test")
        check("create conversation succeeds", true)
        check("has id", !convo.id.isEmpty)
        check("title matches", convo.title == "Verify CLI test")
        print("    id: \(convo.id.prefix(8))…")
    } catch {
        print("  ✗ create conversation FAILED: \(error)")
        return
    }

    // ── 7. Get conversation (returns context) ──
    print("▸ Get conversation + context")
    let context: PsmithContext
    do {
        let (fetched, ctx) = try await client.conversations.get(id: convo.id)
        check("get returns same conversation", fetched.id == convo.id)
        check("context has id", !ctx.id.isEmpty)
        context = ctx
        print("    context: \(ctx.id.prefix(8))…")
    } catch {
        print("  ✗ get conversation FAILED: \(error)")
        return
    }

    // ── 8. List messages (should have system prompt only) ──
    print("▸ List messages (initial)")
    do {
        let msgs = try await client.conversations.listMessages(contextID: context.id)
        check("list messages succeeds", true)
        print("    \(msgs.count) initial message(s)")
        for m in msgs {
            print("    [\(m.role)] \(m.content.prefix(80))…")
        }
    } catch {
        check("list messages: \(error)", false)
    }

    // ── 9. Send message + stream response ──
    print("▸ Send message + stream")
    do {
        let (userMsg, run) = try await client.conversations.sendMessage(
            conversationID: convo.id,
            content: "Say exactly: PONG"
        )
        check("sendMessage returns user message", userMsg.role == .user)
        check("sendMessage returns stream run", !run.id.isEmpty)
        print("    userMsg: \(userMsg.id.prefix(8))… run: \(run.id.prefix(8))…")

        var streamedText = ""
        var gotTerminal = false
        for await event in client.streams.subscribe(streamRunID: run.id) {
            switch event {
            case .chunk(let c):
                if c.type == .textDelta, let s = c.textIfDelta {
                    streamedText += s
                }
            case .terminal(let finalRun):
                gotTerminal = true
                check("stream completed", finalRun.status == .completed)
                if let resultMsgID = finalRun.resultMessageID {
                    print("    result message: \(resultMsgID.prefix(8))…")
                }
            case .failed(let err):
                check("stream failed: \(err)", false)
            }
        }
        check("received terminal event", gotTerminal)
        check("streamed text not empty", !streamedText.isEmpty)
        print("    streamed: \(streamedText.prefix(120))")
    } catch {
        check("send/stream: \(error)", false)
    }

    // ── 10. List messages after response ──
    print("▸ List messages (after send)")
    do {
        let msgs = try await client.conversations.listMessages(contextID: context.id)
        check("messages increased", msgs.count >= 2)
        let hasUser = msgs.contains { $0.role == .user }
        let hasAssistant = msgs.contains { $0.role == .assistant }
        check("has user message", hasUser)
        check("has assistant message", hasAssistant)
        if let asst = msgs.last(where: { $0.role == .assistant }) {
            check("assistant has usage data", asst.usage != nil)
            if let u = asst.usage {
                print("    tokens in: \(u.inputTokens ?? 0) out: \(u.outputTokens ?? 0) cost: \(u.totalCostUsd ?? 0)")
            }
            check("assistant has providerID", asst.providerID != nil)
            check("assistant has modelID", asst.modelID != nil)
        }
    } catch {
        check("list messages after: \(error)", false)
    }

    // ── 11. Token count ──
    print("▸ Token count")
    do {
        let providers = try await client.modelProviders.list()
        if let p = providers.first {
            let models = try await client.modelProviders.listModels(providerID: p.id)
            if let m = models.first {
                let result = try await client.conversations.countContextTokens(
                    contextID: context.id, providerID: p.id, modelID: m.modelID
                )
                check("token count > 0", result.tokenCount > 0)
                check("context window > 0", result.contextWindow > 0)
                print("    \(result.tokenCount) / \(result.contextWindow)")
            }
        }
    } catch {
        check("token count: \(error)", false)
    }

    // ── 12. List contexts ──
    print("▸ Contexts")
    do {
        let ctxs = try await client.conversations.listContexts(conversationID: convo.id)
        check("list contexts succeeds", true)
        check("at least one context", !ctxs.isEmpty)
    } catch {
        check("list contexts: \(error)", false)
    }

    // ── 13. Delete conversation (cleanup) ──
    print("▸ Cleanup")
    do {
        try await client.conversations.delete(id: convo.id)
        check("delete conversation succeeds", true)
    } catch {
        check("delete: \(error)", false)
    }

    // ── 14. Logout ──
    print("▸ Logout")
    do {
        try await client.auth.logout()
        check("logout succeeds", true)
        check("authState no longer authenticated", !authState.isAuthenticated)
    } catch {
        check("logout: \(error)", false)
    }

    // ── Summary ──
    print("\n═══════════════════════════")
    print("  \(passed) passed, \(failed) failed")
    print("═══════════════════════════")

    exit(failed > 0 ? 1 : 0)
}

await run()
