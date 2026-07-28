# Plugins

A plugin is a unit of behavior attached to a profile and, through it, to a conversation. Plugins are how Psmith adds capability without bloating the core: a system-prompt injection, a tool, a stream rewriter, a display renderer are all plugins. They register at compile time like providers, they configure per profile, and they compose into an ordered pipeline that the conversations service runs at the right points in a turn. This document covers the code layout, the interface set, the pipeline and its inheritance, where each capability runs, and the shipped catalog.

## Where the code lives

Three packages, split along the line an out-of-tree plugin author would have to cross.

`pluginapi/` is the contract: the `Plugin` interface, every capability interface, `ConfigField`, the registry, and the `Pipeline` fan-out methods. This is what a plugin compiles against, so its dependency set is what ends up in that author's binary. `pluginapi/deps_test.go` pins that set. `WireMessage` and `Chunk` are aliased from `server/providers` rather than redefined, so there is one definition of each in the tree, and they are re-exported public API: changing those structs breaks out-of-tree plugins, with nothing in `server/providers` to say so.

`pluginapi/host/` is the other direction, the capabilities the host provides to a plugin: `Searcher`, `CallerInfo`, `DeviceToolBroker`, `ProviderResolver`, `PluginStateStore`. Interfaces and small value types only, with the concrete implementations server-side and injected on the dispatch context at `server/conversations/tool_loop.go`. The package is held to zero in-module dependencies, because a shim that grows a concrete dependency has stopped being a shim.

`plugins/` is the built-ins, one package per folder, each with a README. It sits at the top level rather than under `server/` because it is a public extension surface and the reference examples for out-of-tree work. Directory names carry underscores to match the registered name (a database value); package identifiers drop them. `plugins/all` is a blank-import aggregator that links the eleven into the binary, since an `init()` only fires if something imports the package. That is a placeholder for today's behaviour, not a design; registration gets rethought with dynamic plugins.

## One plugin, many optional interfaces

Every plugin implements the base `Plugin` interface (a name and not much else). Beyond that, a plugin opts into capabilities by implementing additional interfaces. The framework reflects over which interfaces a plugin satisfies and records them as a `Capabilities` struct, so the pipeline knows what each plugin can do without the plugin declaring it twice. The capability interfaces:

