# Providers

A provider is how Psmith talks to a model backend. There are three layers to keep straight: the **driver** is compiled-in Go code that speaks one backend's wire format; a **provider instance** is a user's configured connection to a backend (a base URL and a credential); and an **enabled model** is a snapshot of one model the user has turned on under an instance. The driver is code, the instance and the model are rows. This document covers all three, the model-metadata catalog, the stateless-versus-stateful split, and the per-driver behavior.

## Drivers

A driver implements the `Provider` interface in `server/providers/providers.go`: `Type()`, `Stateful()`, `DiscoverModels()`, and `RenderThinkingToText()`. Each driver lives in its own subpackage and registers itself in `init()` under a type string. Five are shipped, three stateless and two stateful:

- **anthropic** — Anthropic Messages API.
- **openai-compatible** — any OpenAI-shaped backend (OpenAI itself, Azure, OpenRouter, local servers, and so on), covering both Chat Completions and the Responses API.
- **google** — Google Gemini.
- **claude-code-subprocess** — the local `claude` CLI, driven as a harness.
- **codex-app-server** — the local `codex` binary over its app-server JSON-RPC.

The registry is a compile-time map. `Register(typeName, constructor)` panics on a duplicate so a collision fails at startup, and `Build(typeName, deps, config)` instantiates a driver from a type string, a `Deps` struct (the model-metadata catalog and a logger), and the instance's config JSON. `IsRegistered` lets the settings RPCs validate a type before persisting. Adding a backend means writing a new subpackage and registering it; nothing else in the system needs to know the type string ahead of time.

## Provider instances

A provider instance (`user_model_providers`) is a user's configured connection: a driver type, a label, a base URL, and an encrypted credential blob. The credential is encrypted at rest with the master key (see [encryption.md](encryption.md)) and never leaves the server in a response. A user can have several instances of the same driver type (two OpenAI-compatible endpoints with different keys, say), each with its own label and credential.

Instances are created and tested through the model-providers service. The test RPC builds the driver from the row and makes one cheap call to confirm the credential and base URL work, returning success inline rather than as an error so the UI can show a clear result.

## Enabled models

Discovering a backend's models and enabling one are separate steps. For a provider with a catalog identity (Anthropic and Google implicitly; openai-compatible instances via `catalog_provider_id` in their config), the `DiscoverModels` RPC lists the catalog's models for that provider — curated, metadata-rich, and free of the alias noise a live `/v1/models` can leak. For whitelisted driver types whose live listing is clean (`liveUnionTypes`, currently Anthropic), the service additionally asks the driver for its live list and unions in anything the catalog snapshot hasn't picked up yet: a model released hours ago exists on the provider's API before models.dev catalogs it, and it must still be discoverable. Live-only entries carry driver-source metadata (no pricing or limits) until the catalog catches up, and a live-listing failure just serves the catalog list. Providers with no catalog hint at all (LM Studio, Ollama, custom endpoints) use live driver discovery alone. The user then enables specific models, which snapshots them into `user_models` rows.

The snapshot matters. An enabled model carries its own copy of pricing (input, output, cache-read, and cache-write per million tokens), its capabilities, and its default call settings, frozen at enable time. A turn is costed against that snapshot, so an upstream price change does not silently rewrite past turns, and the model picker does not depend on a live network call. Re-running discovery and re-enabling refreshes the snapshot.

For models neither the catalog nor discovery knows — brand-new releases, fine-tunes, gateway aliases — `AddManualModel` creates a `user_models` row from user-supplied metadata (`metadata_source = 'manual'`). Both the Mac and iOS clients expose it as "Add custom model" on the provider detail.

Turning a model off depends on where its row came from. A catalog or driver row is deleted: discovery offers the model again, and turning it back on takes a fresh snapshot. A manual row is kept with `enabled = false`, because the user's metadata exists nowhere else and no listing would bring it back. `GetUserModelProvider` returns those rows as `disabled_models`, beside `enabled_models`, so Settings can list them switched off, and `EnableModels` turns one back on as it was rather than re-snapshotting. Everything that offers or uses a model skips them: `ListAllUserModels` and `ListUserModels` (the pickers), and the send, compaction, and context-port checks, which resolve through `GetEnabledUserModel`. Cost accounting still reads the row, so a turn already in flight when its model goes off is priced. `DisableModels` with `delete_manual` deletes a manual row outright; that's the iOS "Delete Model".

