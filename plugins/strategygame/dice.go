package strategygame

import (
	"encoding/binary"
	"fmt"
	"hash/fnv"
	"sort"
)

// Resolution is 3d6 plus the checked rating against a target number.
//
// 3d6 rather than a flat d20 on purpose. On a d20 every point of rating
// is worth exactly 5% wherever you stand, so investment is linear and
// dull, and a 95% still whiffs one time in twenty at full price. On 3d6
// the curve does the design work: a point near the middle swings ~12%,
// points at the extremes swing almost nothing. Investing in a rating
// matters most when you are near the margin, which is exactly when the
// player is making an interesting decision.
const (
	dieMin = 3
	dieMax = 18
	// combinations sums to 216 = 6^3.
	combinations = 216
)

// waysToRoll[n] is the number of 3d6 permutations summing to n. Exact
// rather than sampled, because the displayed odds have to be the same
// number the resolution uses — if the two ever disagree the player is
// being lied to, and they will notice.
var waysToRoll = map[int]int{
	3: 1, 4: 3, 5: 6, 6: 10, 7: 15, 8: 21, 9: 25, 10: 27,
	11: 27, 12: 25, 13: 21, 14: 15, 15: 10, 16: 6, 17: 3, 18: 1,
}

// Band is the outcome tier a resolved check lands in. Margin-based
// rather than binary: "did it work" hides the difference between a
// costly near-miss and a catastrophe, which is most of what makes a
// choice interesting.
type Band string

const (
	BandDisaster Band = "disaster"
	BandFailure  Band = "failure"
	BandMixed    Band = "mixed"
	BandSuccess  Band = "success"
	BandTriumph  Band = "triumph"
)

// AllBands in ascending order of desirability. Exposed so callers can
// build complete effect tables without hardcoding the list.
var AllBands = []Band{BandDisaster, BandFailure, BandMixed, BandSuccess, BandTriumph}

// bandFor maps a margin (roll + modifier - target) onto its tier.
func bandFor(margin int) Band {
	switch {
	case margin >= 5:
		return BandTriumph
	case margin >= 0:
		return BandSuccess
	case margin >= -4:
		return BandMixed
	case margin >= -9:
		return BandFailure
	default:
		return BandDisaster
	}
}

// difficultyTargets is the authored band-to-number table. The model
// picks a band name, never an integer — that is what keeps difficulty
// from drifting across a long campaign and what makes rebalancing one
// table edit instead of a prompt-tuning session.
var difficultyTargets = map[string]int{
	"trivial":  5,
	"easy":     8,
	"moderate": 11,
	"hard":     14,
	"daunting": 17,
	"forlorn":  20,
}

// DifficultyNames returns the legal band names, sorted by how hard they
// are. Used to build the tool schema and the error message a model sees
// when it invents one.
func DifficultyNames() []string {
	out := make([]string, 0, len(difficultyTargets))
	for name := range difficultyTargets {
		out = append(out, name)
	}
	sort.Slice(out, func(i, j int) bool {
		return difficultyTargets[out[i]] < difficultyTargets[out[j]]
	})
	return out
}

// TargetFor resolves a difficulty band name to its target number.
func TargetFor(difficulty string) (int, error) {
	t, ok := difficultyTargets[difficulty]
	if !ok {
		return 0, fmt.Errorf("unknown difficulty %q (want one of %v)", difficulty, DifficultyNames())
	}
	return t, nil
}

// Odds is the probability profile of a check, as whole percents.
//
// Two numbers, not one. A 30% chance with a 5% disaster tail and a 30%
// chance with a 40% disaster tail are completely different decisions,
// and collapsing them to a single "success chance" hides exactly the
// information a player needs — the classic complaint about games that
// show hit chance and conceal the consequence.
type Odds struct {
	Favorable int `json:"favorable"` // success or triumph
	Disaster  int `json:"disaster"`  // the bottom tier only
}

// OddsFor computes the exact probability profile for a check. modifier
// is the checked rating (plus any situational adjustment); target comes
// from the difficulty band.
func OddsFor(modifier, target int) Odds {
	favorableWays, disasterWays := 0, 0
	for roll := dieMin; roll <= dieMax; roll++ {
		ways := waysToRoll[roll]
		switch bandFor(roll + modifier - target) {
		case BandTriumph, BandSuccess:
			favorableWays += ways
		case BandDisaster:
			disasterWays += ways
		}
	}
	return Odds{
		Favorable: pct(favorableWays),
		Disaster:  pct(disasterWays),
	}
}

// pct rounds ways-out-of-216 to the nearest whole percent.
func pct(ways int) int {
	return (ways*200 + combinations) / (combinations * 2)
}

// Roll is a resolved check, kept whole so the UI can explain the
// outcome rather than just announce it. "The operation failed because
// the army was under-supplied and you committed too few troops" is a
// different game from "your plan unexpectedly failed."
type Roll struct {
	Raw      int  `json:"raw"`      // the 3d6 total
	Modifier int  `json:"modifier"` // the checked rating
	Target   int  `json:"target"`
	Margin   int  `json:"margin"`
	Band     Band `json:"band"`
}

// RollFor produces the deterministic 3d6 result for one decision.
//
// Derived from (seed, turn, situation, choice) rather than drawn from a
// running generator, which buys two things. Forks stay comparable: two
// branches that make the same decisions see the same dice, so a
// divergence is caused by the player's choice and not by the RNG
// advancing a different number of times. And a regenerated turn re-rolls
// nothing — narration changes, the mechanical result does not. Getting a
// different outcome means making a different decision, which is the
// point of a strategy game.
func RollFor(seed uint64, turn int, situationID, choiceID string, modifier, target int) Roll {
	h := fnv.New64a()
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], seed)
	_, _ = h.Write(buf[:])
	binary.LittleEndian.PutUint64(buf[:], uint64(turn))
	_, _ = h.Write(buf[:])
	_, _ = h.Write([]byte(situationID))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(choiceID))
	sum := h.Sum64()

	// Three independent dice out of distinct byte lanes, so the sum is
	// a real bell curve rather than one value folded three times.
	raw := int(sum%6) + int((sum>>16)%6) + int((sum>>32)%6) + 3
	margin := raw + modifier - target
	return Roll{
		Raw:      raw,
		Modifier: modifier,
		Target:   target,
		Margin:   margin,
		Band:     bandFor(margin),
	}
}
