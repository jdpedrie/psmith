# Tools

A tool is a function the model can call mid-turn. The model emits a tool-use request, the server runs the function, feeds the result back, and the model continues. Psmith runs the whole loop server-side, so the model sees one linear stream whether the tool ran in Go on the server or on the user's phone. Three kinds of tool exist: server tools (run in the Go process), device tools (run on the connected client), and MCP tools (proxied to an external or in-process MCP server). They all flow through the same loop.

This document covers the tool loop, how tools are collected and gated, device tools and their broker, and elicitation (a tool asking the user for input without the model seeing it). The plugin interface that declares tools is in [plugins.md](plugins.md); the streaming pipeline the loop rides on is in [streaming.md](streaming.md).

## The tool loop

The loop lives in `internal/conversations/tool_loop.go`. It is a decorator around the provider's `Send` function. `SendMessage` builds the wire request, collects the active pipeline's tools into `SendRequest.Tools`, and if that list is non-empty wraps the driver's `Send` in the tool loop before handing it to the stream supervisor. If no plugin contributed a tool, there is no wrapping and the send is a plain pass-through. The supervisor never knows tools exist. From its point of view it consumes one chunk stream and materializes one assistant message.

A single iteration:

1. Open the upstream provider stream.
2. Drain it, forwarding every chunk to the output channel while accumulating round state. Tool-use chunks build up pending calls: `tool_use_start` opens a call, `tool_use_delta` appends to its JSON arguments, `tool_use_end` closes it. Thinking chunks accumulate, and a `thinking_signature` chunk seals a signed Anthropic thinking block so it can be replayed on the next round. The per-round `done` chunk is swallowed, so intermediate rounds never look terminal to the supervisor. An `error` chunk is forwarded and ends the loop.
3. If the round produced no tool calls, the model is finished. Emit one synthetic `done` and close the output. This is the normal exit.
4. Otherwise dispatch each captured call to the plugin that owns the tool name. Build a `ToolResultBlock` from the result: the output on success, the error string on failure. Tool attachments (for example an image a tool produced) ride into the next round's wire prefix for drivers that accept images in tool results, and a copy is persisted. If the tool reported a cost, it is added to the run's tool-cost accumulator.
5. Emit a synthetic `tool_result` chunk for the live UI and for persistence.
6. Grow the request: append a synthetic assistant message carrying the tool-use blocks (and the round's thinking), then a synthetic user message carrying the tool results. Re-issue `Send` with the grown prefix. The model continues from there.

The loop runs up to eight rounds. Exceeding that emits an error chunk, which materializes as an errored assistant message. There is no per-call cap within a round, so one round can carry many parallel tool calls.

### Dispatch

A name-to-plugin map is built once per send by walking the pipeline. On a duplicate tool name the first plugin wins. Before calling `ExecuteTool`, the dispatcher attaches three things to the context: the provider resolver (so a tool can resolve a model), the searcher (so a tool can run semantic search), and caller info (the user, conversation, and active context IDs). Unknown tool names return an error the model sees as an ordinary tool failure.

### What gets persisted

Two independent consumers read the same loop output. The loop emits chunks for the live client. The supervisor's tool-call aggregator re-derives the persisted form from those same chunks, reconstructing each call from its start, delta, end, and matching result, and writes a JSON array to `messages.tool_calls`. A turn with no tool calls writes no array, not an empty one. The aggregator and the loop share no state; the live `tool_result` chunk and the stored `tool_calls` column are reconstructed separately.

On fetch, the column decodes into the `ToolCall` proto on the message (`id`, `name`, `input`, `output`, `error`, `elapsed_ms`, `provider_opaque`). Tool cost lands on `messages.tool_cost_usd` and is folded into `total_cost_usd`. Today only image generation reports a cost.

### Collection and capability gating

Tools are collected by walking the pipeline and asking every plugin that implements `ToolProvider` for its `Tools()`. Each becomes a wire tool definition (name, description, JSON Schema). There is no dedup at collection time, so two plugins declaring the same name put two definitions on the wire, though dispatch routes to the first.

Any plugin that provides tools marks the profile as requiring the `tool_use` model capability. On send, the server resolves the profile's required capabilities, compares them to the selected model's snapshot, and rejects with `FailedPrecondition` naming the missing capability if the model cannot use tools. So attaching a tool plugin to a non-tool model blocks the send before any stream starts.

## Device tools

Device tools run on the user's device, not the server. Calendar, Reminders, Health, and an Obsidian vault on iOS. The server cannot reach EventKit or HealthKit, and the device cannot run a Go plugin, so the server forwards the call to the connected client over the live stream, the client runs it and posts the result back, and the server feeds it into the same tool loop. The model sees a normal server-side tool stream and never knows the work happened on the phone. This is the elicit-broker pattern applied to tools.

### The broker

`internal/devicetools/broker.go`. One broker for the process lifetime. `Invoke` registers a pending call keyed by a fresh UUID with a one-slot response channel, emits a `device_tool_use` chunk describing the call, and blocks on the response channel or a timeout. The default timeout is 60 seconds, larger than elicitation's because some device work (a vault search) is slow. `Respond` matches the UUID, checks the conversation matches, deletes the entry (so a second response is a no-op), and delivers the result. The broker is in memory, so an in-flight call is lost on a server restart and a late response returns not-found.

### The capability handshake

The server only exposes device tools the connected client can fulfill. The client calls `RegisterCapabilities` with the tool names it supports and free-form attributes (OS version, app version). The server keeps an in-memory supported set. Two limitations are worth knowing. First, registration is keyed per user, not per conversation; the binding falls back to the per-user entry, which is where the live set actually lives today. Second, the connected-client filter is applied at execute time, not at tool-advertisement time. The wire tool array uses the plain enabled set, so the model can see a device tool even when no client supports it; the call then fails with a clear "not supported by the connected device" error that the model reads as an ordinary tool failure. A `ToolsForClient` filter exists and is tested but is not wired into the advertisement path.

### The respond endpoint

`POST /conversations/{id}/device-tools/{call_id}/respond`. Bearer-authenticated with the same sessions as the RPCs. The conversation is ownership-checked, and a cross-user or missing conversation returns 404 rather than 403, so the endpoint cannot be used to probe for conversations. The body is `{"output": <json>, "error": "..."}` with at least one of the two present; a blank body is a 400. A successful response is 204. The write is once-only: a second post for the same call returns 404.

### The audit log

Every completed device-tool call writes a row to `device_tool_calls`: the tool name, input, output, status (`ok`, `error`, or `timeout`), and timestamps. The write is best-effort and uses a detached context, because the caller context is already gone on a timeout. The `message_id` is null today, because the assistant message does not exist yet when the call fires; it materializes after the round. The audit surfaces in two places on the client: a per-message section on the assistant turn that triggered the call, and a Settings activity list.

### The catalog

`internal/devicetools/catalog.go` is a hand-curated list in Go, so adding a tool is a server release, not a client release. Each entry carries a JSON Schema, a category, the OS permission it needs, and a default-enabled flag. The default rule is that read-only tools default on and mutating tools default off, so a fresh profile never grants the model write access without the user flipping a toggle. The shipped catalog: Calendar (`calendar_list_events` on by default; `calendar_create_event`, `calendar_update_event`, `calendar_delete_event` off), Reminders (`reminders_list` on; `reminders_create`, `reminders_complete` off), and Health (`health_today_summary`, `health_recent_workouts`, `health_sleep_last_night`, `health_vitals_recent`, `health_query`, all read-only and on by default). Obsidian is deliberately not in this catalog; it is its own plugin with its own catalog, sharing only the broker and wire mechanism.

## Elicitation

Elicitation lets a server-side tool ask the user for input mid-call without that input ever entering the model's context. The motivating case is a secret: a tool that needs an API key asks the user, the user types it into a secure field, the tool uses it, and the key never appears in the prompt or reaches the LLM provider. It is the MCP `elicitation/create` protocol, supported only on the in-process MCP transport.

The mechanism mirrors the device-tool broker. Inside a tool's `ExecuteTool`, the tool calls `Elicit` with a message and a JSON Schema. The elicit broker registers a waiter keyed by UUID, emits an `elicit` chunk, and blocks for up to five minutes (generous, because the user may be fetching a key from a password manager). The client renders a sheet from the schema, the user answers, and the client posts to `POST /conversations/{id}/elicitations/{eid}/respond`. The body is `{"action": "accept|decline|cancel", "content": {...}}`, where content is only meaningful on accept. The endpoint is Bearer-authenticated, ownership-checked with cross-user 404 masking, write-once, and returns 204. The elicited content flows user to server to tool return value; the assistant's eventual text only narrates the result. The `elicit` chunk is an in-flight UI cue, not persisted as message content.

The only consumer today is the `mcp` plugin on the in-process transport. Its tools `create_user_model_provider` and `set_user_plugin_config` elicit secrets so they never enter chat or reach a provider. A tool that needs elicitation but runs on a transport without it degrades with a clear error.

## The tool-providing plugins

Each implements `ToolProvider`. Server tools run in the Go process; device tools round-trip to the client.

- **app_tools** (device). Exposes the device-tools catalog, filtered by a per-tool enabled config. `ExecuteTool` routes through the device-tool broker. The config UI is one boolean per catalog tool, grouped by category.
- **obsidian** (device). Its own five-tool catalog over a bookmarked vault folder: `obsidian_list_notes` and `obsidian_read_note` and `obsidian_search_text` on by default, `obsidian_append_note` and `obsidian_create_note` off. Shares the broker; an unsupported call tells the user to bookmark a vault in settings.
- **brave_search** (server). One tool, `web_search`, over the Brave Web Search API. Config: an API key (a shared per-user global), a default result count, safesearch level, and country. No cost reported.
- **memory** (server). One tool, `search_history`, that semantic-searches the user's own message history through the searcher, scoped to the user, skipping the active context by default. Needs an embedder configured. See [embeddings-and-search.md](embeddings-and-search.md).
- **imagegen** (server). One tool, `generate_image`, that resolves a configured image model and dispatches to OpenAI image generation or Google image output. Returns an image attachment and reports cost, the only plugin that does. The generated image persists on the assistant turn and rides back into the next round for drivers that accept images in tool results.
- **mcp** (server, bridge). Connects to an MCP server over stdio (subprocess), HTTP (Streamable HTTP), or inproc (this Psmith instance's own MCP surface, which is the elicitation path). It snapshots the server's advertised tools, optionally name-prefixed, and proxies calls. See [titles-cost-observability.md](titles-cost-observability.md) and the MCP section of the API docs.

## Cross-cutting notes

- The loop's swallowing of intermediate `done` chunks is what makes a multi-round tool conversation look like one stream to the supervisor. Only the final synthetic `done` reaches it.
- Device-tool and elicitation brokers are both in memory. A server restart drops in-flight calls; a late client response returns 404.
- Two timeouts: device tools 60 seconds, elicitation five minutes.
- Both respond endpoints are write-once, Bearer-authenticated, ownership-checked with cross-user 404 masking, and return 204. The broker's conversation-match check is a second guard behind the endpoint's ownership check.
- Tool-result attachments are persisted after the assistant message materializes: the bytes go to file storage, an idempotent `files` row is created (unique on user plus content hash), and a `message_attachments` row binds the file to the assistant turn with a `tool_result` role hint.
