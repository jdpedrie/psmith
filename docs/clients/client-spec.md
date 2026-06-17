# Client specification

This is the contract any Spalt client must honor, independent of platform. It describes what the server expects and guarantees: how to authenticate, how to drive a conversation, how streaming and reconnection work, what the client owns versus what the server owns, and how the side channels (device tools, elicitation, file upload) behave. The iOS app is the reference implementation of this contract; [ios-reference.md](ios-reference.md) maps each section here to concrete Swift types. If you are building a new client, build to this document and check your understanding against the iOS code.

The guiding principle: **the server is authoritative, the client is a viewer.** The server owns conversation state, history, and the lifecycle of every model run. A client holds no authoritative state it cannot reconstruct by re-fetching. This is what lets a client disconnect, background, crash, or be replaced by another device without losing work. Build the client so that "throw away all local state and re-fetch" is always correct.

## Transport

Spalt speaks ConnectRPC over HTTP/2. The server runs h2c (cleartext HTTP/2) behind whatever TLS termination the operator puts in front of it; the client connects with the Connect protocol and protobuf codec. There are also a few plain HTTP endpoints for things that do not fit the RPC mold (file download, the device-tool and elicitation respond endpoints, health). All of them, RPC and HTTP alike, authenticate with the same bearer token.

The protobuf schema is the source of truth for every message shape. Generate your client stubs from `proto/spalt/v1/*.proto`. Every RPC has a dedicated request and response message; no RPC returns a bare domain message or an empty, so responses always have headroom to grow.

## Authentication

1. **Probe** (`AuthService.Probe`, unauthenticated) confirms a URL is a reachable Spalt server and reports its version. Use it before login to validate a server address.
2. **Login** (`AuthService.Login`, unauthenticated) takes a username and password and returns a session token and its expiry. The token is shown once; store it.
3. Attach the token as `Authorization: Bearer <token>` on every subsequent request, RPC and HTTP. An interceptor is the right place for this.
4. On a `401` / `Unauthenticated`, the session is gone (expired or revoked). Drop the stored token and route the user back to login. Do not retry with the dead token.
5. **Logout** (`AuthService.Logout`) revokes the session server-side. **WhoAmI** returns the current user.

Only Login and Probe are unauthenticated. Everything else requires a valid session. Store the token securely (a keychain or equivalent), namespaced per account so two accounts on the same host do not collide.

## The core conversation flow

A conversation is a profile plus a tree of messages grouped into contexts ([data-model.md](../design/data-model.md)). The client drives it through `ConversationsService`:

- **CreateConversation** with a profile id (and optional title and settings) returns the new conversation, its initial context, and any seed messages (the system message, and an optional default user message).
- **ListConversations** is paginated (page size and token), orderable (recently used or recently created), and filterable by title substring or profile. Use it for the conversation list.
- **GetConversation** returns a conversation and its active context.
- **ListMessages** returns the messages of a context. By default it returns the active leaf chain; pass `full_tree` to get every branch, or pin `leaf_message_id` to read a specific branch. Render the leaf chain as the linear conversation; use the tree only if you expose branching.
- **UpdateConversation** (title, settings) and **DeleteConversation** are sparse and self-explanatory.

Contexts and branching: **ListContexts** enumerates a conversation's contexts (live and retired). **SetCurrentLeaf** moves the per-context viewing cursor to a specific message, which is how you navigate between branches. **ActivateContext** re-activates a retired context. Most clients can start by only ever showing the active context's leaf chain and add branching later.

## Sending a message

`SendMessage` does not return the assistant's reply. It is asynchronous:

1. Call `SendMessage` with the conversation id, the content, and optionally a parent message id (to branch), a per-turn provider and model override, call settings, attachment file ids, device facts, and a regenerate flag.
2. It returns immediately with two things: the persisted **user message** and a **stream run** (its id and metadata).
3. Subscribe to the stream run through `StreamsService.SubscribeStream` to receive the assistant's reply as it streams.
4. When the stream terminates, the assistant message is materialized server-side. Either use the streamed content you accumulated, or re-fetch the conversation to get the durable message.

This split is the heart of the resilience model. The run's lifetime is tied to the server, not to your `SendMessage` call or your subscription. You can subscribe, drop, and re-subscribe; the run keeps going.

Editing and regenerating follow the same shape. **EditMessage** mutates a user or assistant message's content (and optionally swaps role between user and assistant); it is rejected if a stream is in flight on that conversation. To regenerate, send with the `regenerate` flag. To branch, send with a `parent_message_id` pointing at an earlier message. **DeleteMessage** takes a cascade flag: false reparents the children, true removes the subtree.

## Streaming and reconnection

`SubscribeStream` is server-streaming. The request carries a stream run id and a `from_sequence`. The response is a sequence of events, each either a **chunk** or the terminal **stream run** record:

