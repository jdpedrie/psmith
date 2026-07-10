# Plugins

A plugin is a unit of behavior attached to a profile and, through it, to a conversation. Plugins are how Psmith adds capability without bloating the core: a system-prompt injection, a tool, a stream rewriter, a display renderer are all plugins. They register at compile time like providers, they configure per profile, and they compose into an ordered pipeline that the conversations service runs at the right points in a turn. This document covers the interface set, the pipeline and its inheritance, where each capability runs, and the shipped catalog.

## One plugin, many optional interfaces

Every plugin implements the base `Plugin` interface (a name and not much else). Beyond that, a plugin opts into capabilities by implementing additional interfaces. The framework reflects over which interfaces a plugin satisfies and records them as a `Capabilities` struct, so the pipeline knows what each plugin can do without the plugin declaring it twice. The capability interfaces:

- **Configurable** — accepts per-profile config JSON. Without it, a plugin is config-free.
- **SystemPrompter** — contributes text to the system slot (prepend or append to the persona's system prompt). Runs in the history builder.
- **MessageEnvelope** — contributes header/trailer blocks for a user message on the way out, persisted beside the content (in `message_headers` / `message_trailers`) and composed into the wire text by the history builder. The user's own `content` is never touched, so edit/display/TTS/embeddings see clean text while the envelope stays frozen for prefix-cache stability. (The wire proto still calls this capability `outgoing_user_transformer`; the field predates the design.)
- **HistoryTransformer** — mutates a user or assistant message at prefix-build time, given its position relative to the head. Runs in the history builder.
- **ChunkTransformer** — processes the live chunk stream inside the supervisor. Returns a fresh `InboundProcessor` per stream so per-stream state stays isolated; the processor can buffer and emit zero or more chunks per input and flush residue on close.
- **DisplayTransformer** — rewrites stored content for display at fetch time. Non-persistent and position-independent: same input, same output.
- **AssistantContentTransformer** — rewrites the assistant's finalized text before the row is inserted, so the persisted bytes are the post-transform output forever.
- **ContentRenderer** — turns display content into a structured list of content parts the client renders with native UI instead of plain markdown. Runs after DisplayTransformer and chains: each renderer sees the previous one's parts.
- **StreamingTagProvider** — declares tags the client should treat specially while streaming.
- **MessageLifecycleHook** — runs at message lifecycle points.
- **ToolProvider** — declares tools and executes them. Implementing it makes the profile require the `tool_use` model capability. See [tools.md](tools.md).
- **CapabilityRequirer** — declares model capabilities the plugin needs, so a send against an incapable model is rejected before it starts.

The split keeps plugins small. A plugin that only injects a system prompt implements one interface; a plugin that does five things implements five. The framework runs each capability only at the point in the turn where it belongs.

## Where each capability runs

A turn touches the pipeline at several points, and each capability has exactly one of them:

- **Prefix build** (history builder): SystemPrompter contributions and HistoryTransformer rewrites. This is the only place these two run. See [history-builder.md](history-builder.md).
- **Outgoing user message**: MessageEnvelope, rendered before persist; composed onto the wire at prefix build.
- **Live stream** (supervisor): ChunkTransformer processors, transforming chunks as they flow.
- **Assistant finalize**: AssistantContentTransformer, before the assistant row is written.
- **Tool dispatch**: ToolProvider execution, inside the tool loop.
- **Fetch / display**: DisplayTransformer then ContentRenderer, when messages are read back.
- **Lifecycle points**: MessageLifecycleHook.

The pipeline is the same ordered list everywhere; each stage just invokes the plugins that implement the relevant interface, in pipeline order.

## The pipeline and inheritance

A profile owns an ordered list of plugin entries, each a plugin type plus its config. Order matters, because transformers chain. The conversations service resolves the pipeline for a turn from the profile chain and any per-conversation overrides, instantiates each plugin from its config, and runs it.

Inheritance follows the profile parent chain ([data-model.md](data-model.md)). A child profile's pipeline is its parent's pipeline plus the child's own entries. A child cannot delete a parent's entry (it does not own it), but it can subtract one by marking it disabled, which drops it from the resolved pipeline. A conversation can override on top of its profile the same way: add a plugin for this conversation only, or disable an inherited one. The resolved view tags each entry with where it came from (profile or conversation) so the client can show the user what is inherited versus local.

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
- **obsidian** (`obsidian`) — ToolProvider over a bookmarked Obsidian vault on the device, its own five-tool catalog, sharing the device-tool broker.
- **mcp** (`mcp`) — ToolProvider that bridges to an MCP server over stdio, HTTP, or in-process. Proxies the MCP server's tools as Psmith tools. The in-process transport is the elicitation path. See [tools.md](tools.md) and the MCP section of the API docs.

Alongside these, a few non-plugin support files in the same package are wiring shims rather than registered plugins: `caller_info` and `provider_resolver` and `searcher` thread caller, provider-resolution, and search dependencies onto the dispatch context for tools to pull, and `device_tool_broker` is the broker handle. They are not attachable to a profile.

## Adding a plugin

The `/psmith-add-plugin` skill scaffolds a new one. The shape: a type implementing `Plugin` plus whichever capability interfaces it needs, an `init()` registering its name, and a config struct if it is Configurable. Implement only the capabilities the plugin actually uses; the framework runs each at its proper point. A plugin with tools gets the `tool_use` requirement for free by implementing ToolProvider and CapabilityRequirer.
