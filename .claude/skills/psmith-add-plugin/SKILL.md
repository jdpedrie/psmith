---
name: psmith-add-plugin
description: "Scaffold a new Psmith chat plugin under plugins/<name>/ with the right opt-in capability interfaces, registry init, aggregator wiring, and unit tests. Use when adding a new plugin (system prompt injection, tool, history transformer, content rewrite, lifecycle hook)."
trigger: /psmith-add-plugin
---

# /psmith-add-plugin

Adds a chat plugin to Psmith. Plugins are compile-time Go code, one package per
folder under `plugins/`, registering in `init()` and opting into behavior
through interfaces.

Read [`pluginapi/README.md`](../../../pluginapi/README.md) and one or two
existing plugin READMEs before starting. This skill is the checklist, not the
explanation.

## Usage

```
/psmith-add-plugin <name>                 # interactive, asks which interfaces to implement
/psmith-add-plugin <name> --tool          # ToolProvider only (most common new plugin shape)
/psmith-add-plugin <name> --system        # SystemPrompter only
/psmith-add-plugin <name> --history       # HistoryTransformer (re-shapes the wire prefix)
```

## Layout

```
plugins/<name>/<name>.go        # the plugin
plugins/<name>/<name>_test.go   # tests, same package
plugins/<name>/README.md        # what it does, capabilities + why, config, failure modes
plugins/all/all.go              # add the blank import (see below)
plugins/README.md               # add a row to the table
```

Directory name is the registered name and carries underscores, because it is a
database value in `profile_plugins.plugin_name`. The package identifier drops
them: directory `basic_grounding`, package `basicgrounding`. Export `Name`, not
`BasicGroundingName`, since the package already qualifies it.

**The blank import is the step that bites.** An `init()` only fires if something
imports the package, so a plugin missing from `plugins/all/all.go` builds fine,
passes its own tests, and does not exist at runtime. `plugins/all/all_test.go`
derives the expected set from the directory listing and will fail if you forget,
but only if you run it.

## Capability interfaces

`pluginapi.Plugin` is just `Name() + DisplayName() + Description()`. Everything
else is opt-in, detected by type assertion.

| Interface | When to use | Reference |
|---|---|---|
| `Configurable` | Any user-facing knob | `brave_search`, `mcp` |
| `SystemPrompter` | Add text to the system slot | `lettered_choices`, `text_injector` |
| `MessageEnvelope` | Persisted header/trailer beside an outgoing user message | `basic_grounding` |
| `HistoryTransformer` | Rewrite messages in the wire prefix (never persisted) | `lettered_choices`, `text_injector` |
| `TurnContextInjector` | Contribute a per-turn context block | `game_master` |
| `ChunkTransformer` | Mutate provider chunks before fan-out | none in tree |
| `InboundProcessor` | Observe chunks without mutating | none in tree |
| `StreamingTagProvider` | Declare tag pairs the consumer treats as structured | `game_master` |
| `DisplayTransformer` | Rewrite assistant text for display only | `lettered_choices`, `basic_grounding` |
| `AssistantContentTransformer` | Rewrite assistant text before persisting | `game_master` |
| `ContentRenderer` | Turn tagged regions into `UIFragment` components | `lettered_choices`, `component_builder`, `game_master` |
| `ToolProvider` | Tools the model can call | `brave_search`, `mcp`, `memory` |
| `PendingStateProvider` | Bind state to the assistant message being written | `game_master` |
| `MessageLifecycleHook` | Fire-and-forget after a message persists | see `pluginapi/hooks_test.go` |
| `DeviceFactRequester` | Declare which on-device facts the client should gather | `basic_grounding` |
| `CapabilityRequirer` | Require model capabilities beyond the automatic `tool_use` | `imagegen` |

If the plugin has user-facing knobs it MUST implement `Configurable`, or the
attach UI has no fields to render.

## Host capabilities

Things the plugin needs *from* the host arrive on the dispatch context, from
`pluginapi/host`: `Searcher`, `CallerInfo`, `DeviceToolBroker`,
`ProviderResolver`, `PluginStateStore`.

Only `ExecuteTool` gets a context carrying identity. Do not expect `CallerInfo`
anywhere else, and fail loudly rather than falling back if a capability you need
is absent. A silent fallback here once meant every campaign in the deployment
shared one dice seed.

## Playbook

1. **Type + constructor.** `func newMyPlugin(configBytes json.RawMessage) (pluginapi.Plugin, error)`. It must accept nil/empty config and return a usable instance with defaults populated: `Describe` relies on that to introspect metadata without a hand-crafted sample config.
2. **Register.** `func init() { pluginapi.Register(Name, newMyPlugin) }`. `Register` panics on duplicate names, empty names, or nil constructors, so mistakes surface at boot.
3. **Aggregate.** Blank import in `plugins/all/all.go`.
4. **Implement Plugin**, then only the capability interfaces you actually use.
5. **Configurable.** `ConfigFields() []ConfigField`. Types are `text`, `textarea`, `number`, `boolean`, `select`, `model_picker`. There is no password type. For a credential set `Global: true`, which moves the value to user scope in `user_plugin_settings` so it is entered once across every profile, and clients render it on a separate settings surface. Use `Category` to group related fields, and `Merge: MergeAppendString` on text fields that should accumulate down the profile chain rather than override.
6. **Concurrency.** Instances are built fresh per send but shared across the phases of that send, so the tool loop and the pre-persist transform see the same object. Per-turn state in the instance is fine and is how `PendingStateProvider` works. State that must outlive the send goes in `host.PluginStateStore`, never a package global.

## Tests

The repo uses stdlib `testing`. No testify, no `require`. Match the surrounding
style:

```go
func TestMyPlugin_Describe(t *testing.T) {
	d, err := pluginapi.Describe(Name)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}
	if !d.Capabilities.ToolProvider {
		t.Errorf("expected ToolProvider capability")
	}
}
```

Fixtures stay local to the package. When the plugins shared one package they
also shared stubs; they no longer do, and duplicating a small
`stubDeviceToolBroker` beats a shared helper package every plugin depends on.

For a `ToolProvider`, stand up an `httptest` server and assert request shape and
response handling. See `plugins/brave_search/brave_search_test.go`. Never hit a
live service.

For anything touching Postgres, use `pgtestdb`.

## Verification

```bash
go test ./plugins/... ./pluginapi/...   # plugin + contract suites
go test ./plugins/all/                  # catches a missing blank import
make run
```

Then attach the plugin to a profile in the Mac or iOS app, configure it, and
send a turn.

## Don't

- Don't skip the blank import in `plugins/all/all.go`. It fails silently.
- Don't reach into another plugin's package. If two need the same helper, it belongs in `pluginapi` or is small enough to duplicate.
- Don't add a capability interface for one plugin's needs. The existing set covers everything shipped; `pluginapi/README.md` has the procedure and the bar if you genuinely need another.
- Don't import a service package from `pluginapi`. `pluginapi/deps_test.go` will fail, and it is the reason out-of-tree plugins stay cheap to build.
- Don't do network I/O in `init()` or the constructor. Defer to the first interface call.
- Don't skip tests. CLAUDE.md is unambiguous.
