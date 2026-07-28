# text_injector

A configurable `lettered_choices`. Every hook it supports is a free-form text
field on the config form, so a user can reproduce that plugin's tactical pieces
(a system instruction plus a per-turn user-message reminder) or build something
else entirely, without writing Go.

## How it works

Each field maps to one hook, and each hook only fires when its field is
non-empty:

| Field | Hook |
|---|---|
| `system_prefix` | `SystemPrompter`, prepend |
| `system_suffix` | `SystemPrompter`, append |
| `user_prefix` | `HistoryTransformer`, prepended to every user message |
| `user_suffix` | `HistoryTransformer`, appended to every user message |
| `user_head_reminder` | `HistoryTransformer`, appended to the head user message only |

Every user-side hook is a `HistoryTransformer`, not a `MessageEnvelope`. That
means the additions ride on the wire prefix and are never persisted to the
`messages` table. The user's history view shows their original text, and future
sends re-render the additions from the live config. Change the config and the
whole conversation retroactively reflects it, because nothing was ever baked in.

All five fields use `MergeAppendString`, so a child profile's contribution adds
to its parent's rather than replacing it. This is the one plugin where layering
composes text instead of overriding it, which is what makes a base profile's
house style survive a child profile adding its own instructions.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Five textareas. |
| `pluginapi.SystemPrompter` | Prefix and suffix on the system slot. |
| `pluginapi.HistoryTransformer` | Everything user-side, prefix-only by design. |

## Config

Five optional textareas, listed above. All blank is a no-op, so the plugin is
safe to attach and leave unconfigured while the user decides what to put in it.

## Failure modes

There is not much to fail. The text is injected verbatim.

- **Contradicting a downstream plugin.** Nothing detects this. If
  `system_suffix` tells the model to ignore formatting instructions and
  `lettered_choices` is also attached, the two fight and the outcome depends on
  the model.
- **Growth through layering.** Because fields append across the profile chain, a
  deep chain can accumulate more instruction than intended. The resolver's
  layered view is the place to check what a profile actually sends.
