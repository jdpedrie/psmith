# Auto-titles, cost, and observability

Three subsystems that hang off the end of a turn: a small model names the conversation, a ledger records what the turn cost, and a tracer ships the turn to Langfuse. All three fire from the supervisor's post-materialization hooks, all three are best-effort, and none of them can fail a turn.

## Auto-titles

When the first assistant message of a conversation lands, the server names the conversation and the context. The logic is in `internal/conversations/titles.go`, dispatched in a detached goroutine so a slow title model never holds up the stream.

Two titles get decided independently. The conversation title is generated when the conversation has none. The context title is generated when the context has none and this is the first assistant turn in that context, which catches both the opening context and every context created by compaction. The first-assistant guard counts assistant rows in the context and only proceeds when exactly one exists, the one just inserted. Without that guard the server would regenerate and pay on every turn until a title stuck, which is the wrong cost shape.

The title model is resolved from the profile chain: a title provider, a title model, an optional guide, and a title provider kind. The guide defaults to "Generate a 2 to 5 word title, reply with only the title, no quotes, no punctuation, no preamble." The call builds a two-message transcript (the most recent user message plus the just-materialized assistant message), loads and decrypts the title provider, builds the driver, and sends it synchronously, draining the chunk stream into a string. It does not go through the supervisor.

The result is sanitized: trim whitespace, strip one layer of wrapping quotes, collapse internal whitespace, cap at 80 characters on a word boundary. Whatever survives is written with `UpdateConversationTitle` or `UpdateContextTitle`, and a `title`-tagged Langfuse trace is mirrored best-effort.

### The client-side title sentinel

If the resolved profile carries a non-empty title provider kind, a client owns titling for that profile and the server skips both its cloud roundtrip and its fallback write. The shipped case is `apple_foundation`: the Mac client runs Apple's on-device FoundationModels framework on macOS 26+, names the conversation locally for free, persists through the normal `UpdateConversation` RPC, and owns its own failure fallback. The server stays out of the way entirely.

### The fallback

If titling is not configured, or the model call fails, or the transcript is empty, or the sanitized title is unusable, the server writes a derived fallback instead of leaving a row "Untitled": `"{ProfileName} ({YYYY-MM-DD})"`, using the conversation or context creation date. Each fallback write is independent and best-effort. The point is that an untitled row always surfaces with persona plus date, never a blank.

## Cost tracking

Cost lives in two places: per-message columns on `messages`, which are the source of truth for a single turn, and an append-only `cost_events` ledger, which backs the rolled-up per-provider view in Settings.

### Per-message cost

When a model snapshot is enabled onto a provider, its pricing is copied onto the `user_models` row: input, output, cache-read, and cache-write prices per million tokens. That snapshot is what a turn is costed against, so a later price change upstream does not silently rewrite history. There is no separate reasoning-token price; reasoning tokens are counted on the message but priced at zero.

On stream finalization, `internal/stream/consume.go` writes the usage columns onto the messages row: the token counts, the raw provider usage blob, and a computed cost per category plus a total. Each category cost is `tokens * pricePerMillion / 1_000_000`. Tool cost is the sum of every tool result's reported cost over the tool loop, which today is only image generation. The total sums the valid components. If the model row has since vanished, the token counts are still recorded but the token costs are left null; tool cost still flows. Compression turns compute cost the same way but never carry tool cost.

### The ledger

`cost_events` is append-only. Each row references a provider (cascade-deleted with it), a model, an amount, and an optional message (set-null on message delete, because deleting a message does not unspend the money). It starts empty at migration time with no backfill; per-message history stays on the messages rows and is not retroactively aggregated. On terminal materialization of an assistant or compression turn, the server appends a ledger row whenever the total cost is positive, including errored runs if the provider still charged for tokens. The insert is best-effort: a ledger failure is logged and does not block materialization, because the messages row is the real per-turn record and the ledger only feeds the summary.

`ListProviderCosts` aggregates the ledger per provider over an optional time window. It left-joins so a provider with no events still shows up at zero, and it puts the time-window predicate in the join condition rather than the where clause, because a where-clause window would silently drop providers that had no events in the window. The handler sums a grand total across providers and returns one row each, sorted by label for stable ordering. This drives the Settings cost screen.

## Langfuse tracing

Langfuse is per-user, opt-in, and fully out of the hot path. A user who has not configured it pays nothing: the emit calls look up the user's cached config and return immediately with no allocation and no database hop when it is absent or invalid.

### Config

`user_langfuse_config` holds one row per user: host (defaulting to the US cloud), public key, an encrypted secret key, and an enabled flag. The secret is never echoed back; the get RPC returns a `has_secret_key` boolean instead. Update is tri-state on the secret (leave it, clear it, or replace it), trims a trailing slash off the host, and refuses to enable without both a public key and a secret. Saving refreshes the emitter's cache so the next turn uses the new credentials. There is a test RPC that spins up a throwaway one-shot emitter, sends a synthetic trace, and reports success with latency. On startup, every existing config row is loaded into the emitter cache, because otherwise the first turn after a restart would emit nothing until the user touched the settings.

### The emitter

`internal/langfuse` is an async batching client. It POSTs to the Langfuse ingestion endpoint with HTTP basic auth (public key as user, secret as password), a batch of events per request. There are three event types: a trace per assistant turn (session ID set to the conversation ID, so a chat groups), a generation for the LLM call (input prefix, output text, model, token usage, pre-computed cost), and a span per tool call (marked error-level with a status message on failure, so it renders red).

The emitter flushes every 5 seconds or at 32 queued events, with a bounded queue of 1024. Enqueue is non-blocking: if the queue is full, the event is dropped with a warn rather than blocking the supervisor goroutine. There are no retries; a failed POST is logged, and a restart drops anything unflushed. This is acceptable because tracing is observability, not accounting. The ledger above is where money is tracked, and it is durable.

### What gets traced

The assistant emit happens in the per-run hook so it can include the buffered tool spans. It skips errored runs entirely. It builds the trace from the parent user message, sets the generation's tokens and cost from the message columns, and adds one span per tool call carrying the model's arguments as input and the plugin's JSON return as output, error-flagged on failure. Titles and compression get their own traces in the same session, with derived suffixed IDs so they do not collide with the assistant turn. The process-wide post-persist hook today fans out only auto-title generation; the Langfuse assistant emit moved to the per-run hook precisely so the tool spans would be available to attach.
