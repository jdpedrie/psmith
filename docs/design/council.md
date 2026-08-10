# Council mode

A council conversation has more than one voice in it. You ask a question, and
instead of one assistant answering, a panel of personas answers and then argues
about the answer while you watch. You can break in at any point, or let the
discussion run another exchange.

Each persona is a profile: its own system prompt, its own model, its own
plugins. So a council can be three Claudes with different temperaments, or
Claude and GPT and Gemini genuinely disagreeing, or any mix.

## The principle

**Every voice is a real assistant message. The moderator is not a voice.**

Each persona turn gets its own `messages` row, its own `provider_id` and
`model_id`, its own cost, and its own place in the message tree. It can be
forked, edited, retried, and priced exactly like any other assistant message,
because it is one.

The alternative, one model writing a transcript of a panel discussion into a
single message, is a prompt. You can have it today with no code. It looks
similar and it is not the same thing: the voices are one model's impression of
disagreement, they share a token budget, they can't be individually forked, and
the cost is a single line. Council mode exists so the disagreement is real, and
separate rows are the whole mechanism.

The moderator is the other half of that principle. It decides who speaks next
and for how long, and it never says anything. It produces no message row and
has no presence in the UI. Its output is state, not text.

## The hop

A hop is the unit of work:

1. The moderator picks a speaker, a length budget, and whether the discussion
   continues.
2. One stream run generates that persona's reply.
3. One assistant message materializes.
4. The turn ends.

That fourth step is the important one. Nothing is in flight between hops, so
the composer is always live and there is nothing to interrupt. "Let the user
break in at any time" isn't a feature we build, it's what falls out of ending
the turn after every hop.

Continuing is a distinct affordance rather than an automatic loop. The client
renders a chip after each hop; tapping it starts the next hop. Typing instead
ends the discussion and starts a new one.

Mechanically a continue is the regenerate path: parent on the current leaf, no
user row inserted, a synthetic tail on the wire
(`server/conversations/service.go:1511`). It gets its own request flag rather
than reusing `regenerate`, because regenerate means replace this turn and
continue means extend it, and the clients present them differently.

Two clients tapping continue at the same moment must not produce two hops
against the same leaf. The continue carries the leaf id it saw, and the server
rejects it if the leaf has already moved. Losing a race should read as "someone
else continued it", not as a duplicate speaker.

## The moderator

The moderator reads the discussion so far and returns three things: who speaks
next, how long they should speak, and how many exchanges remain. It can also
end the discussion outright.

It runs before the model is resolved, which is the one place in the turn where
nothing currently hooks. `resolveProviderModel` walks per-turn override, then
conversation default, then profile default (`server/conversations/service.go:2002`).
The moderator slots in below the per-turn override and above the conversation
default. Below the override, so "let Historian answer that" still wins when the
user picks a speaker directly.

Every existing plugin capability runs after the model is chosen, so this is a
new interface rather than a use of an existing one.

**It reads rows, not the wire prefix.** Building the wire prefix needs
`DestProviderType`, which needs the model, which is what the moderator is
choosing. Reading a window of `messages` directly breaks the circle, and it's
what we'd want anyway: the moderator only needs the recent shape of the
argument, not attachments, thinking blobs or tool history.

**Two implementations, one interface.** The deterministic router is
round-robin with a length schedule: long opener, then short. The model-backed
router is a cheap model reading a window of the discussion and returning JSON.

Its model comes from a `ConfigFieldModelPicker` on the council plugin, separate
from any member's. It should be a small fast model, and it must never default to
whatever the first member uses: paying opener rates to answer "who talks next"
is the easiest way to make this mode cost twice what it should.

The deterministic one is not a stepping stone. It's the fallback, and we need
it regardless: a moderator call that times out or returns garbage must never
block the panel. Having both behind one interface also makes the model
moderator's contribution measurable rather than assumed. Run the same argument
through both and read the transcripts.

**Latency.** The moderator is a serial round-trip in front of every hop, so a
few hundred milliseconds of dead air after a tap the user already made. It can
be hidden by running the moderator speculatively the moment the previous hop
terminates, so the decision is waiting before the user asks for it. That pays
for a moderator call on every discussion the user abandons. Ship it serial,
see whether it grates, decide then.

## The wire shape

All three drivers map wire messages one to one with no merging. Anthropic's
translator documents the expectation in its own comment ("the alternating
user/assistant message list that Anthropic wants",
`server/providers/anthropic/send.go:386`), and Gemini's `contents` is strict the
same way. Only OpenAI Chat Completions is lenient. So three persona turns in a
row reach Anthropic as three consecutive assistant messages and the request is
rejected: the obvious shape, every persona turn as an assistant message
distinguished by a speaker header, does not survive contact with Claude.

