# Game master

A turn-based narrative management game that runs inside an ordinary
conversation. The plugin is the game master: it holds the rules, the
dice and the ledger, and the model supplies the voice.

Naming note, because the genre label matters here. This is not a strategy
game in the Civilization sense — there is no map, no build order, and the
player picks from a handful of authored options rather than planning
across a space they control. Nor is it a simulator: nothing is modelled
underneath, and stats move because an authored table says so rather than
because an economy computed it. The family is Reigns and King of Dragon
Pass, and the machinery is tabletop-derived (the clocks are Blades in the
Dark clocks; 3d6 against a target read by margin is close to how PbtA
games resolve). What the plugin provides to a conversation is a game
master, which is what it is named for. The player holds a position of authority — ruler,
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
one table in `plugins/game_master/engine/engine.go` rather than a
prompt-tuning session.

## Where the numbers come from

`plugins/game_master/engine/` is pure Go with no dependencies on the rest of
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
root — so carrying a campaign across one is an explicit copy, made inside
the transaction that creates the context so the new context never exists
without its state. The same applies to a manual context switch.

Which snapshot gets copied is the subtle part. A context can hold several
leaves, and the copy has to take the one on the same chain the summary
was written from, not simply the newest row. Taking the newest would hand
the player mechanical state from a branch they abandoned while the
summary describes the branch they actually played, and nothing about the
mismatch would be visible.

The plugin never writes state itself. A tool runs mid-generation, when no
assistant row exists to key state to, so the plugin holds its result on
the per-send instance and the runtime binds it at materialization via
`PendingStateProvider`.

## Clocks

A situation the player cannot solve in one turn becomes a background
clock: a famine, a siege, an inquiry closing in. Each bleeds a stat a
little every turn and lands hard when it expires, and each is visible in
the status panel with its remaining turns.

This is the difference between a management game and a branching story.
Without clocks every turn is a self-contained dilemma and the only real
question is which option reads best. With them the focal choice is hard
because of what else is running: spending the treasury on grain is a
different decision when the creditors come due in two turns, and the
player can see both at once.

The bleed is deliberately a fraction of the payload. A clock has to hurt
a little while it runs and a lot when it lands, so ignoring one is a real
gamble rather than a free delay. Resolving a clock removes it without
firing the payload, which is the reward for actually dealing with the
problem instead of riding it out. Length and weight are tag vocabulary
priced from the same authored tables as everything else.

## Off-menu actions

The player can ignore the buttons and say what they actually want to do.
The model reads the intent, describes it in the ordinary tag vocabulary,
and `game_price_action` returns real odds without committing anything.
The player sees the price, then confirms or picks something else.

This is the move no board game can adjudicate and the main reason to run
a game like this on a language model at all: "I'll marry my daughter to
the duke and buy his cavalry" gets a genuine priced gamble rather than a
shrug or a rubber stamp.

The pricing goes through the same path as an authored choice, and the
improvised action is spliced onto the situation as a real option before
resolving. There is no second, softer code path for free text — if there
were, off-menu actions would end up strictly better than the buttons, and
once players noticed, the listed options would stop being decisions.

Quoting is read-only on purpose. Showing odds means committing to them,
so the player has to be able to see the price before paying it.

## Staying honest across turns

Three guards, each for a failure this design invites.

**One commit per send.** A model that calls the commit tool twice — retry
logic, a confused tool loop, or fishing for a better roll — would
otherwise advance the campaign several turns behind a single narration,
and only the last state would ever be bound to a message. The second call
is refused.

**Optimistic concurrency.** Every result carries a `state_version` the
model passes back on its next commit. A call acting on a version that has
since moved is rejected rather than applied on top of newer state, which
covers replays, retries, and a second client acting on what the model
last saw.

**Live state in front of the model.** The campaign state is injected into
the wire prefix every turn, scoped to the branch being continued, so the
model never narrates from figures it half-remembers. This block is
ephemeral — rebuilt per send, never stored. Writing it through
`MessageEnvelope` would persist it beside the user's content and
recompose it into every later prefix, accumulating one stale copy per
turn.

Its position is load-bearing. Anthropic's cache breakpoint sits at the
end of the last assistant turn, so anything before it must stay
byte-identical between turns to remain cached. The block lands on the
head message, after the breakpoint. In the system slot it would
invalidate the entire cached prefix on every single turn, which on turn
forty of a long campaign means re-reading the whole transcript at full
price, every turn.

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

Still missing from the game: multi-stage situations that branch within
themselves, delayed and conditional effects that fire on a state
predicate rather than a countdown, policies and projects the player sets
once and lets run, factions and characters with loyalty tracked
separately from power, and turn capacity limits that force triage across
several problems in one turn.

On durability: prepared-then-committed transitions with an idempotency
key, and a transitions ledger. Today a tool that mutates state followed
by a failed generation leaves the turn bound to no message; the next
turn's ancestor walk absorbs that by replaying from the previous
snapshot, which is safe but quietly costs a turn.

Presentation reuses `key_value` and `choice_list`, so odds and clocks
ride in label strings. Bespoke components would give the odds a real
two-column layout and the clocks a progress treatment.

## Ready-made campaigns

Three scenarios ship as an importable bundle in [../profiles/](../profiles/README.md): The Crown, The Regency and The Usurper, sharing one `parent_only` base. They exist partly to exercise parts of the engine that are otherwise untested by hand, notably `Director.HiddenFacts`, which is what makes an intrigue campaign work and which nothing else uses.