## The model-metadata catalog

`server/modelmeta` holds a `LiveCatalog` that enriches discovered models with metadata (context window, capabilities, pricing hints) from models.dev. It is lazy: it fetches on first use and caches in memory, with no background ticker and no catalog tables in the database. The snapshot carries a max age (12h): the first lookup past it re-fetches in-line while concurrent callers serve the stale copy, a failed refresh serves stale and backs off five minutes before retrying, and the explicit Refresh RPC still forces a fetch. Without the max age a long-running daemon served its launch-day model list forever, which is how "the new model isn't in discovery" happened. `DiscoverModels` is handed the catalog through `Deps` so a driver can enrich its raw model list with the metadata models.dev knows.

Separately, `ConstraintsFor(providerType, modelID)` returns hard constraints a model imposes on call settings, resolved by exact match, then model-id prefix, then provider-type default. The shipped case: OpenAI's gpt-5 and o-series models lock temperature at 1.0 and reject an explicit `temperature` or `top_p`. The catalog encodes that as a locked-at constraint, the OpenAI driver omits the sampling parameters for those models, and the client renders the setting as locked rather than as an editable slider. This is why a model can show a fixed setting that the four-layer resolution cannot override.

## Stateless versus stateful

The interface splits on who owns history.

A **stateless** provider implements `Send(ctx, SendRequest)` and gets the full wire prefix every turn. The server owns history, builds the prefix from the message tree ([history-builder.md](history-builder.md)), and sends it whole. All three shipped drivers are stateless. This is the model that makes Psmith's stream resilience work: because the server holds the authoritative history and re-sends it, a turn does not depend on any provider-side session surviving.

A **stateful** provider implements `StartSession` / `SendInSession` / `TerminateSession` and gets only the newest message. The harness holds the transcript. `claude-code-subprocess` and `codex-app-server` are both stateful; you are borrowing a coding agent's local session, and there is no wire format that would let us hand it a prefix.

A driver can optionally implement `TokenCounter` (count tokens for a candidate prefix, used to inform compaction) and `ExplicitCacheProvider` (server-managed explicit caching).

## The stateful send path

The problem with a backend that owns history is that Psmith owns history too, and the two will disagree the first time a user edits an old message. The fix is to never reuse a session: **every turn forks**, and the handle the fork produces is stored on the assistant row that turn produced (`messages.harness_handle`).

That one decision buys the rest. A handle names the harness state *including* the turn it sits on. To send message N+1 you walk up from its parent to the nearest ancestor carrying a handle and fork from there, so:

- Continuing a conversation finds the tip's handle and extends it.
- Regenerating an old turn finds the handle at *that* point in the tree and forks from there. The abandoned turns are not in the state it forks from, because they were never in it.
- Two branches off one parent each resolve to their own handle. Branching in the message tree is branching in the harness, for free.
- No handle above you means no session yet, which is the signal to open one.

`SendMessage` takes the stateful branch when the built driver satisfies `StatefulProvider`. What that branch does differently:

| | Stateless | Stateful |
|---|---|---|
| Wire prefix | the whole chain | the newest message only (`history.Params.LatestOnly`) |
| System prompt | assembled per turn | resolved once, pinned at `StartSession` |
| Tools | sent | dropped; the harness runs its own |
| Attachments | inlined or uploaded | refused |
| Explicit cache | driver's hook | skipped; the harness caches its own |

The history walk still runs in full even though the result is thrown away. It is what proves the leaf is reachable and inside the active context, and skipping it would trade one cheap query for the ability to send into the wrong conversation.

### What this costs

These are consequences of borrowing someone else's session, not bugs to be fixed later.