The fix is to put the moderator's direction on the wire as the interstitial
user turn:

```
system     roster, etiquette, length examples
user       What should we do about the migration?
           [panel] Skeptic, at length.
assistant  <speaker name="Skeptic">The rollback story is the problem...
user       [panel] Optimist, briefly. Four exchanges left.
assistant  <speaker name="Optimist">Rollback is solved. The real risk is...
user       [panel] Skeptic, briefly. Three exchanges left.
```

This satisfies alternation, gives the length directive a natural home, and puts
the moderator's voice on the wire without ever creating a message row. The user
never sees any of it: the directions are wire-only, and the speaker tag is
rendered into wire content from the message's `persona`, never into
`messages.content`.

It also carries length discipline forward by example, which is the strongest
argument for it. A persona told to be brief, immediately after seeing another
persona told to be brief and answer in one line, is far more likely to comply
than one reading an instruction alone.

**The merge rule.** A direction placed after a user turn would produce two
consecutive user messages, which breaks alternation just as badly. So when a
direction would follow a user turn, it appends to that turn instead of becoming
its own. That's why the first direction in the example above sits inside the
user's message. The rule is deterministic, so the merged bytes are identical on
every rebuild.

**The freeze rule.** Directions are frozen when issued and replayed verbatim.
Each hop's direction is stored in `plugin_state` alongside the speaker and the
budget, and a `HistoryTransformer` replays it on every rebuild. If a rebuild at
hop six regenerates hop two's direction with different wording, the prefix
changes at position two and every byte after it is a cache miss. This is the
same freeze-at-write-time invariant `message_headers` already has, applied to
something that isn't stored on a message.

**The considered alternative.** Consecutive persona turns could be merged into
one assistant message on the wire, speaker tags intact, rows still separate.
Fewer messages, alternation trivially satisfied. We don't do it because it
loses the in-context example of a short turn being asked for and delivered, and
because merging voices on the wire is the failure mode this whole design exists
to avoid, even where the rows stay separate.

## What this needs elsewhere

Two changes, both generalizations rather than council hooks.

**Messages grow an optional persona.** A `persona` column on `messages` and a
matching optional field on the proto `Message`, defaulting to "Assistant" when
absent. It does two jobs at once, which is why it's the right shape: it's what
`history.Build` renders into the wire as the speaker tag, and it's what the
client renders as the bubble's name. Any plugin can set it; no client learns
what a council is.

For color, the persona carries a palette index alongside the name. A bare name
would leave the client to assign colors by order of first appearance, which
shifts under pagination when an older message loads later and changes what slot
everyone got. Absent index means default styling, so an ordinary assistant
message is untouched.

**The server sends an index, never a color.** That single rule is what keeps
councils from breaking themes. The palette belongs to the client, so a council
built under Sage renders in Nordic's colors when you switch, and a persona can
never specify something that fights the palette.

**`HistoryTransformer` has to go one-to-many.** It is
`TransformHistoryMessage(msg, pos) WireMessage` today, one in and one out
(`pluginapi/prompt.go:174`), so it cannot insert the interstitial directions
this design is built on. Widening the return to `[]providers.WireMessage`
touches three implementors (`lettered_choices`, `component_builder`,
`text_injector`), each of which returns a one-element slice, and turns the
pipeline's fold into a flat-map. That's the whole change, and without it the
wire shape above is unbuildable.

**What we don't need.** An earlier draft had `AssistantContentTransformer`
growing a `(header, trailer)` return so the speaker tag could live in the
assistant row's `message_headers`. With a persona column that's redundant: the
name is already stored, and `history.Build` renders the tag from it. Headers
exist because `basic_grounding`'s envelope contains volatile facts (time,
location) that have to be frozen at write time or every rebuild moves bytes. A
persona name is not volatile.

## Coalescing, and a bug this review found

`history.Build` appends one wire message per stored row and never coalesces
consecutive same-role turns, and neither does any driver. That's already
producing malformed requests today, independent of councils.

Regenerating against an assistant parent skips the user-row insert and parents
the new assistant on the old one, so the stored chain reads user, assistant,
assistant. The service knows this and appends a synthetic single-space user turn
so the prefix doesn't end on an assistant
(`server/conversations/service.go:1738`). That handles the *end* of the array
but not the middle. Do it once and the wire is user, assistant, user, which is
fine. Do it twice on the same branch and the wire is user, assistant, assistant,
user. Anthropic and Gemini both reject that. `ConversationViewModel.swift:1426`
reaches this path.

