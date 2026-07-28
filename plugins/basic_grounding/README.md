# basic_grounding

Tells the model the things it cannot know and consistently gets wrong: what time
it is, where the user is, what device they are on. Small facts, wrapped in a
`<grounding>` block attached to each outgoing user message.

## How it works

The block is rendered once, at send time, and persisted in the user row's
`message_headers` column. Never in `content`.

Both halves of that matter.

Persisting to `message_headers` keeps `content` as the user's own words, so
editing, display, TTS and embeddings all see what the user actually typed.

Rendering once at write time is what freezes the wall clock. If we rendered at
history-build time instead, "current time" would tick forward every turn and
invalidate the provider-side prefix cache on every single request. Because the
persisted header is byte-stable after write, this plugin's contribution never
busts the cache as a conversation grows.

Location, locale and platform arrive as device facts. The client gathers them
before each `SendMessage`, and the `RequestedDeviceFacts` list is how it knows
which OS permissions are worth asking for. A fact the plugin does not request is
a permission prompt the user never sees.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Each fact is individually switchable. |
| `pluginapi.MessageEnvelope` | Contributes the persisted header block. |
| `pluginapi.DisplayTransformer` | Strips inline `<grounding>` blocks from legacy rows only. |
| `pluginapi.DeviceFactRequester` | Declares `timezone`, `locale`, `platform`, `location_city`, `location_coords`. |

The `DisplayTransformer` exists purely for history. Before `message_headers`
existed, the plugin rewrote `content` directly, and those rows still carry the
block inline. New rows have clean content and the anchored regex never matches.

The tag pair is stable across releases. Changing it would orphan stripping on
every existing row.

## Config

| Field | Notes |
|---|---|
| `include_date_time` | The core fact. |
| `time_format` | 12 or 24 hour. |
| `timezone` | Override for when the device fact is absent or wrong. |
| `include_locale`, `include_platform`, `include_location` | Each gates a device fact. |

## Failure modes

- **Device fact missing.** The client did not send it, or the user denied the
  permission. The fact is omitted; nothing errors. An absent fact is better than
  a wrong one.
- **Unparseable timezone.** Falls back rather than failing the send.
