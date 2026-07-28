package engine

import (
	"strings"
	"testing"
)

// demoScenario is a minimal but valid setup: two resources, two
// ratings, a bankruptcy loss and a survive-the-campaign win.
func demoScenario() Scenario {
	return Scenario{
		Title:   "The Lean Winter",
		Role:    "Margrave",
		Premise: "A border march, one bad harvest from collapse.",
		Resources: []StatDef{
			{ID: "treasury", Label: "Treasury", Start: 60, Min: 0, Max: 200},
			{ID: "unrest", Label: "Unrest", Start: 20, Min: 0, Max: 100},
		},
		Ratings: []StatDef{
			{ID: "guile", Label: "Guile", Start: 4, Min: 0, Max: 10},
			{ID: "standing", Label: "Standing", Start: 5, Min: 0, Max: 10},
		},
		LossWhen: []Condition{
			{Stat: "treasury", Op: "<=", Value: 0, Label: "The treasury is empty and the garrison walks"},
		},
		TurnLimit: 12,
		OpeningScene: SituationDraft{
			ID:    "granary",
			Title: "The Empty Granary",
			Body:  "The winter stores were overstated.",
			Choices: []ChoiceDraft{
				{ID: "A", Label: "Buy grain from the guild", Rating: "guile", Difficulty: "moderate",
					Stakes: "standard", Advances: "standing", Costs: "treasury"},
				{ID: "B", Label: "Seize the guild's stores", Rating: "standing", Difficulty: "hard",
					Stakes: "major", Advances: "treasury", Costs: "standing"},
			},
		},
	}
}

func mustInit(t *testing.T) State {
	t.Helper()
	st, err := Initialize(demoScenario(), 42)
	if err != nil {
		t.Fatalf("initialize: %v", err)
	}
	return st
}

func TestInitialize_SeedsStatsAndPricesOpening(t *testing.T) {
	t.Parallel()
	st := mustInit(t)

	if st.Public.Resources["treasury"] != 60 || st.Public.Ratings["guile"] != 4 {
		t.Errorf("stats not seeded from scenario: %+v %+v", st.Public.Resources, st.Public.Ratings)
	}
	if st.Meta.Turn != 1 || st.Meta.StateVersion != 1 {
		t.Errorf("turn/version: got %d/%d want 1/1", st.Meta.Turn, st.Meta.StateVersion)
	}
	if st.Protocol.Phase != PhaseAwaitingActer {
		t.Errorf("phase: got %q", st.Protocol.Phase)
	}
	if got := strings.Join(st.Protocol.LegalChoiceIDs, ","); got != "A,B" {
		t.Errorf("legal choices: got %q", got)
	}
	// The engine, not the model, produced the numbers.
	a, _ := st.ChoiceByID("A")
	if a.Target != 11 || a.Modifier != 4 {
		t.Errorf("choice A pricing: target %d modifier %d, want 11/4", a.Target, a.Modifier)
	}
	if a.Odds.Favorable <= 0 || a.Odds.Favorable >= 100 {
		t.Errorf("choice A odds look wrong: %+v", a.Odds)
	}
}

// TestOdds_MatchExactDistribution pins the odds against hand-computed
// 3d6 probabilities. If displayed odds ever drift from the real
// distribution the game is lying to the player, so this is worth
// nailing rather than sanity-checking.
func TestOdds_MatchExactDistribution(t *testing.T) {
	t.Parallel()
	// modifier 0, target 11 → favorable means roll >= 11.
	// ways(11..18) = 27+25+21+15+10+6+3+1 = 108 of 216 = 50%.
	if got := OddsFor(0, 11); got.Favorable != 50 {
		t.Errorf("OddsFor(0,11).Favorable: got %d want 50", got.Favorable)
	}
	// Disaster is margin < -9, i.e. roll < 2 for target 11 — impossible
	// on 3d6, so the tail is empty.
	if got := OddsFor(0, 11); got.Disaster != 0 {
		t.Errorf("OddsFor(0,11).Disaster: got %d want 0", got.Disaster)
	}
	// A brutal check: target 20, no modifier. Favorable needs roll >= 20,
	// impossible; disaster is roll <= 10, which is 108/216 = 50%.
	hard := OddsFor(0, 20)
	if hard.Favorable != 0 {
		t.Errorf("impossible check should be 0%% favorable; got %d", hard.Favorable)
	}
	if hard.Disaster != 50 {
		t.Errorf("target-20 disaster tail: got %d want 50", hard.Disaster)
	}
}