**The system prompt is fixed for the conversation's life.** The harness pins it when the session opens. Editing the profile afterwards changes nothing until a new conversation starts.

**You cannot switch providers mid-conversation.** Choosing a harness commits the conversation to it. There is no prefix to hand a different backend, because Psmith never built one. `checkHarnessBinding` enforces this in both directions, before the user row is written: a bound conversation refuses any other provider, and a conversation a regular provider has already answered refuses a harness, because the harness's transcript would start at the switch and never see what came before.

**Editing an assistant turn and resending drifts.** The handle names the state containing the *original* text. The harness has no way to be told it changed, so the edit shows in Psmith's history and not in the harness's.

**Attachments are refused.** Neither driver reads `WireMessage.Attachments`, so the bytes would be loaded out of storage and dropped. The send is rejected before the user's message is persisted: a dropped image reads as the model ignoring it, which is worse than an error.

**Plugin capabilities that operate on history do not fire.** `HistoryTransformer` sees one message. `SystemPrompter` contributions are dropped, since there is no per-turn system slot to put them in. `ToolProvider` tools are dropped. What still works is anything that acts on the outgoing message or on state: `MessageEnvelope`, `TurnContextInjector`, `InboundProcessor`, `DisplayTransformer`, the lifecycle hooks.

**Provisional handles do not survive a restart.** `StartSession` returns a provisional handle that becomes durable only once the harness mints a real session on the first turn. A crash in between leaves nothing to resume.

### What the clients do about it

The server refuses every one of these regardless of what a client does. The UI exists so the user meets the rule before the error, not after.

`Conversation.harness` carries the binding on the detail reads (`GetConversation`, `CreateConversation`, `UpdateConversation`), populated by `attachHarnessBinding`. It is deliberately absent from `ListConversations`: that would be one query per row to answer a question the sidebar never asks. Absence therefore means "unbound or not asked", so every client treats it as unconstrained and lets the server refuse. A control that quietly lies is worse than one clear error.

The binding carries `system_prompt_frozen` and `accepts_attachments` as fields rather than assuming them from the driver type. Both are true of every harness shipped today, and both are things a driver could grow without a client release.

`ConversationViewModel` derives the affordances once (`canAttachFiles`, `canChangeProvider`, `systemPromptIsFrozen`, `selectableModels`, `harnessNotice`) so Mac and iOS cannot drift on what the rules are; the web client's `harnessVM` is the same shape for templ. What each surface does:

| Surface | Bound behaviour |
|---|---|
| Composer attach control | Absent. On Mac and iOS the existing per-kind capability gate answers false; the web template omits the input entirely. |
| Paste and drag | Refused in the view model before the upload, so no bytes are spent on a send that cannot happen. |
| Model picker | Filtered to the bound provider, with a one-line notice above it. Filtering rather than disabling: a whole provider of dead rows is noise, one absent section plus a reason is a rule. |
| Conversation settings | A card at the top of the call-settings tab explaining all three constraints together. |

Model switching stays available inside the bound provider. The handle encodes the model, so the next turn opens against the new one and both harnesses accept that.

Statefulness on the wire (`ProviderType.stateful`) comes from `providers.IsStateful`, which builds a throwaway driver and asks it. The list it replaced named `codex-subprocess`, a type that never existed, and its test asserted the list's own contents, so it stayed green while every client was told Codex was stateless.

Both drivers pin their sandbox to read-only and their approval policy to never. That is not the operator's setting to make: their CLI config is tuned for an agent editing files with a human at the keyboard, and a chat turn has nobody to approve anything. An unanswered approval request hangs the turn until it times out.

## The send request and chunks

