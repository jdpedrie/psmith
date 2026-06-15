# Web client

The web client is a server-rendered UI built into `reeved` itself. It is not a separate app talking over the RPC API; it is a presentation layer in the Go process that calls the same services in-process and renders HTML. The page works as plain HTML (forms POST, links navigate) and is progressively enhanced with [Datastar](https://data-star.dev): the conversation streams live over SSE. This document describes the approach and the current state.

Status: early but functional. Working today: cookie auth, the chats list, creating a conversation (pick a profile), a conversation that sends and streams end to end, a per-conversation model picker (populated from the user's enabled models, remembered on the conversation), markdown rendering of message content, provider management under Settings (add a provider, discover and enable models, test the connection, delete), and profile management (create, edit name/system prompt/description, delete), embedder and Langfuse config (save, test, delete), the elicitation prompt (MCP secret-input mid-stream), image attachments (upload in the composer, rendered in the transcript), a per-provider cost view, a contexts view (list a conversation's contexts and inspect retired ones read-only), compaction (run it, review the streamed summary, promote it into a fresh context), profile config including default model, compaction model/guide/mode, and auto-title model/guide, in-place message editing, regenerating an assistant turn (which branches), and the per-profile plugin pipeline (attach, configure as JSON, remove). Not built yet: branch navigation (switching between regenerated alternatives). The parity target is the [client spec](client-spec.md) and the [iOS reference](ios-reference.md).

## Why server-rendered

The project optimizes for operational simplicity (one Go binary) and resilient server-owned streams. A server-rendered client in Go keeps both: no Node runtime, no second deploy, no TypeScript client to keep in sync, and direct in-process access to the streaming infrastructure. It also sidesteps the browser limits of the Connect protocol: client-streaming (the `UploadFile` RPC) is not available in browsers, but the composer posts as multipart (Datastar's `@post` with `contentType: 'form'`) and the send handler stores bytes through `files.Service.Store`, the non-streaming counterpart to `UploadFile` that reuses the same hashing, dedup, and storage path. Images render in the transcript via short-lived signed URLs.

The trade is that the web client does not consume the documented wire contract the way iOS does. Parity here means the same feature surface and UX, backed by the same Go services, not three generated clients honoring one proto. The client-spec behaviors (streaming resume, four-layer settings, branching, compaction, elicitation) remain the checklist.

## Stack

- **templ** (`github.com/a-h/templ`) for typed HTML components. Templates live in `internal/web/*.templ` and compile to `*_templ.go` (checked in; regenerate with `make web-generate`).
- **Datastar** (`github.com/starfederation/datastar-go`, runtime pinned to v1.0.2, vendored at `internal/web/assets/datastar.js`) for progressive enhancement: `data-*` attributes drive behavior and the server patches the DOM over SSE.
- **embed.FS** for the CSS and the Datastar runtime, so the UI ships inside the single binary.

## How it is wired

`internal/web.New(queries, authSvc, conversationsSvc, supervisor, logger)` builds the handler from the same dependencies `main()` already constructed for the ConnectRPC services. `Mount(mux)` registers the routes on reeved's mux at paths distinct from the RPC services and the other non-RPC endpoints, so they coexist. Service calls go through the real handler methods with `connect.NewRequest(...)` and a context carrying the authenticated user, the same way the interceptor would set it.

Routes: `GET /login`, `POST /login`, `POST /logout`, `GET /chats`, `GET /c/{id}`, `POST /c/{id}/send`, `GET /c/{id}/stream`, and `GET /web-assets/` for the embedded assets.

## Auth

Cookie sessions, layered on the existing sessions table with no new auth code. Login calls `AuthService.Login` in-process and stores the returned session token in an httpOnly cookie; every request validates it through the same `auth.AuthenticateBearer` the RPC interceptor uses (the cookie just carries the bearer token). Bearer auth for the RPC clients is untouched.

## Streaming

The conversation page renders the materialized messages server-side, so it reads with JS off. When enhanced, sending a message posts to `/c/{id}/send`, which calls `SendMessage`, appends the user bubble and an assistant placeholder via SSE patches, and clears the composer. The placeholder's `data-on-load` opens `GET /c/{id}/stream?run=...`, a long-lived SSE response that subscribes to the run through the stream supervisor, morphs the assistant element as text deltas arrive, and replaces the placeholder with a final bubble on the terminal event. Because `Subscribe` replays persisted chunks from a sequence before live-tailing, the stream endpoint takes a `from` cursor and resume is a re-request with the last sequence (resume wiring on the client side is a fan-out item).

Without JS, the send form POSTs normally and redirects back to the conversation; the run still completes server-side (that is the whole resilience design) and the reply appears on the next load.

The composer carries a model picker. Its value is a `providerID|modelID` pair; sending passes it as the per-turn provider and model override, and the choice is written back to the conversation's default model so the picker remembers it. Message content (live deltas, stored messages, and the finalized turn) is rendered as markdown with goldmark and then sanitized with bluemonday, because the content is model-generated.

## The device-tools gap

Calendar, Reminders, Health, and Obsidian are device-native (EventKit, HealthKit, file bookmarks) and a browser cannot run them, so the web client registers no device-tool capabilities. The server already handles that: the model gets a clean "not supported by the connected device" result. Elicitation, by contrast, works (see below). Web-equivalent integrations (for example Google Calendar over OAuth) would be a later, separate effort.

## Elicitation

When a tool elicits input mid-run, the stream handler patches a form into the conversation built from the request's JSON Schema (string, password, number, and boolean fields). The fields bind under an `elicit` signal namespace so they do not collide with the composer's signals, and the action (accept / decline) is carried in the request URL. Submitting posts to a cookie-authenticated web route that delivers the response to the same elicit broker the bearer endpoint uses, then clears the form. The stream stays open throughout, so the waiting tool unblocks and the assistant turn resumes on the same SSE connection. The secret never enters the transcript.

## Building and running

The generated templ files are checked in, so `go build ./...` and `make build` need no extra step. After editing a `.templ` file, run `make web-generate`. The UI is served by `reeved` on its normal address; open `/` (it redirects to `/login`). See [operations/configuration.md](../operations/configuration.md) for the server's environment.

Tests live in `internal/web/`. The streaming path has an end-to-end test that drives the real anthropic driver against the fake LLM through the supervisor and asserts the Datastar patches, the same harness style as the conversations e2e tests ([operations/fakellm.md](../operations/fakellm.md)).
