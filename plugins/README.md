# `plugins/` — the built-in plugins

One package per folder, each with its own README. The contract they implement
lives in [`pluginapi/`](../pluginapi/README.md).

These are also the reference examples for out-of-tree plugins, which is why
`plugins/` sits at the top level rather than under `server/`. A plugin is a
public extension surface, not a server internal.

## What's here

| Plugin | What it does | Capabilities |
|---|---|---|
| [`app_tools`](app_tools/) | Calendar, Reminders and Health tools on the user's device | Configurable, ToolProvider |
| [`basic_grounding`](basic_grounding/) | Date, time, locale, platform and location as a persisted header | Configurable, MessageEnvelope, DisplayTransformer, DeviceFactRequester |
| [`brave_search`](brave_search/) | `web_search` against the Brave index | Configurable, ToolProvider |
| [`component_builder`](component_builder/) | User-defined structured-output recipes rendered as components | Configurable, SystemPrompter, HistoryTransformer, ContentRenderer |
| [`files`](files/) | Read and write a granted folder of markdown or text files | Configurable, ToolProvider |
| [`game_master`](game_master/) | A turn-based management game with the rules held server-side | Configurable, SystemPrompter, ToolProvider, AssistantContentTransformer, DisplayTransformer, ContentRenderer |
| [`imagegen`](imagegen/) | `generate_image`, returned as a tool attachment | Configurable, ToolProvider |
| [`lettered_choices`](lettered_choices/) | A lettered menu of next moves, rendered as tappable buttons | Configurable, SystemPrompter, HistoryTransformer, DisplayTransformer, ContentRenderer |
| [`mcp`](mcp/) | Bridges one MCP server's tools in, over stdio or http | Configurable, ToolProvider |
| [`memory`](memory/) | `search_history`, for recovering compressed-out context | Configurable, ToolProvider |
| [`text_injector`](text_injector/) | Free-form prompt shaping without writing Go | Configurable, SystemPrompter, HistoryTransformer |

`plugins/all` is not a plugin. It is the blank-import aggregator that links the
other eleven into the binary.

## Conventions

**Directory name is the registered name.** `plugins/basic_grounding` registers
as `basic_grounding`. That string is a database value in
`profile_plugins.plugin_name` and `plugin_state.plugin_name`, so it never
changes. `plugins/all/all_test.go` enforces the correspondence.

**Package identifiers drop the underscores.** Directory `basic_grounding`,
package `basicgrounding`. Go style wants one word; the database wants the
readable form. The import line carries an explicit alias where they differ.

**Each plugin exports `Name`.** Not `BasicGroundingName`. The package qualifies
it already.

**Test fixtures stay local.** When these shared one package they also shared
stubs. They no longer do. Duplicating a small `stubDeviceToolBroker` is the
right trade against a shared test-helper package that every plugin then depends
on.

## Adding one

1. `plugins/<name>/<name>.go`, package `<name>` without underscores, with
   `const Name = "<name>"` and an `init()` calling `pluginapi.Register`.
2. Implement `pluginapi.Plugin` plus whichever capability interfaces you need.
   They are all opt-in and detected by type assertion.
3. Add the blank import to `plugins/all/all.go`. Skipping this is silent at
   build time and caught by `plugins/all/all_test.go`.
4. Tests in the same package. Unit tests for pure logic; `pgtestdb` for anything
   touching Postgres.
5. A README covering what it does, which capabilities it implements and why, its
   config fields, and how it fails.

[`pluginapi/README.md`](../pluginapi/README.md) has the full walkthrough of the
capability interfaces, config mechanics, and turn lifecycle.