`SendRequest` carries the model id, the wire messages, the resolved call settings, the conversation id (threaded through so a driver can use it as a provider-specific cache key like OpenAI's `prompt_cache_key`), and the tool definitions. The messages are already wire-shaped: role rewriting and cross-provider thinking injection happened in the history builder before the driver sees them. A driver translates the tool definitions into its native shape, or silently drops them if it does not support tools.

`Send` returns a channel of chunks. The chunk vocabulary (text, thinking, tool-use, usage, error, done, and the rest) is shared across all drivers and documented in [streaming.md](streaming.md). Each driver's job is to parse its backend's stream into that common vocabulary so the supervisor and the client never see a provider-specific shape.

## Cross-provider thinking

Extended thinking is provider-specific on the wire. Anthropic emits signed thinking blocks that must be replayed verbatim; other providers represent reasoning differently or not at all. Two mechanisms bridge this. `RenderThinkingToText` converts a stored thinking blob to plain text for injection into a different provider's prefix (deterministic, computed once and cached). And the `thinking_signature` chunk captures Anthropic's block seal during a stream so a later tool round can replay the block intact. The result is that you can branch or continue a conversation across providers and the reasoning history degrades gracefully into text rather than breaking the next turn.

The user-facing thinking control is one effort level: off, low, medium, high, or extra high. Nobody sets a token budget. The level is what every current API takes (OpenAI, xAI, Anthropic's adaptive models) and the vocabulary users reason in; Claude's own apps expose nothing finer. Drivers translate it. OpenAI's two surfaces, and every OpenAI-compatible endpoint routed through Chat Completions, get `reasoning_effort` verbatim, so a Grok 4 model that defaults to high can be turned down. Off is sent as low on models the constraints table knows cannot stop reasoning and omitted on models it does not know, where the model keeps its default. Anthropic's adaptive models get `output_config.effort` verbatim. The legacy Anthropic shape and Gemini derive a budget from one table in `server/providers` (2048, 8192, 16384 and 24576 tokens), sized to clear Anthropic's 1024 floor and fit under Gemini 2.5 Flash's 24576 ceiling so the top level never has to know which model it lands on. Off is honoured where the API can stop the model and means the closest thing elsewhere: Gemini 2.5 and later keep thinking with the thoughts hidden.

Anthropic's request shape for thinking also split by model generation: older models take `thinking: {type: "enabled", budget_tokens: N}`, newer ones (Fable 5 / Opus 4.7 onward, Sonnet 4.6 onward) reject that with a 400 and require `thinking: {type: "adaptive"}` plus `output_config.effort`. The driver picks the first attempt from a per-model prefix table (`thinking_shape.go`) and, because the table is a guess, not a contract, retries a shape-mismatch 400 once with the other shape, before any output has streamed. A brand-new model the table doesn't know costs one doomed request and then works. On the legacy shape the derived budget is added on top of `max_tokens`, since the API charges thinking against it: a user who asked for 4096 tokens of answer at high effort still gets 4096 tokens of answer.

The same generation locks temperature at 1.0 (any other value 400s). The constraints table encodes that as a LockedAt temperature for the affected prefixes — the same single source of truth the clients read to render the slider locked and the openai driver already uses for gpt-5/o-series — and the anthropic driver omits the temperature parameter for those models. For a model the table doesn't know yet, the send-time remedy loop catches the sampling-rejection 400 and retries once with the sampling knobs stripped. The remedies compose: an unknown model needing both the adaptive flip and the sampling strip recovers in three requests, invisibly.

## Explicit caching

`ExplicitCacheProvider` is the optional interface for server-managed explicit caching, where the conversations service orchestrates the lifecycle (look up a stored ref, check expiry, check that the prefix hash still matches, then attach or create-and-store) and the driver provides three primitives: create a cache over a prefix, apply a valid ref to a request and trim the covered messages off the tail, and delete a ref. Two mechanisms fit the same shape: Gemini's upstream `cachedContents` resource (a real create and delete against the backend) and a future Anthropic explicit-cache toggle (stateless `cache_control` breakpoint placement, where create returns a sentinel and delete is a no-op). Drivers that do not implement the interface are silently no-op'd when the toggle is on.

## Adding a provider

The `/psmith-add-provider` skill scaffolds a new driver. The shape is always the same: a subpackage with a `Driver` type implementing `Provider` and `StatelessProvider`, an `init()` that registers the type string, a config struct unmarshaled from the instance's JSON, a `DiscoverModels` that lists and enriches models, and a `Send` that translates the backend's stream into the common chunk vocabulary. Tests point the driver's base URL at the fake LLM ([building-and-codegen.md](../operations/building-and-codegen.md)) and exercise the real parsing path.

## Model capability probing

Capabilities on a `user_model` come from catalog metadata and hand-editing, so they are a claim. Claims go stale, catalogs lie by omission, and a custom endpoint has no catalog at all. The failure is asymmetric: a capability the model has but we do not know about stays switched off, and `validateModelCapabilities` then refuses sends that would have worked.

`ProbeUserModel` is the empirical counterpart to `RefreshUserModelMetadata`. That re-reads what the catalog claims; this reports what the model does, by making it do it.

**One probe per capability.** Streaming asks for a word and checks text arrived over a stream. Tool use declares one trivial tool and checks for a tool call. Vision attaches a 1x1 PNG, the smallest thing that is unambiguously an image. Thinking enables reasoning and checks for reasoning chunks.

Two are skipped, and say so. Prompt caching would need two calls with a prefix over the provider's minimum, which costs more than the answer is worth. Generated images would bill for an image and the response shape is not comparable across providers. Skipped is a distinct outcome from inconclusive on purpose: "we did not ask" and "we asked and could not tell" are different answers, and collapsing them would read as a checked-and-found-nothing.

**Additive only.** A probe may switch a capability on and may never switch one off. Three reasons that point the same way: an unsupported verdict can come from a quirk of the probe's own prompt, a user may have set the flag deliberately and know something the probe does not, and clearing a flag silently breaks sends that were working. The asymmetry is the feature. A probe that can only help is one you can run without reading the code first.

Contradictions are still reported. A model marked vision-capable that rejects an image is worth knowing about even though the server will not act on it, so the response carries a `contradicted` list and the clients render it as information with the fix left to the user.

**Inconclusive is the default outcome.** Anything that does not clearly demonstrate support or clearly demonstrate refusal lands there, including every network failure, timeout and rate limit. A bad minute must never be recorded as a fact about a model. Only a refusal that names the capability in its own error text counts as unsupported, and the matching is deliberately narrow: matching loosely would turn an unrelated 400 into a recorded verdict, which is the one mistake that makes a probe worse than no probe.

**User-triggered, dry run first.** Every probe bills a few tokens on the user's own key, so spending their money on a background sweep nobody asked for is not a trade to make on their behalf. `apply` defaults to false, so the first call reports what it would change and changes nothing.

## Provider-side attachment uploads

History assembly inlines every attachment in a conversation on every send, so
one image is base64'd and pushed upstream once per turn for the life of the
chat. `providers.FileUploader` is the optional interface a driver implements to
take the bytes once and be handed a reference thereafter.

Google implements it today, through Gemini's Files API. It is the provider
where this matters most: Gemini has no implicit prompt cache to blunt the cost
of resending, so an image in a long conversation is re-uploaded and re-charged
on every turn. Anthropic and OpenAI both have Files APIs and can adopt the same
interface; until they do they keep inlining, which is correct, just chattier.

`provider_files` maps `(user_model_provider, sha256)` to the provider's file id.
Keyed by the provider ROW rather than its type, because an upload lives behind
one account's credentials and is invisible to another. Keyed by content hash
rather than by message, because blobs are content-addressed and one upload
serves every message that references the same bytes, across conversations.

**Every failure degrades to inline bytes.** No uploader on the driver, an
unsupported mime type, an upload error, a database error, a reference past its
expiry: each leaves the attachment's bytes intact and the driver sends them the
old way. A Files API outage costs bandwidth, never a turn. That is what makes
this safe to have on by default.

Uploads happen inline before the model call, bounded by a deadline, because a
slow Files API would otherwise be felt as the send hanging. Past the deadline
the turn inlines, which is the same outcome as not having the feature.

Expiries come from the provider rather than being assumed, and stale rows are
filtered at read time as well as swept on the stream-chunk cleanup cadence, so
a lagging sweep is never a correctness problem.