So `history.Build` wants a normalization pass that coalesces consecutive
same-role wire messages. It fixes the live bug, and it's the safety net for
councils: if a direction ever fails to insert, the request degrades to merged
turns instead of a 400.

## Cache

Council mode multiplies calls per turn, so cache behaviour decides whether it's
usable or a toy. The good news is that the existing placement policy is already
right for it.

**Breakpoint depth is correct for free.** `applyAutoCacheControl` scans from the
tail for the last assistant turn and marks its final text block
(`server/providers/anthropic/send.go:335`). The council wire always ends on a
direction, so the breakpoint lands on the previous persona's message at n-2 and
exactly one message sits uncached. That's the depth we want and it needs no
change.

**Add a second breakpoint.** The code places exactly one; Anthropic allows four.
A council churns the tail far faster than a human conversation does, through
retries, mid-discussion edits, and forks. With one breakpoint at n-2, any churn
in that region cold-starts the entire prefix. A second around n-6 costs one
extra write and turns a cold start into a partial hit. This is what actually
buys stability through n-2 to n-4 rather than n-2 or nothing.

**Default the TTL to an hour.** The default is 5 minutes and the extras already
support `1h` (`providers.CacheTTL1h`). A discussion where you read a long opener
before tapping continue blows through five minutes easily. Council profiles set
the hour.

**The system slot must be shared.** The roster and the panel etiquette go in a
system prompt identical for every persona; identity and length go in the
direction at the tail. Per-persona system prompts thrash when two personas share
a model, because they alternate and each invalidates the other at position zero.
Skeptic writes a lineage at hop one, Optimist's different system prompt misses
it entirely at hop two and writes its own, hop three hits Optimist's, hop four
hits only as far as hop one reached. A shared slot means all four hops extend
one lineage.

**Mixed-provider panels get no sharing, and that's fine.** Claude, GPT and
Gemini cache separately. A persona speaking at hops one and four hits its own
provider's cache as far as hop one reached, then pays for hops two and three.
That's the unavoidable price of a mixed panel, and it's worth stating plainly so
it doesn't read as a bug later.

**What it costs.** Take a six-hop discussion on a 20k-token conversation. Every
hop re-reads the whole prefix, so the naive figure is 120k input tokens plus six
short completions plus six moderator calls. With a warm single-model panel most
of that prefix reads at the cached rate and the real cost lands nearer 20k of
fresh input spread across the hops, which is a rounding error against the
completions. With a three-provider panel each provider sees roughly a third of
the hops, so each pays fresh for what it missed. The cap is what bounds the
worst case, and it's why the cap is enforced rather than requested.

## Personas are profiles

A profile already holds a system prompt, a default model, a plugin set, call
settings, and an inheritance parent. That is a persona in full. A separate
`personas` table would duplicate all of it and immediately need its own
inheritance.

Inheritance is the reason to reuse profiles rather than an accident of it. A
`Council Base` profile carries the shared etiquette, and Skeptic, Optimist and
Historian inherit it and add their slant plus their model. Change the etiquette
once. Export already walks the tree, so a council ships as one bundle.

The roster lives in plugin config, not a new column, and the conversation keeps
its single `profile_id`: the council profile is the conversation's profile. A
`members` list field gets the editor on Mac and iOS for free from
`ListFieldEditor`, gets layered by inheritance, and rides along in export. One
gap: member rows need a profile reference, and the field vocabulary has
`ConfigFieldModelPicker` but no profile picker. That's a small, well-precedented
addition.

Council member profiles get a flag hiding them from the start-a-conversation
picker. Five members would otherwise clutter a list that already runs to
dozens of entries.

## Getting a one-word answer

A persona should be able to answer "Yes." and stop. That is genuinely hard,
because models are trained to elaborate and will elaborate through a polite
request for brevity. Three levers, and only one of them is a bound:

- **The direction.** Necessary, nowhere near sufficient.
- **`max_output_tokens` per hop.** `CallSettings` already merges four layers
  (conversation, profile, model, provider). A per-hop layer on top is the only
  lever that actually stops the model rather than asking it to stop. A brief hop
  caps around 60 tokens.
- **Examples in the shared system prompt.** Two or three one-word exchanges.
  Models copy shape from examples far more reliably than they follow
  instructions about length.

The cap and the direction have to agree or you get truncation mid-sentence. Say
two sentences and cap at 60. Never say two sentences and cap at 4000.