- **Configurable** — accepts per-profile config JSON. Without it, a plugin is config-free.
- **SystemPrompter** — contributes text to the system slot (prepend or append to the persona's system prompt). Runs in the history builder.
- **MessageEnvelope** — contributes header/trailer blocks for a user message on the way out, persisted beside the content (in `message_headers` / `message_trailers`) and composed into the wire text by the history builder. The user's own `content` is never touched, so edit/display/TTS/embeddings see clean text while the envelope stays frozen for prefix-cache stability. (The wire proto still calls this capability `outgoing_user_transformer`; the field predates the design.)
- **HistoryTransformer** — mutates a user or assistant message at prefix-build time, given its position relative to the head. Runs in the history builder.
- **ChunkTransformer** — processes the live chunk stream inside the supervisor. Returns a fresh `InboundProcessor` per stream so per-stream state stays isolated; the processor can buffer and emit zero or more chunks per input and flush residue on close.
- **DisplayTransformer** — rewrites stored content for display at fetch time. Non-persistent and position-independent: same input, same output.
- **AssistantContentTransformer** — rewrites the assistant's finalized text before the row is inserted, so the persisted bytes are the post-transform output forever.
- **TurnContextInjector** — contributes a block of live state for the turn about to be generated. Alone among the prompt-shaping interfaces it receives conversation identity, so a plugin can scope what it injects to the specific branch being continued. Two properties are load-bearing. It is never persisted, because MessageEnvelope output is recomposed into every future prefix and a per-turn state block written that way would accumulate one copy per turn forever. And it lands at the head rather than the system slot: Anthropic's cache breakpoint sits at the end of the last assistant turn, so anything before it must stay byte-identical to stay cached. Changing state in the system slot would invalidate the whole cached prefix every turn, which on turn forty means re-reading the entire transcript at full price. Injected after the breakpoint, only the block itself is uncached.
- **ContentRenderer** — turns message content into a structured list of content parts the client renders with native UI instead of plain markdown. Renderers chain with each other, each seeing the previous one's parts, but they read the ORIGINAL content rather than the DisplayTransformer's output. The two are independent views of the same message, not a pipeline: `display_content` is the flat fallback for a client that cannot draw fragments, `ui_fragments` is the structured rendering. Feeding the second from the first meant a plugin that both strips a block for the fallback and renders it as a component destroyed its own renderer's input, and the content became invisible.
- **StreamingTagProvider** — declares tags the client should treat specially while streaming.
- **MessageLifecycleHook** — runs at message lifecycle points.
- **ToolProvider** — declares tools and executes them. Implementing it makes the profile require the `tool_use` model capability. See [tools.md](tools.md).
- **PendingStateProvider** — hands the runtime state to bind to the assistant message once it exists. Forced by ordering: a tool runs mid-generation, before there is any assistant row to key state to, so the plugin holds its result on the per-send instance and the runtime collects it at materialization.
- **DeviceFactRequester** — declares which on-device facts (timezone, locale, platform, location) the client should gather before each send. A fact no plugin requests is a permission the user is never prompted for, so the list stays short.

`ConfigField` carries two flags that look similar and are not. `Global` is about scope: the value lives at user scope in `user_plugin_settings` rather than on the profile, so it is entered once across every profile that uses the plugin. `Secret` is about sensitivity: the value is a credential and must never leave the deployment, which is what profile export checks. They often coincide (brave_search's `api_key` is both) but not always: mcp's `env` and `headers` are per-instance profile config holding exactly the API keys and bearer tokens you would not want to share. Export skips a key when either flag is set, read from the plugin's own declaration, so a new plugin with a new credential field is covered without changing the export code.
- **CapabilityRequirer** — declares model capabilities the plugin needs, so a send against an incapable model is rejected before it starts.

The split keeps plugins small. A plugin that only injects a system prompt implements one interface; a plugin that does five things implements five. The framework runs each capability only at the point in the turn where it belongs.

## Where each capability runs

A turn touches the pipeline at several points, and each capability has exactly one of them:

- **Prefix build** (history builder): SystemPrompter contributions, HistoryTransformer rewrites, and TurnContextInjector blocks. This is the only place these run. See [history-builder.md](history-builder.md).
- **Outgoing user message**: MessageEnvelope, rendered before persist; composed onto the wire at prefix build.
- **Live stream** (supervisor): ChunkTransformer processors, transforming chunks as they flow.
- **Assistant finalize**: AssistantContentTransformer, before the assistant row is written.
- **Tool dispatch**: ToolProvider execution, inside the tool loop.
- **Fetch / display**: DisplayTransformer and ContentRenderer, when messages are read back. Both read the stored content; neither feeds the other.
- **Lifecycle points**: MessageLifecycleHook.
- **Before the send leaves the client**: DeviceFactRequester, which is the client's cue for what to gather.
- **Assistant materialization**: PendingStateProvider. A tool runs mid-generation, before any assistant row exists to key state to, so a stateful plugin holds its result on the per-send instance and the runtime collects it once the message id is known. Unlike MessageLifecycleHook this runs synchronously, so the state lands before the run closes.

The pipeline is the same ordered list everywhere; each stage just invokes the plugins that implement the relevant interface, in pipeline order.

## The pipeline and inheritance

A profile owns an ordered list of plugin entries, each a plugin type plus its config. Order matters, because transformers chain. The conversations service resolves the pipeline for a turn from the profile chain and any per-conversation overrides, instantiates each plugin from its config, and runs it.

Inheritance follows the profile parent chain ([data-model.md](data-model.md)). A child profile's pipeline is its parent's pipeline plus the child's own entries. A child cannot delete a parent's entry (it does not own it), but it can subtract one by marking it disabled, which drops it from the resolved pipeline. A conversation can override on top of its profile the same way: add a plugin for this conversation only, or disable an inherited one. The resolved view tags each entry with where it came from (profile or conversation) so the client can show the user what is inherited versus local.

## The MCP server registry

MCP is the one multi-instance plugin: one attachment per server, each with its own transport spec and credentials. Pasting that spec into every pipeline that wants the server was the friction, and worse, every attachment shared the pipeline name `mcp`, so the chain merge could not tell two servers apart — a child's Firecrawl row shadowed the parent's Linear row, and disabling "mcp" dropped every server at once.

The registry fixes both. A user registers a server once (`user_mcp_servers`: name plus the same JSON spec shape the mcp plugin's config uses, encrypted at rest). Each registered server then surfaces as a pseudo-plugin named `mcp:<id>` in `ListPluginTypes` — "Firecrawl" appears in every plugin picker like a compiled-in plugin, attachable as a toggle. The pipeline row stores only that reference. At build time the services resolve it through `server/mcpreg`: load the row (owner-checked), decrypt, merge the attach-time config over the spec (non-empty attach values win, which is how a per-attachment `tool_prefix` override works), and hand the result to the ordinary `mcp` constructor. The plugin itself never learns about the registry, and the connection pool still keys on the resolved spec, so two profiles referencing the same server share one live connection.

Reference semantics differ by moment. Attach time resolves strictly — a dangling or foreign id is rejected as `InvalidArgument`. Build time resolves leniently — a reference whose registry row was deleted becomes an unconfigured mcp instance, which no-ops (tools vanish) instead of failing every send on the profile. Secrets are write-only on the wire: list/get return `has_env` / `has_headers` flags, and an absent env/headers field on upsert keeps the stored value, so edit forms never round-trip credentials.

The bare `mcp` type stays registered as the inline-configured escape hatch (one-off local servers, existing rows). Ids, not names, are the identity so renames are free and shared/household registry entries remain possible later.

## Capability requirements

A plugin can require model capabilities through CapabilityRequirer. The canonical case is any ToolProvider requiring `tool_use`. The service combines the requirements of every plugin in the resolved pipeline and checks them against the selected model's capability snapshot before the send. If the model is missing a required capability, the send is rejected with `FailedPrecondition` naming what is missing, so the failure is clear and pre-stream rather than a confusing mid-turn error. This is also why the client filters the model picker to capable models when a tool plugin is attached.

## The shipped catalog

The registered plugins:

- **text_injector** (`text_injector`) — SystemPrompter. Injects configured text into the system prompt. The simplest plugin and the template for the shape.
- **basic_grounding** (`basic_grounding`) — SystemPrompter. Injects grounding context (date, environment) into the system prompt.
- **lettered_choices** (`lettered_choices`) — HistoryTransformer and ContentRenderer. Rewrites recent turns to present lettered choices and renders them as native UI. It skips its history rewrite for Anthropic, because mutating a message inside Anthropic's cached prefix every turn would bust the cache breakpoint; the `DestProviderType` on the history position is what lets it make that call. See [history-builder.md](history-builder.md).
- **component_builder** (`component_builder`) — ContentRenderer. Renders structured components from assistant content.
- **brave_search** (`brave_search`) — ToolProvider. One server tool, `web_search`, over the Brave Web Search API.
- **memory** (`memory`) — ToolProvider. One server tool, `search_history`, semantic-searching the user's own history. Needs an embedder. See [embeddings-and-search.md](embeddings-and-search.md).
- **imagegen** (`imagegen`) — ToolProvider. One server tool, `generate_image`. The only plugin that reports a cost.
- **app_tools** (`app_tools`) — ToolProvider over the device-tools catalog (Calendar, Reminders, Health), routed through the device-tool broker. See [tools.md](tools.md).
- **files** (`files`) — ToolProvider over a bookmarked notes folder on the device (an Obsidian vault is the flagship use; frontmatter preserved, content stays markdown), its own five-tool catalog, sharing the device-tool broker. Shipped as `obsidian` originally; migration 00046 renamed persisted references and the config parser normalizes old `obsidian_*` enabled-keys.
- **game_master** (`game_master`) — ToolProvider, SystemPrompter, AssistantContentTransformer, DisplayTransformer, ContentRenderer, PendingStateProvider. Runs a turn-based management game in the conversation. The plugin owns every rule, stat, die roll and win/loss check; the model writes only fiction and proposes situations in tag vocabulary (a difficulty band, a stakes tier), never integers. It is the first user of branch-scoped `plugin_state`, so forking a conversation forks the campaign. Engine lives in `plugins/game_master/engine/` as pure functions. See [game-master.md](game-master.md).
- **mcp** (`mcp`) — ToolProvider that bridges to an MCP server over stdio, HTTP, or in-process. Proxies the MCP server's tools as Psmith tools. The in-process transport is the elicitation path. Usually attached via the MCP server registry's `mcp:<id>` pseudo-plugins (see above) rather than configured inline. See [tools.md](tools.md) and the MCP section of the API docs.

Alongside these, a few non-plugin support files in the same package are wiring shims rather than registered plugins: `caller_info` and `provider_resolver` and `searcher` and `game_store` thread caller identity, provider resolution, search, and branch-scoped state onto the dispatch context for tools to pull, and `device_tool_broker` is the broker handle. They are not attachable to a profile.

## Adding a plugin

The `/psmith-add-plugin` skill scaffolds a new one. The shape: `plugins/<name>/`, a type implementing `Plugin` plus whichever capability interfaces it needs, `const Name`, an `init()` registering it, and a config struct if it is Configurable. Implement only the capabilities the plugin actually uses; the framework runs each at its proper point. A plugin with tools gets the `tool_use` requirement for free by implementing ToolProvider and CapabilityRequirer.

One step is easy to miss and silent when missed: add the blank import to `plugins/all/all.go`. Without it the plugin builds, tests pass, and it does not exist at runtime. `plugins/all/all_test.go` derives the expected set from the directory listing so the omission fails there instead.

[`plugins/README.md`](../../plugins/README.md) has the conventions; [`pluginapi/README.md`](../../pluginapi/README.md) has the full walkthrough.