// TestOdds_RatingMovesTheNeedle is the argument for 3d6 over d20: a
// point of rating near the middle of the curve is worth far more than
// the flat 5% a linear die would give.
func TestOdds_RatingMovesTheNeedle(t *testing.T) {
	t.Parallel()
	base := OddsFor(0, 11).Favorable
	oneBetter := OddsFor(1, 11).Favorable
	if delta := oneBetter - base; delta < 8 {
		t.Errorf("a rating point near the margin should swing ~12%%; got %d", delta)
	}
	// And at the extremes it should barely matter.
	edge := OddsFor(0, 5).Favorable
	edgePlus := OddsFor(1, 5).Favorable
	if delta := edgePlus - edge; delta > 6 {
		t.Errorf("a rating point at the easy extreme should be nearly worthless; got %d", delta)
	}
}

// TestRoll_IsDeterministicPerDecision is what makes forks comparable:
// the same campaign, turn and choice always produce the same dice, so a
// divergence between branches is caused by the player's decision rather
// than by the generator having advanced a different number of times.
func TestRoll_IsDeterministicPerDecision(t *testing.T) {
	t.Parallel()
	a := RollFor(42, 3, "granary", "A", 4, 11)
	b := RollFor(42, 3, "granary", "A", 4, 11)
	if a != b {
		t.Fatalf("same inputs must produce the same roll: %+v vs %+v", a, b)
	}
	// A different decision at the same moment rolls differently.
	other := RollFor(42, 3, "granary", "B", 4, 11)
	// A different campaign rolls differently.
	otherSeed := RollFor(99, 3, "granary", "A", 4, 11)
	if a.Raw == other.Raw && a.Raw == otherSeed.Raw {
		t.Error("choice id and seed should both perturb the roll")
	}
	if a.Raw < 3 || a.Raw > 18 {
		t.Errorf("roll out of 3d6 range: %d", a.Raw)
	}
}

// TestRoll_CoversTheWholeRange guards against a hash-folding bug that
// would quietly bias every check in the game.
func TestRoll_CoversTheWholeRange(t *testing.T) {
	t.Parallel()
	seen := map[int]int{}
	for turn := 0; turn < 4000; turn++ {
		r := RollFor(7, turn, "s", "A", 0, 11)
		if r.Raw < 3 || r.Raw > 18 {
			t.Fatalf("out of range: %d", r.Raw)
		}
		seen[r.Raw]++
	}
	if len(seen) < 14 {
		t.Errorf("expected most of 3..18 to appear across 4000 rolls; got %d distinct", len(seen))
	}
	// The curve should peak in the middle, not be flat.
	if seen[10]+seen[11] <= seen[3]+seen[18] {
		t.Errorf("distribution is not bell-shaped: mid=%d tails=%d",
			seen[10]+seen[11], seen[3]+seen[18])
	}
}

func TestResolve_AppliesCostAndAdvance(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	before := st.Public.Resources["treasury"]

	tr, next, err := Resolve(st, "A")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if tr.Band == "" {
		t.Error("transition has no band")
	}
	// Choice A costs treasury on every band, so it must have moved.
	if next.Public.Resources["treasury"] >= before {
		t.Errorf("treasury should be spent: %d -> %d", before, next.Public.Resources["treasury"])
	}
	if next.Meta.Turn != 2 || next.Meta.StateVersion != 2 {
		t.Errorf("turn/version should advance: %d/%d", next.Meta.Turn, next.Meta.StateVersion)
	}
	if next.Public.Situation != nil {
		t.Error("the resolved situation should be consumed")
	}
	if len(next.Public.History) != 1 {
		t.Errorf("expected one ledger entry; got %d", len(next.Public.History))
	}
	if len(tr.Explain) == 0 || !strings.Contains(tr.Explain[0], "against") {
		t.Errorf("transition should explain the check: %v", tr.Explain)
	}
}

// TestResolve_DoesNotMutateParent is branch independence at the engine
// level — the store keeps lineages apart, but only if resolving a turn
// never reaches back into the snapshot it came from.
func TestResolve_DoesNotMutateParent(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	before := st.Public.Resources["treasury"]
	beforeHistory := len(st.Public.History)

	if _, _, err := Resolve(st, "A"); err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if st.Public.Resources["treasury"] != before {
		t.Errorf("parent treasury mutated: %d -> %d", before, st.Public.Resources["treasury"])
	}
	if len(st.Public.History) != beforeHistory {
		t.Error("parent history mutated")
	}
	if st.Public.Situation == nil {
		t.Error("parent situation was consumed")
	}
}

