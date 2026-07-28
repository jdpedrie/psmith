package strategygame

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// Scenario is what the model compiles from the player's opening
// message: the fiction plus the shape of the game. It is data, validated
// here before anything is stored, so a malformed or unbalanced setup
// fails at turn one rather than halfway through a campaign.
type Scenario struct {
	Title     string    `json:"title"`
	Role      string    `json:"role"`
	Premise   string    `json:"premise"`
	DateLabel string    `json:"date_label,omitempty"`
	Resources []StatDef `json:"resources"`
	Ratings   []StatDef `json:"ratings"`
	// LossWhen / VictoryWhen are predicates over stats, checked after
	// every transition. Loss is checked first: bleeding out on the turn
	// you would have won is a loss.
	LossWhen    []Condition `json:"loss_when"`
	VictoryWhen []Condition `json:"victory_when,omitempty"`
	// TurnLimit, when >0, ends the campaign in victory if no loss
	// condition tripped first — the "survive N turns" shape.
	TurnLimit    int            `json:"turn_limit,omitempty"`
	HiddenFacts  []string       `json:"hidden_facts,omitempty"`
	OpeningScene SituationDraft `json:"opening_situation"`
}

// StatDef declares one stat. Resources are spent and accumulate;
// ratings are small and get added to dice.
type StatDef struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Start int    `json:"start"`
	Min   int    `json:"min"`
	Max   int    `json:"max"`
}

// Condition is a threshold predicate over one stat.
type Condition struct {
	Stat  string `json:"stat"`
	Op    string `json:"op"` // "<=" or ">="
	Value int    `json:"value"`
	Label string `json:"label"`
}

// SituationDraft is the model's contribution: ids, prose, and tags. No
// numbers anywhere, which is what makes it impossible for the model to
// publish a figure it invented.
type SituationDraft struct {
	ID      string        `json:"id"`
	Title   string        `json:"title"`
	Body    string        `json:"body"`
	Choices []ChoiceDraft `json:"choices"`
}

// ChoiceDraft is one proposed option, described entirely in tags.
type ChoiceDraft struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	Rating     string `json:"rating"`
	Difficulty string `json:"difficulty"`
	Stakes     string `json:"stakes"`
	Advances   string `json:"advances"`
	Costs      string `json:"costs"`
}

// stakesUnits is the authored magnitude table. The model picks a tier
// name; the engine turns it into points. Rebalancing a campaign that
// feels too soft is an edit here, not a prompt change.
var stakesUnits = map[string]int{
	"minor":    3,
	"standard": 7,
	"major":    15,
}

// StakesNames returns the legal tiers, easiest-to-heaviest.
func StakesNames() []string {
	out := make([]string, 0, len(stakesUnits))
	for k := range stakesUnits {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return stakesUnits[out[i]] < stakesUnits[out[j]] })
	return out
}

// bandEffect scales the unit into an actual gain and cost.
//
// Failure still costs. A bribe that does not work should cost more gold
// than one that does, not zero — otherwise every risky option is free to
// attempt and the decision evaporates.
type bandEffect struct {
	gainMul float64
	costMul float64
}

var bandEffects = map[Band]bandEffect{
	BandTriumph:  {gainMul: 1.5, costMul: 0.5},
	BandSuccess:  {gainMul: 1.0, costMul: 1.0},
	BandMixed:    {gainMul: 0.4, costMul: 1.0},
	BandFailure:  {gainMul: 0.0, costMul: 1.0},
	BandDisaster: {gainMul: -0.6, costMul: 1.5},
}

// Transition is the mechanical result of one decision.
type Transition struct {
	Band    Band           `json:"band"`
	Roll    Roll           `json:"roll"`
	Deltas  map[string]int `json:"deltas"`
	Explain []string       `json:"explain"`
	Outcome *Outcome       `json:"outcome,omitempty"`
}

