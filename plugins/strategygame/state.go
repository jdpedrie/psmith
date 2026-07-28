package strategygame

import (
	"fmt"
	"sort"
	"strings"
)

// SchemaVersion is stamped into every snapshot so a future shape change
// can migrate old campaigns instead of misreading them.
const SchemaVersion = 1

// Phase gates which commit kinds are legal. The model cannot initialize
// a running campaign or resolve an uninitialized one, because the plugin
// checks the phase rather than trusting the model to track it.
type Phase string

const (
	PhaseUninitialized Phase = "uninitialized"
	PhaseAwaitingActer Phase = "awaiting_player_action"
	PhaseFinished      Phase = "finished"
)

// State is the authoritative campaign snapshot. Split four ways so the
// renderer can never leak what the model is allowed to know.
type State struct {
	Meta     Meta     `json:"meta"`
	Public   Public   `json:"public"`
	Director Director `json:"director"`
	Protocol Protocol `json:"protocol"`
}

type Meta struct {
	SchemaVersion int    `json:"schema_version"`
	StateVersion  int64  `json:"state_version"`
	Turn          int    `json:"turn"`
	DateLabel     string `json:"date_label,omitempty"`
	Ruleset       string `json:"ruleset"`
	// Seed fixes every die roll in the campaign. Stored rather than
	// drawn so a fork replays identically — see RollFor.
	Seed uint64 `json:"seed"`
}

// Public is everything safe to render. Resources and Ratings are kept
// apart deliberately: resources are spent and accumulate in the
// hundreds, ratings are small and get added to dice. Summing a treasury
// of 4,000 into a 3d6 check is nonsense, and one flat stat map invites
// exactly that mistake.
type Public struct {
	Title     string            `json:"title"`
	Role      string            `json:"role"`
	Premise   string            `json:"premise,omitempty"`
	Resources map[string]int    `json:"resources"`
	Ratings   map[string]int    `json:"ratings"`
	Labels    map[string]string `json:"labels,omitempty"`
	// Limits are the declared bounds every effect clamps to, carried on
	// the snapshot so a reloaded campaign clamps the same way the
	// scenario promised rather than drifting unbounded.
	Limits    map[string]Limit `json:"limits,omitempty"`
	Situation *Situation       `json:"situation,omitempty"`
	// Clocks are the background pressures running alongside the focal
	// situation. They are what make the focal choice hard.
	Clocks  []Clock  `json:"clocks,omitempty"`
	Outcome *Outcome `json:"outcome,omitempty"`
	// Loss / Victory / TurnLimit ride on the state rather than being
	// re-read from the scenario, so the end conditions a campaign was
	// started under cannot change under the player mid-game.
	Loss      []Condition `json:"loss_when"`
	Victory   []Condition `json:"victory_when,omitempty"`
	TurnLimit int         `json:"turn_limit,omitempty"`
	// History is the compact mechanical ledger — what happened, not how
	// it was narrated. Lets a later turn reference turn 4 without the
	// prose of turn 4 being in context.
	History []Entry `json:"history,omitempty"`
}

// Director is model-visible and never rendered. The tool result marks it
// separately from the player-visible payload so a renderer cannot
// accidentally spill hidden facts into the transcript.
type Director struct {
	HiddenFacts []string `json:"hidden_facts,omitempty"`
}

type Protocol struct {
	Phase             Phase    `json:"phase"`
	AllowedCommitKind string   `json:"allowed_commit_kind"`
	LegalChoiceIDs    []string `json:"legal_choice_ids,omitempty"`
}

// Situation is one posed decision. Everything numeric on it was computed
// by the engine; the model supplies only ids, labels and prose.
type Situation struct {
	ID      string   `json:"id"`
	Title   string   `json:"title"`
	Body    string   `json:"body"`
	Choices []Choice `json:"choices"`
}

// Choice is a priced option. Target, Modifier and Odds are engine
// output. They are stored on the snapshot rather than recomputed at
// render time so the number shown on the button is provably the number
// the resolution used.
type Choice struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Rating is which player rating this check adds.
	Rating string `json:"rating"`
	// Difficulty is the authored band name; Target is what it resolved to.
	Difficulty string `json:"difficulty"`
	Target     int    `json:"target"`
	Modifier   int    `json:"modifier"`
	Odds       Odds   `json:"odds"`
	// Stakes scales the magnitude of the effects. Authored tier, not a
	// model-chosen number.
	Stakes string `json:"stakes"`
	// Advances is the stat that improves when the check goes well;
	// Costs is the stat spent regardless.
	Advances string `json:"advances"`
	Costs    string `json:"costs"`
}

// Limit is the inclusive range a stat is clamped to.
type Limit struct {
	Min int `json:"min"`
	Max int `json:"max"`
}

// Outcome ends a campaign.
type Outcome struct {
	Victory bool   `json:"victory"`
	Label   string `json:"label"`
	Turn    int    `json:"turn"`
}

// Entry is one line of the mechanical ledger.
type Entry struct {
	Turn      int            `json:"turn"`
	Situation string         `json:"situation"`
	Choice    string         `json:"choice"`
	Band      Band           `json:"band"`
	Roll      int            `json:"roll"`
	Target    int            `json:"target"`
	Deltas    map[string]int `json:"deltas,omitempty"`
}

// Label returns the display name for a stat id, falling back to the id.
func (p Public) Label(stat string) string {
	if l, ok := p.Labels[stat]; ok && l != "" {
		return l
	}
	return stat
}

// StatValue reads a stat from whichever map owns it.
func (p Public) StatValue(stat string) (int, bool) {
	if v, ok := p.Resources[stat]; ok {
		return v, true
	}
	if v, ok := p.Ratings[stat]; ok {
		return v, true
	}
	return 0, false
}

// SortedStats returns resource ids then rating ids, each alphabetical,
// so the status panel renders in a stable order across turns rather than
// reshuffling with Go's map iteration.
func (p Public) SortedStats() (resources, ratings []string) {
	for k := range p.Resources {
		resources = append(resources, k)
	}
	for k := range p.Ratings {
		ratings = append(ratings, k)
	}
	sort.Strings(resources)
	sort.Strings(ratings)
	return resources, ratings
}

// ChoiceByID finds a choice on the active situation.
func (s State) ChoiceByID(id string) (Choice, bool) {
	if s.Public.Situation == nil {
		return Choice{}, false
	}
	for _, c := range s.Public.Situation.Choices {
		if strings.EqualFold(c.ID, id) {
			return c, true
		}
	}
	return Choice{}, false
}

// Validate catches a snapshot that could not have come from this engine.
// Cheap insurance against a hand-edited or partially-written blob being
// treated as authoritative.
func (s State) Validate() error {
	if s.Meta.SchemaVersion == 0 {
		return fmt.Errorf("state: missing schema_version")
	}
	if s.Meta.SchemaVersion > SchemaVersion {
		return fmt.Errorf("state: schema_version %d is newer than this build understands (%d)",
			s.Meta.SchemaVersion, SchemaVersion)
	}
	switch s.Protocol.Phase {
	case PhaseUninitialized, PhaseAwaitingActer, PhaseFinished:
	default:
		return fmt.Errorf("state: unknown phase %q", s.Protocol.Phase)
	}
	return nil
}
