# Web client

The web client is a server-rendered UI built into `psmithd` itself. It is not a separate app talking over the RPC API; it is a presentation layer in the Go process that calls the same services in-process and renders HTML. The page works as plain HTML (forms POST, links navigate) and is progressively enhanced with [htmx](https://htmx.org) (plus its SSE extension): the conversation streams live over SSE. This document describes the approach and the current state.

Status: early but functional. Working today: cookie auth, the chats list, creating a conversation (pick a profile), a conversation that sends and streams end to end, a rich per-conversation model picker (grouped by provider, with each model's context window, cost bucket, knowledge cutoff, and capability badges; capability-filtered against what the profile requires; remembered on the conversation), per-conversation settings (a Call settings tab with the sampling/thinking/caching/provider-extras knobs and inheritance preview, and a Plugins tab that shows the merged pipeline with inherited/override badges and lets you disable inherited plugins or add conversation-only overrides), markdown rendering of message content, provider management under Settings (add a provider, discover and enable models, test the connection, delete), and profile management (create, edit name/system prompt/description, delete), embedder and Langfuse config (save, test, delete), the elicitation prompt (MCP secret-input mid-stream), image attachments (upload in the composer, rendered in the transcript), a per-provider cost view, a contexts view (list a conversation's contexts and inspect retired ones read-only), compaction (run it, review the streamed summary, promote it into a fresh context), profile config including default model, compaction model/guide/mode, and auto-title model/guide, in-place message editing, regenerating an assistant turn (which branches), and the per-profile plugin pipeline (attach, configure as JSON, remove). Not built yet: branch navigation (switching between regenerated alternatives), and the JSON-oneof call-settings editors (OpenAI response-format/logit-bias, Google response-schema). The parity target is the [client spec](client-spec.md) and the [iOS reference](ios-reference.md).

## Why server-rendered

The project optimizes for operational simplicity (one Go binary) and resilient server-owned streams. A server-rendered client in Go keeps both: no Node runtime, no second deploy, no TypeScript client to keep in sync, and direct in-process access to the streaming infrastructure. It also sidesteps the browser limits of the Connect protocol: client-streaming (the `UploadFile` RPC) is not available in browsers, but the composer posts as multipart (htmx `hx-encoding="multipart/form-data"`) and the send handler stores bytes through `files.Service.Store`, the non-streaming counterpart to `UploadFile` that reuses the same hashing, dedup, and storage path. Images render in the transcript via short-lived signed URLs.

The trade is that the web client does not consume the documented wire contract the way iOS does. Parity here means the same feature surface and UX, backed by the same Go services, not three generated clients honoring one proto. The client-spec behaviors (streaming resume, four-layer settings, branching, compaction, elicitation) remain the checklist.

## Stack

- **templ** (`github.com/a-h/templ`) for typed HTML components. Templates live in `internal/web/*.templ` and compile to `*_templ.go` (checked in; regenerate with `make web-generate`).
- **htmx 2** (vendored at `internal/web/assets/htmx.min.js`) plus its **SSE extension** (`internal/web/assets/sse.js`) for progressive enhancement: `hx-*` attributes drive behavior. The composer `hx-post`s the send and swaps the returned HTML fragment into the transcript; the streamed assistant turn is an element with `hx-ext="sse" sse-connect=...` whose `sse-swap` targets morph as named SSE events arrive. The server speaks plain SSE (no client library on the wire), not a framework-specific patch protocol.
- **embed.FS** for the CSS and the htmx runtime, so the UI ships inside the single binary.

## How it is wired

`internal/web.New(queries, authSvc, conversationsSvc, supervisor, logger)` builds the handler from the same dependencies `main()` already constructed for the ConnectRPC services. `Mount(mux)` registers the routes on psmithd's mux at paths distinct from the RPC services and the other non-RPC endpoints, so they coexist. Service calls go through the real handler methods with `connect.NewRequest(...)` and a context carrying the authenticated user, the same way the interceptor would set it.

Routes: `GET /login`, `POST /login`, `POST /logout`, `GET /chats`, `GET /c/{id}`, `POST /c/{id}/send`, `GET /c/{id}/stream`, and `GET /web-assets/` for the embedded assets.

## Auth

Cookie sessions, layered on the existing sessions table with no new auth code. Login calls `AuthService.Login` in-process and stores the returned session token in an httpOnly cookie; every request validates it through the same `auth.AuthenticateBearer` the RPC interceptor uses (the cookie just carries the bearer token). Bearer auth for the RPC clients is untouched.

## Streaming

The conversation page renders the materialized messages server-side, so it reads with JS off. When enhanced, the composer `hx-post`s to `/c/{id}/send`, which calls `SendMessage` and returns an HTML fragment (the user bubble plus a streaming assistant element) that htmx appends to `#messages`; `hx-on::after-request` resets the composer. The assistant element carries `hx-ext="sse" sse-connect="/c/{id}/stream?run=..."`, so htmx opens that long-lived SSE response, which subscribes to the run through the stream supervisor and emits named events: `message` (the rendered markdown so far, swapped into the `.md` target), `elicit` (an inline prompt), and `done` (which `sse-close` uses to close the connection on the terminal event). Because `Subscribe` replays persisted chunks from a sequence before live-tailing, the stream endpoint takes a `from` cursor and resume is a re-request with the last sequence (resume wiring on the client side is a fan-out item).

Without JS, the send form POSTs normally and redirects to `/c/{id}?run=...`; the conversation page renders the same streaming element on load, and the run completes server-side regardless (that is the whole resilience design).

The composer carries a model picker. Its value is a `providerID|modelID` pair; sending passes it as the per-turn provider and model override, and the choice is written back to the conversation's default model so the picker remembers it. Message content (live deltas, stored messages, and the finalized turn) is rendered as markdown server-side with goldmark and then sanitized with bluemonday, because the content is model-generated; the live stream ships the rendered HTML in each `message` event rather than rendering markdown in the browser.

## The device-tools gap

Calendar, Reminders, Health, and Obsidian are device-native (EventKit, HealthKit, file bookmarks) and a browser cannot run them, so the web client registers no device-tool capabilities. The server already handles that: the model gets a clean "not supported by the connected device" result. Elicitation, by contrast, works (see below). Web-equivalent integrations (for example Google Calendar over OAuth) would be a later, separate effort.

## Elicitation

When a tool elicits input mid-run, the stream handler emits an `elicit` SSE event carrying a form built from the request's JSON Schema (string, password, number, and boolean fields), which htmx swaps into the streaming element's elicit host. Field inputs are named `field_<name>` so they don't collide with the action button, and the chosen action (accept / decline) rides the submit button's value. Submitting `hx-post`s to a cookie-authenticated web route that delivers the response to the same elicit broker the bearer endpoint uses; the empty response plus an `outerHTML` swap removes the form. The stream stays open throughout, so the waiting tool unblocks and the assistant turn resumes on the same SSE connection. The secret never enters the transcript.

## Building and running

The generated templ files are checked in, so `go build ./...` and `make build` need no extra step. After editing a `.templ` file, run `make web-generate`. The UI is served by `psmithd` on its normal address; open `/` (it redirects to `/login`). See [operations/configuration.md](../operations/configuration.md) for the server's environment.

Tests live in `internal/web/`. The streaming path has an end-to-end test that drives the real anthropic driver against the fake LLM through the supervisor and asserts the named SSE events (`message`, `done`), the same harness style as the conversations e2e tests ([operations/fakellm.md](../operations/fakellm.md)).