// ValidateScenario rejects a setup that could not produce a playable
// game. Every check here is one the model can get wrong when compiling
// a free-form premise, and every one of them is cheaper to catch now
// than to discover on turn nine.
func ValidateScenario(sc Scenario) error {
	if strings.TrimSpace(sc.Role) == "" {
		return fmt.Errorf("scenario: role is required")
	}
	if len(sc.Resources) == 0 {
		return fmt.Errorf("scenario: at least one resource is required")
	}
	if len(sc.Ratings) == 0 {
		return fmt.Errorf("scenario: at least one rating is required (checks add a rating to the dice)")
	}
	seen := map[string]bool{}
	for _, group := range [][]StatDef{sc.Resources, sc.Ratings} {
		for _, s := range group {
			if strings.TrimSpace(s.ID) == "" {
				return fmt.Errorf("scenario: stat is missing an id")
			}
			if seen[s.ID] {
				return fmt.Errorf("scenario: duplicate stat id %q", s.ID)
			}
			seen[s.ID] = true
			if s.Max <= s.Min {
				return fmt.Errorf("scenario: stat %q has max <= min", s.ID)
			}
			if s.Start < s.Min || s.Start > s.Max {
				return fmt.Errorf("scenario: stat %q starts outside its own bounds", s.ID)
			}
		}
	}
	if len(sc.LossWhen) == 0 {
		return fmt.Errorf("scenario: at least one loss condition is required (a game you cannot lose is not a game)")
	}
	for _, group := range [][]Condition{sc.LossWhen, sc.VictoryWhen} {
		for _, c := range group {
			if !seen[c.Stat] {
				return fmt.Errorf("scenario: condition references unknown stat %q", c.Stat)
			}
			if c.Op != "<=" && c.Op != ">=" {
				return fmt.Errorf("scenario: condition op must be <= or >=, got %q", c.Op)
			}
		}
	}
	if sc.TurnLimit == 0 && len(sc.VictoryWhen) == 0 {
		return fmt.Errorf("scenario: needs a turn_limit or at least one victory condition, or the campaign cannot be won")
	}
	// Validate the opening scene against the stats it will reference.
	ratings := map[string]bool{}
	for _, r := range sc.Ratings {
		ratings[r.ID] = true
	}
	return validateDraft(sc.OpeningScene, seen, ratings)
}

func validateDraft(d SituationDraft, stats, ratings map[string]bool) error {
	if strings.TrimSpace(d.ID) == "" {
		return fmt.Errorf("situation: id is required")
	}
	if len(d.Choices) < 2 {
		return fmt.Errorf("situation %q: at least two choices are required", d.ID)
	}
	ids := map[string]bool{}
	for _, c := range d.Choices {
		if strings.TrimSpace(c.ID) == "" {
			return fmt.Errorf("situation %q: a choice is missing an id", d.ID)
		}
		if ids[c.ID] {
			return fmt.Errorf("situation %q: duplicate choice id %q", d.ID, c.ID)
		}
		ids[c.ID] = true
		if strings.TrimSpace(c.Label) == "" {
			return fmt.Errorf("choice %q: label is required", c.ID)
		}
		if !ratings[c.Rating] {
			return fmt.Errorf("choice %q: rating %q is not a declared rating", c.ID, c.Rating)
		}
		if _, err := TargetFor(c.Difficulty); err != nil {
			return fmt.Errorf("choice %q: %w", c.ID, err)
		}
		if _, ok := stakesUnits[c.Stakes]; !ok {
			return fmt.Errorf("choice %q: unknown stakes %q (want one of %v)", c.ID, c.Stakes, StakesNames())
		}
		if !stats[c.Advances] {
			return fmt.Errorf("choice %q: advances unknown stat %q", c.ID, c.Advances)
		}
		if !stats[c.Costs] {
			return fmt.Errorf("choice %q: costs unknown stat %q", c.ID, c.Costs)
		}
	}
	return nil
}

// Initialize compiles a validated scenario into turn one.
func Initialize(sc Scenario, seed uint64) (State, error) {
	if err := ValidateScenario(sc); err != nil {
		return State{}, err
	}
	st := State{
		Meta: Meta{
			SchemaVersion: SchemaVersion,
			StateVersion:  1,
			Turn:          1,
			DateLabel:     sc.DateLabel,
			Ruleset:       "governance",
			Seed:          seed,
		},
		Public: Public{
			Title:     sc.Title,
			Role:      sc.Role,
			Premise:   sc.Premise,
			Resources: map[string]int{},
			Ratings:   map[string]int{},
			Labels:    map[string]string{},
			Limits:    map[string]Limit{},
		},
		Director: Director{HiddenFacts: sc.HiddenFacts},
	}
	for _, s := range sc.Resources {
		st.Public.Resources[s.ID] = s.Start
		st.Public.Labels[s.ID] = s.Label
		st.Public.Limits[s.ID] = Limit{Min: s.Min, Max: s.Max}
	}
	for _, s := range sc.Ratings {
		st.Public.Ratings[s.ID] = s.Start
		st.Public.Labels[s.ID] = s.Label
		st.Public.Limits[s.ID] = Limit{Min: s.Min, Max: s.Max}
	}
	st.Public.Loss = sc.LossWhen
	st.Public.Victory = sc.VictoryWhen
	st.Public.TurnLimit = sc.TurnLimit

	sit, err := PriceSituation(st, sc.OpeningScene)
	if err != nil {
		return State{}, err
	}
	st.Public.Situation = &sit
	st.Protocol = protocolFor(&sit)
	return st, nil
}