func TestResolve_RejectsIllegalChoice(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	_, _, err := Resolve(st, "Z")
	if err == nil || !strings.Contains(err.Error(), "not on the table") {
		t.Errorf("expected an illegal-choice error; got %v", err)
	}
}

func TestResolve_ClampsToDeclaredBounds(t *testing.T) {
	t.Parallel()
	sc := demoScenario()
	// Start treasury one point above the floor so any cost would
	// otherwise drive it negative.
	sc.Resources[0].Start = 1
	st, err := Initialize(sc, 1)
	if err != nil {
		t.Fatalf("initialize: %v", err)
	}
	_, next, err := Resolve(st, "A")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got := next.Public.Resources["treasury"]; got < 0 {
		t.Errorf("treasury drove below its declared minimum: %d", got)
	}
}

func TestCheckEnd_LossBeatsVictory(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	st.Public.Victory = []Condition{{Stat: "standing", Op: ">=", Value: 1, Label: "acclaimed"}}
	st.Public.Resources["treasury"] = 0

	out := CheckEnd(st)
	if out == nil {
		t.Fatal("expected the campaign to end")
	}
	if out.Victory {
		t.Errorf("bankruptcy on the turn you would have won is still a loss; got %+v", out)
	}
}

func TestCheckEnd_TurnLimitIsAWin(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	st.Meta.Turn = st.Public.TurnLimit + 1

	out := CheckEnd(st)
	if out == nil || !out.Victory {
		t.Errorf("surviving the campaign should be a victory; got %+v", out)
	}
}

func TestResolve_RefusesAfterTheEnd(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	st.Protocol.Phase = PhaseFinished
	if _, _, err := Resolve(st, "A"); err == nil {
		t.Error("a finished campaign must not accept another turn")
	}
}

// --- scenario validation ---

func TestValidateScenario_RejectsUnwinnable(t *testing.T) {
	t.Parallel()
	sc := demoScenario()
	sc.TurnLimit = 0
	sc.VictoryWhen = nil
	if err := ValidateScenario(sc); err == nil {
		t.Error("a scenario with no way to win should be rejected")
	}
}

func TestValidateScenario_RejectsUnlosable(t *testing.T) {
	t.Parallel()
	sc := demoScenario()
	sc.LossWhen = nil
	if err := ValidateScenario(sc); err == nil {
		t.Error("a scenario with no way to lose should be rejected")
	}
}

func TestValidateScenario_RejectsModelInventedTags(t *testing.T) {
	t.Parallel()
	for name, mutate := range map[string]func(*Scenario){
		"unknown difficulty": func(s *Scenario) { s.OpeningScene.Choices[0].Difficulty = "impossible" },
		"unknown stakes":     func(s *Scenario) { s.OpeningScene.Choices[0].Stakes = "colossal" },
		"unknown rating":     func(s *Scenario) { s.OpeningScene.Choices[0].Rating = "charisma" },
		"unknown cost stat":  func(s *Scenario) { s.OpeningScene.Choices[0].Costs = "goats" },
		"rating not a stat":  func(s *Scenario) { s.OpeningScene.Choices[0].Rating = "treasury" },
	} {
		sc := demoScenario()
		mutate(&sc)
		if err := ValidateScenario(sc); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestValidateScenario_RequiresTwoChoices(t *testing.T) {
	t.Parallel()
	sc := demoScenario()
	sc.OpeningScene.Choices = sc.OpeningScene.Choices[:1]
	if err := ValidateScenario(sc); err == nil {
		t.Error("a single-option situation is not a decision")
	}
}

// TestPriceSituation_UsesCurrentRatings verifies odds track the player's
// actual ratings, so investing in a rating visibly changes the numbers on
// later buttons.
func TestPriceSituation_UsesCurrentRatings(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	draft := demoScenario().OpeningScene

	weak, err := PriceSituation(st, draft)
	if err != nil {
		t.Fatalf("price: %v", err)
	}
	st.Public.Ratings["guile"] = 9
	strong, err := PriceSituation(st, draft)
	if err != nil {
		t.Fatalf("price: %v", err)
	}
	if strong.Choices[0].Odds.Favorable <= weak.Choices[0].Odds.Favorable {
		t.Errorf("a higher rating must improve the odds: %d -> %d",
			weak.Choices[0].Odds.Favorable, strong.Choices[0].Odds.Favorable)
	}
}
