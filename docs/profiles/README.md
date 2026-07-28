# Shareable profile bundles

Importable `.psmithprofile` files. Import one from the profile list: on Mac the
Import button sits above the list, on iOS in the nav bar next to `+`.

These are generated, not hand-authored. Edit
[`scripts/gen-profile-bundles/main.go`](../../scripts/gen-profile-bundles/main.go)
and re-run:

```bash
go run ./scripts/gen-profile-bundles -out docs/profiles
```

Output is byte-stable, so regenerating without changing the source produces no
diff. `TestShippedBundlesImport` in `server/profiles` imports every file here
against a real database on each run, which is what stops a bundle-format change
leaving a broken artifact in the tree.

## crown-campaigns.psmithprofile

Four profiles for the [game_master](../design/game-master.md) plugin: one
`parent_only` base plus three scenarios that inherit it.

**Game Master** carries the plugin and the framing that the model narrates and
never computes. It is the only profile with a plugin row; the scenarios inherit
it through the chain, which is also a decent exercise of the layered merge.

**The Crown.** You hold a throne on a contested claim and one of the great
houses is already committed against you. The design centre is that information
is a purchase rather than a lookup: a spymaster check buys a true fact from the
director-only hidden state, and because failure still costs, an investigation
that finds nothing burns the same gold as one that succeeds. The player is
always choosing between knowing and preparing. Conspiracies run as ominous
clocks with a visible label and a hidden payload, so you can watch a lord arm
himself without learning what he intends. Uses the full difficulty ladder, up to
`forlorn` at target 20, which on 3d6 is unreachable until many turns of building
`martial` have gone in.

**The Regency.** You rule for a child heir, so `legitimacy` is not yours: it
starts at its ceiling and can only be spent. `martial` and `favor` are capped
low. The player cannot grow their way out of trouble, which forces the whole
campaign into resource management and information. Survive to the turn limit and
the heir comes of age.

**The Usurper.** The same engine with the perspective flipped. You hold a great
house and mean to take the throne, and the hidden state is what the crown knows
about *you*: which ally has already talked, what evidence exists, what they are
waiting for. `pretext` is the rating that matters, because taking a throne by
force loses it again in a season. Clocks are the investigation closing in.

All three ship with `show_odds` and `show_rolls` on, since they exist partly to
exercise the engine and the dice are most of the point. Turn `show_rolls` off in
the plugin config for a straight play-through.

One thing to know going in: rolls are `hash(seed, turn, situation, choice)`, so
regenerating a message will not reroll an outcome. That matters most in The
Crown, where a player who could reroll until an investigation succeeded would
have no game left.