// PriceSituation turns the model's tag-only draft into a playable
// situation by resolving difficulty bands to targets and computing exact
// odds against the player's current ratings.
//
// This is the only place odds are produced. They are stored on the
// snapshot, displayed from it, and resolved against it, so the number on
// the button is provably the number the dice were checked against.
func PriceSituation(st State, d SituationDraft) (Situation, error) {
	stats := map[string]bool{}
	ratings := map[string]bool{}
	for k := range st.Public.Resources {
		stats[k] = true
	}
	for k := range st.Public.Ratings {
		stats[k] = true
		ratings[k] = true
	}
	if err := validateDraft(d, stats, ratings); err != nil {
		return Situation{}, err
	}
	out := Situation{ID: d.ID, Title: d.Title, Body: d.Body}
	for _, c := range d.Choices {
		target, err := TargetFor(c.Difficulty)
		if err != nil {
			return Situation{}, err
		}
		mod := st.Public.Ratings[c.Rating]
		out.Choices = append(out.Choices, Choice{
			ID:         c.ID,
			Label:      c.Label,
			Rating:     c.Rating,
			Difficulty: c.Difficulty,
			Target:     target,
			Modifier:   mod,
			Odds:       OddsFor(mod, target),
			Stakes:     c.Stakes,
			Advances:   c.Advances,
			Costs:      c.Costs,
		})
	}
	return out, nil
}

func protocolFor(sit *Situation) Protocol {
	p := Protocol{Phase: PhaseAwaitingActer, AllowedCommitKind: "resolve"}
	if sit != nil {
		for _, c := range sit.Choices {
			p.LegalChoiceIDs = append(p.LegalChoiceIDs, c.ID)
		}
	}
	return p
}

// Resolve applies one decision and returns the transition plus the next
// state. The caller supplies the next situation separately, because the
// model writes that fiction only after seeing how this turn went.
func Resolve(st State, choiceID string) (Transition, State, error) {
	if st.Protocol.Phase == PhaseFinished {
		return Transition{}, st, fmt.Errorf("campaign is already over")
	}
	if st.Public.Situation == nil {
		return Transition{}, st, fmt.Errorf("no active situation to resolve")
	}
	choice, ok := st.ChoiceByID(choiceID)
	if !ok {
		return Transition{}, st, fmt.Errorf("choice %q is not on the table (legal: %s)",
			choiceID, strings.Join(st.Protocol.LegalChoiceIDs, ", "))
	}

	roll := RollFor(st.Meta.Seed, st.Meta.Turn, st.Public.Situation.ID, choice.ID, choice.Modifier, choice.Target)
	eff := bandEffects[roll.Band]
	unit := stakesUnits[choice.Stakes]

	deltas := map[string]int{}
	if cost := roundHalfUp(float64(unit) * eff.costMul); cost != 0 {
		deltas[choice.Costs] -= cost
	}
	if gain := roundHalfUp(float64(unit) * eff.gainMul); gain != 0 {
		deltas[choice.Advances] += gain
	}

	next := st.clone()
	next.applyDeltas(deltas)
	next.Meta.StateVersion++
	next.Meta.Turn++

	tr := Transition{
		Band:   roll.Band,
		Roll:   roll,
		Deltas: deltas,
		Explain: []string{
			fmt.Sprintf("%s: rolled %d + %s %d against %d (margin %+d).",
				choice.Label, roll.Raw, next.Public.Label(choice.Rating), roll.Modifier, roll.Target, roll.Margin),
		},
	}
	for _, stat := range sortedKeys(deltas) {
		tr.Explain = append(tr.Explain, fmt.Sprintf("%s %+d", next.Public.Label(stat), deltas[stat]))
	}

	next.Public.History = append(next.Public.History, Entry{
		Turn:      st.Meta.Turn,
		Situation: st.Public.Situation.ID,
		Choice:    choice.ID,
		Band:      roll.Band,
		Roll:      roll.Raw,
		Target:    roll.Target,
		Deltas:    deltas,
	})
	// The situation is consumed; the model supplies the next one via a
	// separate call, and until then there is nothing legal to choose.
	next.Public.Situation = nil
	next.Protocol = Protocol{Phase: PhaseAwaitingActer, AllowedCommitKind: "resolve"}

	if outcome := CheckEnd(next); outcome != nil {
		next.Public.Outcome = outcome
		next.Protocol = Protocol{Phase: PhaseFinished, AllowedCommitKind: ""}
		tr.Outcome = outcome
	}
	return tr, next, nil
}