`max_output_tokens` is a request parameter, not part of the cached prefix, so
varying it per hop costs nothing in cache terms.

## Ending a discussion

Three things end one. The moderator decides it's done. The budget runs out. The
user types something instead of continuing.

The budget lives in branch-scoped `plugin_state` bound to the assistant message
each hop produced, the same way game-master binds campaign state. A fork carries
its own remaining count, which is what you want: exploring an alternative
argument shouldn't spend the budget of the branch you left.

A hard cap in plugin config, enforced server-side, is not optional. Two
agreeable personas will happily talk until the money runs out, and the cap is
the only thing standing between a council and an overnight bill. It is a number
we enforce, not a request in a prompt.

Compaction is the one interaction worth naming. A compacted discussion loses its
directions along with its messages, and the summary is a single message, so
alternation resumes naturally on the far side.

## Visual design

Two goals in tension. Personas need to be distinguishable at a glance so a
discussion reads as grouped rather than as a wall. And Psmith has six themes,
each built around one hue plus neutrals, several of which are explicitly
low-stimulus. Dropping five saturated colors into "Nordic Mist" destroys it.

The resolution is to do most of the work with structure, which is
theme-neutral, and use color sparingly and from within the theme.

**Structure carries the identity.** Assistant messages render full-width with
no bubble (`clients/psmithd-ios/PsmithiOS/Chats/MessageRow.swift:160`), so there
is nothing to tint anyway. The persona name replaces the `ASSISTANT` role label
in the slot that already exists, with a filled dot as a monogram. Consecutive
turns by the same persona collapse the label, the way every chat client collapses
repeated senders. A discussion, being a bounded run between two user turns, gets
a light container so it reads as one block and can be skipped without parsing
where it ends.

A thin rail down the left of the message region is the fast-scan cue. It works
where a label doesn't, because the eye tracks a continuous stripe without
reading. Successive personas at the same x with different rails make a
discussion legible as a column.

**Color comes from the theme, and only from the theme.** `Theme` grows a
`personaColors: [Color]` array alongside `accent`, `highlight` and `chrome`,
hand-picked per theme so each palette gets a set that lives inside its own
world. Sage gets moss, olive and slate-green. Nordic gets ice, steel and pewter.
That's six themes times four or five colors times light and dark, which is real
work, but it's the same work that produced the existing palettes and it's the
only approach where both goals hold. Deriving colors by rotating the accent's
hue fails on exactly the themes that need it most: every derived color on Nordic
Mist is another pale icy blue.

The server never sends a color, only the palette index from the attribution
field. So a council authored under Sage renders in Nordic's colors the moment
you switch themes, and no persona can specify something that fights the palette,
because personas don't get to specify colors at all.

Two constraints on those sets. **No persona gets a red, orange or yellow rail.**
Those are reserved app-wide for error, warning and delete, and a persona rail
that reads as an error is worse than no color at all. This bites hardest on
Clay, whose terracotta accent already sits near the warning hue, which is
another argument for hand-picking per theme rather than deriving. And
**`Theme.system` uses the user's own system accent**, unknown at design time, so
it gets a fixed neutral set rather than anything derived.

Color is the scan cue and the name is the information. Anyone colorblind, or
reading in sunlight, gets the full grouping from structure alone.

**Cap the roster at five.** Past that no palette discriminates and the
discussion is unreadable regardless.

**The moderator has no visual presence at all.** No rail, no color, no label, no
row. The continue chip is neutral system chrome and shows the discussion's
remaining exchanges, because that's the user's own spend rather than the
moderator's voice.

## What is not built yet

Nothing. This document is the design; no code exists.

The persona column, the `HistoryTransformer` widening and the coalescing pass
come first. Nothing else can be built on top of them, and the coalescing pass
is worth landing on its own regardless. Then the roster, the router interface with the deterministic
implementation behind it, interstitial directions with the merge and freeze
rules, per-hop `max_output_tokens`, the continue chip, and the hard cap. The
model-backed moderator is the second implementation of an interface that already
has a working one under it.

The visual layer splits cleanly: the persona name and the rail work for any
plugin that sets the field, and `Theme.personaColors` is independent of every
other part of this.

Deliberately deferred:

- **Model-requested speakers.** A persona asking for another persona to weigh
  in, subject to the user approving it.
- **Speculative moderation.** Worth it only if the serial round-trip proves
  annoying in practice.
- **Personas with different tool sets.** Falls out of personas being profiles,
  but the cost and confusion of a panel where only one member can search wants
  its own thinking.
