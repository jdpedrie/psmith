# council

A conversation with more than one voice in it. You ask a question, a panel of
personas answers, and then they discuss it. Each member is a profile, so it
brings its own system prompt, model and plugins.

Full design and reasoning: [docs/design/council.md](../../docs/design/council.md).

## The principle

Every voice is a real assistant message, with its own row, model and cost. One
model writing a transcript of a panel into a single message is a prompt you can
have today for free. Separate rows are what make the disagreement real,
individually forkable and separately priced.

The moderator is not a voice. It decides who speaks and for how long, produces
no message, and has no presence in the UI. Its decisions are state.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | The roster and the caps. |
| `pluginapi.TurnRouter` | Picks who answers, before the model is resolved. |
| `pluginapi.SystemPrompter` | One shared roster block, identical for every member. |
| `pluginapi.HistoryTransformer` | Expands each persona turn into its direction plus the message. |
| `pluginapi.PendingStateProvider` | Binds the hop to the assistant message it produced. |

## Why the wire looks like that

Two persona turns must never be adjacent. Nothing rejects that shape, which is
the trap: Anthropic combines consecutive assistant turns into one, so the
structure saying these were different speakers disappears and the model reads a
single long block of its own prior voice. That is the exact convergence a panel
exists to prevent, and it happens with no error to notice.

So each persona turn is preceded by the moderator's direction as a wire-only
user turn. It separates the speakers, gives the length instruction a home, and
carries discipline forward by example: a member told to be brief right after
seeing another member told to be brief and answer in one line complies far more
often than one reading an instruction alone.

Directions are frozen when issued and replayed verbatim. Re-render one and hop
six's build changes hop two's bytes, which invalidates the provider cache from
that point on every send.

## Getting a short answer

Three levers, and only one is a bound. The direction asks. Examples in the
system prompt show the shape, which works better than asking. `max_output_tokens`
per hop actually stops the model, which is the only reason "answer in one word"
is possible at all. The wording and the cap have to agree, or you get
truncation mid-sentence.

## Config

`members` is the roster in speaking order: an auto id, a name, a profile, and a
one-line stance the other members see. `max_exchanges` caps a discussion and is
enforced server-side rather than requested in a prompt, because two agreeable
personas will talk until the money runs out. `opening_tokens` and
`discussion_tokens` bound the first answer and every turn after it.

## Failure modes

- **Fewer than two members.** Every hook no-ops and it is an ordinary
  conversation. Attaching it half-configured is safe.
- **No persistence, exhausted budget, closed discussion, deleted member
  profile, member with no resolvable model.** The router declines and the turn
  falls through to the conversation's ordinary model. Losing the panel beats
  losing the turn.
- **Unparseable state.** Starts a fresh discussion rather than going mute.
- **An assistant message with no recorded direction** (from before the plugin
  was attached, or a welcome message) passes through untouched.