- Every chunk has a monotonic `sequence` (per run) and a typed payload.
- The server replays every persisted chunk from `from_sequence` onward, then live-tails new ones, then emits exactly one terminal stream-run event and closes.

The reconnection contract, which you must implement:

1. Track the highest sequence you have applied. Start a subscription at `from_sequence = 0` for a fresh run, or at `last_applied + 1` to resume.
2. On any transport drop before the terminal event, reconnect and resubscribe from `last_applied + 1`. The server replays from the durable log, so resume is correct by construction. Back off between retries and give up after a bounded number of attempts, surfacing an error.
3. Dedupe defensively: drop any chunk whose sequence you have already applied. Resume should not, but a belt-and-braces sequence guard costs nothing.
4. The terminal stream-run event is the definitive end. Its status tells you how the run ended (completed, errored, cancelled, interrupted). After it, the run is done; fetch the materialized message if you need the durable form.

Because the log is durable, opening a conversation whose last run finished while you were away is the same operation as resuming a live one: subscribe from sequence 0 (or your last cursor) and the server replays the whole run, then sends the terminal event immediately. A client should be able to reconstruct any past streamed turn this way.

**CancelStream** cancels an in-flight run (idempotent, safe on an already-terminal run). **ListActiveRuns** returns the user's currently-running runs, optionally filtered by conversation, which lets a client that just launched reattach to runs started on another device.

### The chunk vocabulary

Each chunk has a type. A client must handle all of them, even if only to ignore some:

- `TEXT_DELTA` — append to the visible assistant text.
- `THINKING_DELTA` — append to the reasoning display (extended thinking).
- `THINKING_SIGNATURE` — internal signing data; a client can ignore it for display.
- `TOOL_USE_START` / `TOOL_USE_DELTA` / `TOOL_USE_END` — a tool call being assembled (id and name, then streamed JSON arguments, then close). Show it as a tool invocation in progress if you surface tools.
- `TOOL_RESULT` — the result of a tool call (output or error, with elapsed time). Pair it with its tool-use by id.
- `USAGE` — token counts and usage; drives any live cost display.
- `ELICIT` — the server is asking the user for input mid-run (see Elicitation below). You must respond out of band.
- `DEVICE_TOOL_USE` — the server is asking this client to run a device tool (see Device tools below). You must respond out of band.
- `ERROR` — the run failed; carries an error payload.
- `DONE` — terminal success marker for the run.

A turn that uses tools streams multiple rounds, but the server collapses them: you see one logical stream with interleaved text, tool-use, and tool-result chunks, and exactly one terminal event. You do not manage tool rounds; the server does.

## Cancellation and in-flight rules

Only one stream can be active on a conversation at a time. Mutating operations on a conversation with an in-flight run (edit, compact) are rejected. A well-behaved client disables those affordances while a run is streaming and re-enables them on the terminal event.

## Device facts

`SendMessage` accepts a list of device facts: locale, timezone, platform, and optionally a coarse location (city or coordinates). These let a profile's grounding plugin tell the model where and when the user is. Send the ones you can supply and the user has consented to share; they are per-message, not stored config.

## Device tools

Device tools run on the client, not the server ([tools.md](../design/tools.md)). If your client can fulfill any device tools (calendar, reminders, health, a notes vault, whatever you implement), the flow is:

1. **Register.** Call `DeviceToolsService.RegisterCapabilities` once per session with the tool names you support and a map of client attributes (OS, OS version, app version, device model). `ListSupportedTools` returns the server's catalog with each tool's input schema, so you know what is dispatchable and what shape its input takes.
2. **Receive.** During a stream you may get a `DEVICE_TOOL_USE` chunk carrying a call id, a tool name, and JSON input. Route it to your handler for that tool.
3. **Run.** Execute the tool natively (request OS permission as needed), producing either a JSON output or an error.
4. **Respond.** POST the result to `/conversations/{conversation_id}/device-tools/{call_id}/respond` with a body of `{"output": <json>}` or `{"error": "..."}` (at least one). The server unblocks the waiting tool call and the run continues. The write is once-only; a duplicate post returns 404. You have about 60 seconds before the call times out server-side.

Only register tools you can actually run, and run heavy work off the UI thread. The audit log of device-tool calls is available through `ListDeviceToolCalls` (paginated, recent-first, optionally per conversation) if you want an activity view.

## Elicitation

Elicitation is the server asking the user for input mid-run without that input entering the model's context ([tools.md](../design/tools.md)), used for secrets like an API key. The flow:

