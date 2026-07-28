# Strategy game

A turn-based narrative strategy game that runs inside an ordinary
conversation. The player holds a position of authority — ruler,
commander, colony administrator — and each turn poses a situation with
structured choices that show their real odds. Choices resolve against
dice plus player ratings, effects move persistent stats, and campaigns
end in victory or loss.

The scenario is data, not code. The engine does not know what a medieval
kingdom is; it knows about resources, ratings, difficulty bands and
threshold conditions. A colony under siege and a failing company are the
same machine with different words.

## The principle

The plugin owns every rule, number, die roll and end condition. The model
owns nothing but fiction.

Models narrate well and keep books badly. Ask one to track a treasury
across forty turns and it will drift, quietly, in whichever direction the
story wants. So the model is never asked to produce a figure — not a stat
value, not a cost, not a probability, not a die result. It proposes
situations in a tag vocabulary ("this is a hard check against guile, with
major stakes") and the engine turns those tags into numbers from authored
tables.

That is also why rebalancing a campaign that plays too soft is an edit to
one table in `plugins/strategygame/engine.go` rather than a
prompt-tuning session.

## Where the numbers come from

`plugins/strategygame/` is pure Go with no dependencies on the rest of
the app, so all of it is unit-testable without a database.

**Stats split in two.** Resources are spent and accumulated and run to
the hundreds (treasury, manpower). Ratings are small, move slowly, and
are what gets added to dice (guile, standing). Keeping them in separate
maps is not tidiness: summing a treasury of 4,000 into a 3d6 check is
nonsense, and one flat stat map invites exactly that.

**Resolution is 3d6 plus the checked rating against a target.** Not a
d20. On a flat die every rating point is worth exactly 5% wherever you
stand, so investment is linear and a 95% still whiffs one time in twenty
at full price. On 3d6 a point near the middle of the curve swings about
12% and points at the extremes swing almost nothing, so investing in a
rating matters most when you are near the margin — which is exactly when
the player is making an interesting decision.

**Outcomes are banded by margin**, not pass/fail: disaster, failure,
mixed, success, triumph. Binary resolution hides the difference between a
costly near-miss and a catastrophe, which is most of what makes a choice
interesting. Failure still costs. A bribe that does not work should cost
more gold than one that does, or every risky option is free to attempt
and the decision evaporates.

**Difficulty and stakes are authored tables.** The model picks a band
name (`trivial` through `forlorn`) and a stakes tier (`minor`,
`standard`, `major`); the engine maps those to target numbers and effect
magnitudes. An invented band is rejected, so the vocabulary is enforced
server-side rather than merely requested in the prompt.

**Odds are computed once.** Exactly, from the 3d6 distribution, when the
situation is committed — then stored on the snapshot, displayed from it,
and resolved against it. The number on the button is provably the number
the dice were checked against. Both numbers are shown: a 30% chance with
a 5% disaster tail and a 30% chance with a 40% tail are completely
different decisions, and collapsing them to one figure hides the thing
the player most needs.

**Rolls are deterministic per decision**, derived from
`(seed, turn, situation, choice)` rather than a running generator. Two
branches that make the same decisions see the same dice, so a divergence
is caused by the player's choice and not by the RNG having advanced a
different number of times. A consequence worth knowing: regenerating a
turn re-rolls nothing. The narration changes, the mechanical result does
not. Getting a different outcome means making a different decision.

## State and branching

Campaign state lives in `plugin_state`, keyed to the assistant message
that produced it rather than to the conversation. Psmith conversations
are trees, so this is what makes forking a conversation fork the
campaign: two branches off one decision keep independent lineages and
neither can overwrite the other. Replaying a decision and comparing
outcomes falls out of architecture that already existed for chat.

Reads walk the message parent chain to the nearest ancestor carrying a
row, which absorbs stitch deletes, interleaved non-game messages, and any
turn that failed to bind. The walk stops at a context boundary because
the parent chain does too — compaction seeds a new context with a fresh
root — so carrying a campaign through compaction is an explicit copy.
That copy is not built yet; a campaign that compacts today loses its
mechanical state while keeping its narrative.

The plugin never writes state itself. A tool runs mid-generation, when no
assistant row exists to key state to, so the plugin holds its result on
the per-send instance and the runtime binds it at materialization via
`PendingStateProvider`.

## How a turn works

Attaching the plugin to a profile and opening a conversation is what
decides a campaign exists. There is no start command: the first user
message *is* the scenario brief, and the first assistant turn compiles it
and begins play.

1. The model reads the user's message as a decision (or, on turn one, as
   a scenario) and calls `game_commit_turn`.
2. The engine validates, rolls, applies effects, checks win and loss, and
   returns what actually happened.
3. The model narrates that outcome. The band is authoritative — if the
   engine says disaster, the story is a disaster.
4. At persist time the plugin appends the authoritative status panel and
   choice buttons to the model's prose.

One tool with a `kind` discriminator rather than several, because the
phase gate belongs to the plugin: the model cannot initialize a running
campaign or resolve an uninitialized one, and it does not get to decide
which.

Step 4 is what makes the "model never publishes a number" guarantee
real rather than aspirational. The model writes prose only; the engine
appends the block; a `DisplayTransformer` strips it from the readable
text and a `ContentRenderer` turns it into native components. The model
cannot mistype a figure it was never asked to write.

The rendering reuses the existing `key_value` and `choice_list`
components rather than introducing bespoke ones, so the game plays on
every client with no client-side change. Choice buttons carry a
`send:<id>` action, and because tapping a choice on a scrolled-back
message forks the conversation, alternate-timeline play works out of the
box.

## What is not built yet

Phase 1 is the loop. Deliberately missing: multi-stage situations and
concurrent clocks, delayed and conditional effects, free-text actions
priced on the fly, policies and projects, factions and characters with
loyalty tracked separately from power, and turn capacity limits.

On the durability side: prepared-then-committed transitions with an
idempotency key, optimistic concurrency on `state_version`, the
compaction copy described above, and injecting live state near the
prompt head so the model always has ground truth without a tool call.
That last one has to land after the Anthropic cache breakpoint — state
in the system slot would invalidate the entire cached prefix on every
single turn, which on turn forty of a long campaign is expensive.
