# lettered_choices

Teaches the model to end each turn with a lettered menu of next moves, then
renders that menu as something the user can tap. Choose-your-own-adventure
scaffolding for an ordinary chat.

## How it works

Three pieces have to agree on one tag pair: the system prompt that teaches it,
the history transform that strips it from old turns, and the display transform
that parses it. Because all three converge, the tag is not user-configurable.
The knob would be more surface than it is worth.

**System prompt.** The prose half ("when and why to offer choices") is
overridable via config. The tag mechanics half is appended at runtime, so a user
can rewrite the prose without restating the format, and a change to the format
does not silently drift away from their override.

**History transform.** Choice blocks older than `keep_last_n` assistant messages
get spliced out of the wire prefix, delimiters included. Old menus are dead
weight: the user already picked.

**Per-turn reminder.** A `[system_reminder ...]` tail is injected onto the head
user message at wire-build time only. Never persisted, never shown on older
turns. It re-grounds the instruction near the top of the model's attention so
long-context drift does not lose the format after a few turns. A matching
explainer in the system slot tells the model what `[system_reminder ...]` means,
without which the model tends to either ignore it or echo it back at the user.

**Output modes.** `text` strips the delimiters and renders the choices inline as
markdown. `component` emits a `choice_list` fragment through the
`ContentRenderer` pipeline, so the client draws tappable buttons that drop the
picked letter into the composer. Default is `text`, so an existing profile does
not silently change render shape on a build update.

In component mode the model emits JSON inside the delimiters, and letters are
not part of it. The server assigns them by index. Less for the model to escape,
less to get wrong, and button labels stay consistent with what the system prompt
taught.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Mode, retention, prose override. |
| `pluginapi.SystemPrompter` | Teaches the convention. |
| `pluginapi.HistoryTransformer` | Prunes stale menus and injects the reminder. |
| `pluginapi.DisplayTransformer` | Strips delimiters in text mode. |
| `pluginapi.ContentRenderer` | Emits `choice_list` fragments in component mode. |

## Config

| Field | Default | Notes |
|---|---|---|
| `keep_last_n` | 1 | Trailing assistant messages whose choices survive into the prefix. 0 strips all. Negative rejected. |
| `output_mode` | `text` | Or `component`. |
| `system_instruction_override` | empty | Replaces the prose half only. |

## Failure modes

- **Model emits no choice block.** Nothing to strip or render. The turn reads as
  ordinary prose.
- **Malformed JSON in component mode.** The renderer leaves the text alone
  rather than dropping the message.
- **Unclosed delimiter.** Same, text passes through.

## Related

`component_builder` is the general form. Use it when the recipe is
user-defined; this plugin when the choice-menu convention is what you want.