// CheckEnd evaluates loss first, then victory, then the turn limit.
// Losing on the turn you would have won is a loss — the kingdom does not
// care that the treaty was one signature away.
func CheckEnd(st State) *Outcome {
	for _, c := range st.Public.Loss {
		if conditionMet(st, c) {
			return &Outcome{Victory: false, Label: c.Label, Turn: st.Meta.Turn}
		}
	}
	for _, c := range st.Public.Victory {
		if conditionMet(st, c) {
			return &Outcome{Victory: true, Label: c.Label, Turn: st.Meta.Turn}
		}
	}
	if st.Public.TurnLimit > 0 && st.Meta.Turn > st.Public.TurnLimit {
		return &Outcome{Victory: true, Label: "Survived to the end of the campaign", Turn: st.Meta.Turn}
	}
	return nil
}

func conditionMet(st State, c Condition) bool {
	v, ok := st.Public.StatValue(c.Stat)
	if !ok {
		return false
	}
	switch c.Op {
	case "<=":
		return v <= c.Value
	case ">=":
		return v >= c.Value
	}
	return false
}

// applyDeltas moves stats and clamps them to their declared bounds, so
// no effect can drive a stat outside the range the scenario promised.
func (s *State) applyDeltas(deltas map[string]int) {
	for stat, d := range deltas {
		lim, hasLim := s.Public.Limits[stat]
		if v, ok := s.Public.Resources[stat]; ok {
			s.Public.Resources[stat] = clamp(v+d, lim, hasLim)
			continue
		}
		if v, ok := s.Public.Ratings[stat]; ok {
			s.Public.Ratings[stat] = clamp(v+d, lim, hasLim)
		}
	}
}

func clamp(v int, lim Limit, has bool) int {
	if !has {
		return v
	}
	if v < lim.Min {
		return lim.Min
	}
	if v > lim.Max {
		return lim.Max
	}
	return v
}

// clone deep-copies the maps and slices a transition mutates, so the
// caller's state is never modified in place. Branch independence starts
// here: a resolved turn must not reach back into its parent snapshot.
func (s State) clone() State {
	out := s
	out.Public.Resources = copyIntMap(s.Public.Resources)
	out.Public.Ratings = copyIntMap(s.Public.Ratings)
	out.Public.Labels = copyStrMap(s.Public.Labels)
	out.Public.Limits = make(map[string]Limit, len(s.Public.Limits))
	for k, v := range s.Public.Limits {
		out.Public.Limits[k] = v
	}
	out.Public.History = append([]Entry(nil), s.Public.History...)
	out.Public.Loss = append([]Condition(nil), s.Public.Loss...)
	out.Public.Victory = append([]Condition(nil), s.Public.Victory...)
	out.Director.HiddenFacts = append([]string(nil), s.Director.HiddenFacts...)
	return out
}

func copyIntMap(in map[string]int) map[string]int {
	out := make(map[string]int, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func copyStrMap(in map[string]string) map[string]string {
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func sortedKeys(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// roundHalfUp keeps magnitudes predictable; Go's default float-to-int
// truncation would quietly shave a point off every mixed result.
func roundHalfUp(f float64) int {
	if f < 0 {
		return -int(math.Floor(-f + 0.5))
	}
	return int(math.Floor(f + 0.5))
}