1. You receive an `ELICIT` chunk with an elicitation id, a prompt message, and a JSON Schema for the requested input.
2. Render a form from the schema. A string field with `format: password` should be a secure field; the value must never be logged or shown in plaintext history.
3. POST the answer to `/conversations/{conversation_id}/elicitations/{elicitation_id}/respond` with `{"action": "accept"|"decline"|"cancel", "content": {...}}`, where content matters only on accept.
4. The server feeds the answer to the waiting tool and the run continues. Write-once, 204 on success. You have about five minutes before timeout.

The elicited value flows user to server to tool. It is not persisted as message content and does not reach the model, so do not echo it into the transcript.

## File upload and images

Uploading is client-streaming through `FilesService.UploadFile`: send a header (MIME type, declared size, optional filename), then the bytes in chunks. The cap is 50 MB. The server is content-addressed and dedupes on the user plus content hash, so re-uploading identical bytes is cheap and returns the existing file. The response gives you a file id; pass that id in `SendMessage`'s attachment list to attach it to a turn.

Displaying an attached image: a message carries attachment metadata (file id, kind, MIME type, hash, size), not bytes. Call `FilesService.GetFileURL` to mint a short-lived signed URL, then load the bytes over plain HTTP from `/files/{id}?token=...`. The URL is good for a few minutes; if a render happens after it expires, mint a fresh one rather than caching the URL forever. The download endpoint returns 404 for an expired or invalid token, a wrong-owner file, or a missing file, all indistinguishable on purpose.

## Offline behavior

Offline support is a client concern; the server has no offline mode. The reference client does two things you should consider:

- **A read-through cache.** Persist the results of list and get calls locally and serve them when the network is unavailable, refreshing in the background when it returns. Because the server is authoritative, the cache is purely an availability optimization and can be wiped at any time.
- **An outbound queue.** When a `SendMessage` cannot reach the server, queue it locally and drain it in order when connectivity returns, stopping at the first failure so ordering holds. Persist the queue so it survives an app restart.

Neither is required by the protocol. A simpler client can just show an error when offline. But the cache-and-queue shape is what makes the app usable on a flaky connection, and it is safe precisely because the server owns the truth.

## Multi-account

The protocol has no notion of multiple accounts; each account is just a (server URL, session token) pair. A client that supports several should keep them isolated: a separate token store, cache, and outbound queue per account, switchable without re-login. The reference client keeps one in-memory app model per account and switches between them instantly.

## Account events

`EventsService.SubscribeAccountEvents` is a server-streaming push channel for account-level changes (today, profile created/updated/deleted). It has no replay: a subscription delivers events from the moment it connects, and a reconnect starts fresh. Treat it as a hint to refresh, not as a source of truth; the recovery story for a missed event is the same re-fetch you do everywhere. A client can ignore this entirely and just re-fetch on screen entry.

## Settings, providers, and profiles

The remaining services are straightforward request-response CRUD, scoped to the authenticated user:

- **ModelProvidersService** manages provider instances and enabled models: list provider types and templates, create and test a provider, discover and enable models, list all enabled models for the picker, toggle favorites, and read per-provider cost rollups. See [providers.md](../design/providers.md).
- **ProfilesService** manages profiles and their plugin pipelines, including resolving a profile up its inheritance chain (`GetProfile` with resolve), listing plugin types and their config fields, and per-user plugin settings. See [data-model.md](../design/data-model.md) and [plugins.md](../design/plugins.md).
- **EmbedderService** and **LangfuseService** manage the per-user embedder and Langfuse config, each with get / update (sparse, with secret-handling semantics) / delete / test. Secrets are never returned, only a boolean that one is set. See [embeddings-and-search.md](../design/embeddings-and-search.md) and [titles-cost-observability.md](../design/titles-cost-observability.md).

Sparse updates throughout use optional fields plus a `clear_fields` list to distinguish "leave unchanged" from "set to empty / revert to inherited." Honor that distinction in your client: omitting a field and clearing it are different operations.

## Settings resolution on the client

Call settings resolve through four layers server-side (conversation, profile, model, provider; see [data-model.md](../design/data-model.md)), and the resolve endpoints return the merged view. A good client shows the resolved value and labels its source (for example "Enabled (Inherited)") so the user can see what they would be overriding before they override it. Some settings are locked by the model (a fixed temperature, an unsupported parameter); the model's constraints come down with its metadata, and the client should render a locked setting as locked rather than as an editable control. Pushing an unsupported parameter to such a model is a server-side rejection, so respect the constraints in the UI.

## A minimal client checklist

To be correct, a client must: authenticate and attach the bearer token; create and list conversations; send a message and subscribe to its stream; resume a stream from a sequence cursor after a drop; handle every chunk type, including responding to device-tool and elicit chunks out of band; treat the terminal event as authoritative; and re-fetch rather than trust local state after any uncertainty. Everything else (offline, multi-account, branching, cost views, settings editing) is additive on top of that core.
