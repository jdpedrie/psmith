# context_packs

Splits a profile's background into named packs the user delivers when the
conversation needs them, instead of putting everything in the system message
and paying for it on every turn of every conversation.

## How a pack travels

A delivered pack rides in the user message's `message_headers`, not its
content. The transcript still shows what the user typed, and the history
builder composes the pack into the wire text. Envelope values are frozen at
write time, so a delivered pack is byte-stable on every later prefix build and
does not disturb the provider-side cache — which matters more here than
anywhere, because packs are exactly the large blocks you do not want re-hashed
each turn.

## Two kinds of state, deliberately

**Delivered** is branch-scoped, in `plugin_state`, bound to the assistant
message that closed the turn. Fork a conversation before delivering a pack and
the fork still considers it undelivered, which is the only sensible answer when
that branch never saw the content.

**Armed** is conversation-scoped, in `plugin_conversation_state`. Queued intent
about a send that has not happened is not branch history. Storing it per branch
also made it impossible to queue anything on a conversation with no messages,
since there was no message to key to — and that is the first thing a user does:
open a chat, load the context they know they need, then type.

Delivery checks both. A pack already on the branch is skipped even if something
armed it again, so double-arming is harmless rather than duplicating a large
block into the prefix.

## Capabilities

| Interface | Why |
|---|---|
| `Configurable` | The pack catalog and the announce toggle. |
| `SystemPrompter` | Announces pack names and descriptions, never bodies. |
| `MessageEnvelope` | Delivers armed packs into `message_headers`. |
| `PendingStateProvider` | Records the delivery against the assistant message. |
| `PanelProvider` | Draws the catalog as a `card_list` in the composer's add menu. |
| `ActionHandler` | Handles `arm` and `disarm` from that panel. |

## Config

| Field | Notes |
|---|---|
| `packs` | JSON array of `{id, name, description, body}`. `id` must be unique; duplicates are rejected at construction because they would make the ledger ambiguous. |
| `announce_to_model` | Default on. Puts names and descriptions in the system prompt so the model can say which pack it needs. Bodies never appear. |

The JSON textarea is the known rough edge. The plain `ConfigField` vocabulary
cannot express a list of records, and the alternative was a bespoke form
compiled into every client, which is the coupling the panel system exists to
avoid. A structured editor is the obvious follow-up.

## Failure modes

- **No state store on the context.** The envelope stays silent. Delivering
  without being able to record it would re-send the pack on every following
  turn.
- **Armed pack removed from config.** Dropped quietly at delivery. The
  alternative is failing a send over a config edit.
- **Unknown action.** Returns `ErrUnknownAction`, which the RPC layer maps to
  `FailedPrecondition` — a client newer than the server is a real deployment
  state, not a crash.
- **Unreadable state.** Treated as "nothing delivered yet". Re-sending a pack
  is visible and recoverable; wedging the plugin is not.

## Not built yet

The model cannot request a pack. It is told what exists so it can say which one
it needs, and the user decides. The approval machinery for a
model-asks-user-approves flow already exists in `server/elicit`, so that is a
tool plus an elicitation rather than new infrastructure.
