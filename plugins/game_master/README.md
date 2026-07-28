# game_master

Runs a turn-based narrative management game inside an ordinary conversation. Not
an RPG. The player runs something (a city, a company, an expedition) and spends
turns making decisions with costs and consequences.

Full design in [docs/design/game-master.md](../../docs/design/game-master.md).

## The division of labour

This is the whole design. The plugin owns every rule, number, die roll and end
condition. The model owns nothing but fiction.

Models narrate well and keep books badly. So the model is never asked to produce
a figure. Not a stat, not a cost, not a probability. It proposes situations in
qualitative tags ("hard", "major stakes") and the engine turns those into
numbers from authored tables in [`engine/`](engine/).

Resolution is 3d6 plus a rating against a target, read as margin bands:
disaster, failure, mixed, success, triumph. Rolls are deterministic, derived
from `hash(seed, turn, situation, choice)`, so regenerating a message cannot
reroll a bad outcome by accident. Off-menu free-text actions get priced through
the same path as authored choices.

## State

Campaign state lives in `plugin_state`, keyed to the assistant message that
produced it. Forking a conversation forks the campaign, which falls out of the
keying rather than needing its own machinery.

Reads walk the message parent chain to the nearest ancestor carrying state. That
chain does not cross context boundaries: compaction seeds a new head with
`ParentID: nil`. The plugin copies state across the boundary explicitly at
compaction time.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Two presentation toggles. |
| `pluginapi.SystemPrompter` | Teaches the model the protocol and its own narrow role. |
| `pluginapi.ToolProvider` | The engine is reached through tools. Implies `ToolUse`. |
| `pluginapi.AssistantContentTransformer` | Appends the authoritative `<psmith_game>` block to each assistant turn before persist. |
| `pluginapi.DisplayTransformer` | Strips that block from what the user reads. |
| `pluginapi.ContentRenderer` | Emits the state fragments the client renders. |

The instance is built fresh per send and shared across phases, so the tool loop
and the pre-persist transform see the same object. That is how a turn committed
during the tool loop reaches `PendingPluginStates` at materialization.

## Config

| Field | Notes |
|---|---|
| `show_odds` | Surface each choice's success chance, "Choice A, 30% success chance". |
| `show_rolls` | Show the raw dice and margin rather than just the outcome. |

Both are presentation only. Neither changes what happens.

## Failure modes

- **No `CallerInfo` on the context.** Seed derivation fails loudly. It used to
  fall back to a constant, which meant every campaign in the deployment shared
  one dice sequence. A hard error is the correct behaviour.
- **No `PluginStateStore`.** Tools that read or commit state error rather than
  starting a fresh campaign on top of an existing one.
- **Model ignores the protocol.** The engine only acts on tool calls, so a turn
  narrated without one changes nothing. State stays consistent; the turn is just
  wasted.
