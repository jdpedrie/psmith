package gamemaster

import (
	"fmt"
	"sort"
	"strings"
)

// Clock is a background pressure running alongside the focal situation:
// a famine, a siege, an investigation closing in.
//
// This is the difference between a management game and a branching story.
// Without clocks each turn is a self-contained dilemma and the only
// question is which option reads best. With them the focal choice is
// hard because of what else is running: spending the treasury on grain
// is a different decision when a mercenary contract comes due in two
// turns, and the player can see both.
type Clock struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Remaining counts down one per turn. At zero the clock fires its
	// payload and is removed.
	Remaining int `json:"remaining"`
	// Drain is applied every turn while the clock runs — the slow bleed
	// that makes a long-running crisis cost something even when it is
	// not the thing you are looking at.
	Drain map[string]int `json:"drain,omitempty"`
	// Payload lands once, when the clock expires.
	Payload map[string]int `json:"payload,omitempty"`
	// Ominous marks a clock whose payload is bad news, so the UI can
	// distinguish "reinforcements arrive in 3" from "the creditors call
	// in 3" without the model having to say so in numbers.
	Ominous bool `json:"ominous"`
}

// ClockDraft is the model's proposal. Same discipline as choices: no
// numbers. Length and severity are tag vocabulary the engine prices.
type ClockDraft struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Length  string `json:"length"`  // short | medium | long
	Weight  string `json:"weight"`  // minor | standard | major
	Drains  string `json:"drains"`  // stat bled each turn
	Strikes string `json:"strikes"` // stat hit when it expires
	Ominous bool   `json:"ominous"`
}

// clockLengths is the authored turn-count table.
var clockLengths = map[string]int{
	"short":  2,
	"medium": 4,
	"long":   7,
}

// ClockLengthNames returns the legal lengths, shortest first.
func ClockLengthNames() []string {
	out := make([]string, 0, len(clockLengths))
	for k := range clockLengths {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return clockLengths[out[i]] < clockLengths[out[j]] })
	return out
}

// PriceClock turns a draft into a running clock. Drain is deliberately a
// fraction of the payload: a crisis should hurt a little every turn and
// a lot when it lands, so ignoring it is a real gamble rather than a
// free delay.
func PriceClock(d ClockDraft, stats map[string]bool) (Clock, error) {
	if strings.TrimSpace(d.ID) == "" {
		return Clock{}, fmt.Errorf("clock: id is required")
	}
	if strings.TrimSpace(d.Label) == "" {
		return Clock{}, fmt.Errorf("clock %q: label is required", d.ID)
	}
	turns, ok := clockLengths[d.Length]
	if !ok {
		return Clock{}, fmt.Errorf("clock %q: unknown length %q (want one of %v)", d.ID, d.Length, ClockLengthNames())
	}
	unit, ok := stakesUnits[d.Weight]
	if !ok {
		return Clock{}, fmt.Errorf("clock %q: unknown weight %q (want one of %v)", d.ID, d.Weight, StakesNames())
	}
	if !stats[d.Drains] {
		return Clock{}, fmt.Errorf("clock %q: drains unknown stat %q", d.ID, d.Drains)
	}
	if !stats[d.Strikes] {
		return Clock{}, fmt.Errorf("clock %q: strikes unknown stat %q", d.ID, d.Strikes)
	}
	c := Clock{
		ID:        d.ID,
		Label:     d.Label,
		Remaining: turns,
		Ominous:   d.Ominous,
		Drain:     map[string]int{},
		Payload:   map[string]int{},
	}
	// A third of the weight per turn, minimum 1, so even a minor clock
	// registers rather than rounding away to nothing.
	perTurn := roundHalfUp(float64(unit) / 3)
	if perTurn < 1 {
		perTurn = 1
	}
	c.Drain[d.Drains] = -perTurn
	c.Payload[d.Strikes] = -unit
	return c, nil
}

// TickClocks advances every running clock one turn, returning the
// combined stat deltas and a human-readable account of what happened.
//
// Drains apply first and expiries second, so a clock that runs out this
// turn still charges its final drain — the last week of a famine is not
// free just because relief arrives at the end of it.
func TickClocks(clocks []Clock) (remaining []Clock, deltas map[string]int, events []string) {
	deltas = map[string]int{}
	for _, c := range clocks {
		for stat, d := range c.Drain {
			deltas[stat] += d
		}
		c.Remaining--
		if c.Remaining > 0 {
			remaining = append(remaining, c)
			continue
		}
		for stat, d := range c.Payload {
			deltas[stat] += d
		}
		events = append(events, fmt.Sprintf("%s came due.", c.Label))
	}
	// Drop any all-zero entries so the ledger stays readable.
	for stat, d := range deltas {
		if d == 0 {
			delete(deltas, stat)
		}
	}
	return remaining, deltas, events
}

// ClockByID finds a running clock.
func (s State) ClockByID(id string) (Clock, bool) {
	for _, c := range s.Public.Clocks {
		if strings.EqualFold(c.ID, id) {
			return c, true
		}
	}
	return Clock{}, false
}

// ResolveClock removes a clock without firing its payload — what
// happens when the player actually deals with the underlying problem.
func (s *State) ResolveClock(id string) bool {
	for i, c := range s.Public.Clocks {
		if strings.EqualFold(c.ID, id) {
			s.Public.Clocks = append(s.Public.Clocks[:i:i], s.Public.Clocks[i+1:]...)
			return true
		}
	}
	return false
}
