package gamemaster

import (
	"strings"
	"testing"
)

func demoStats() map[string]bool {
	return map[string]bool{"treasury": true, "unrest": true, "guile": true, "standing": true}
}

func TestPriceClock_UsesAuthoredTables(t *testing.T) {
	t.Parallel()
	c, err := PriceClock(ClockDraft{
		ID: "famine", Label: "The granaries empty", Length: "medium", Weight: "major",
		Drains: "treasury", Strikes: "unrest", Ominous: true,
	}, demoStats())
	if err != nil {
		t.Fatalf("price: %v", err)
	}
	if c.Remaining != 4 {
		t.Errorf("medium should run 4 turns; got %d", c.Remaining)
	}
	// The bleed must be real but smaller than the payload, or ignoring a
	// clock is either free or instantly fatal.
	drain := -c.Drain["treasury"]
	payload := -c.Payload["unrest"]
	if drain <= 0 {
		t.Errorf("a running clock must bleed something; got %d", drain)
	}
	if drain >= payload {
		t.Errorf("per-turn drain (%d) should be well under the payload (%d)", drain, payload)
	}
}

func TestPriceClock_RejectsInventedTags(t *testing.T) {
	t.Parallel()
	base := ClockDraft{ID: "x", Label: "X", Length: "medium", Weight: "major", Drains: "treasury", Strikes: "unrest"}
	for name, mutate := range map[string]func(*ClockDraft){
		"length":  func(d *ClockDraft) { d.Length = "eternal" },
		"weight":  func(d *ClockDraft) { d.Weight = "apocalyptic" },
		"drains":  func(d *ClockDraft) { d.Drains = "morale" },
		"strikes": func(d *ClockDraft) { d.Strikes = "morale" },
		"id":      func(d *ClockDraft) { d.ID = "" },
	} {
		d := base
		mutate(&d)
		if _, err := PriceClock(d, demoStats()); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

// TestTickClocks_BleedsThenFires pins the ordering: a clock that runs out
// this turn still charges its final drain. The last week of a famine is
// not free just because relief arrives at the end of it.
func TestTickClocks_BleedsThenFires(t *testing.T) {
	t.Parallel()
	c := Clock{
		ID: "siege", Label: "The siege tightens", Remaining: 1,
		Drain:   map[string]int{"treasury": -2},
		Payload: map[string]int{"unrest": -15},
	}
	remaining, deltas, events := TickClocks([]Clock{c})
	if len(remaining) != 0 {
		t.Errorf("an expiring clock should be removed; %d left", len(remaining))
	}
	if deltas["treasury"] != -2 {
		t.Errorf("final drain should still apply; treasury %d", deltas["treasury"])
	}
	if deltas["unrest"] != -15 {
		t.Errorf("payload should land; unrest %d", deltas["unrest"])
	}
	if len(events) != 1 || !strings.Contains(events[0], "siege") {
		t.Errorf("expiry should be narratable; got %v", events)
	}
}

func TestTickClocks_LongClockKeepsRunning(t *testing.T) {
	t.Parallel()
	c := Clock{ID: "inquiry", Label: "The inquiry", Remaining: 3, Drain: map[string]int{"standing": -1}}
	remaining, deltas, events := TickClocks([]Clock{c})
	if len(remaining) != 1 || remaining[0].Remaining != 2 {
		t.Fatalf("clock should tick down and survive; got %+v", remaining)
	}
	if deltas["standing"] != -1 {
		t.Errorf("drain should apply while running; got %d", deltas["standing"])
	}
	if len(events) != 0 {
		t.Errorf("a running clock is not an event; got %v", events)
	}
}

// TestResolveClock_SkipsThePayload is the reward for actually solving the
// problem rather than riding it out.
func TestResolveClock_SkipsThePayload(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	st.Public.Clocks = []Clock{{
		ID: "famine", Label: "Famine", Remaining: 1,
		Payload: map[string]int{"treasury": -50},
	}}
	if !st.ResolveClock("famine") {
		t.Fatal("expected the clock to be found")
	}
	if len(st.Public.Clocks) != 0 {
		t.Error("resolved clock should be gone")
	}
	if _, deltas, _ := TickClocks(st.Public.Clocks); len(deltas) != 0 {
		t.Errorf("a resolved clock must not fire its payload; got %v", deltas)
	}
	if st.ResolveClock("nonexistent") {
		t.Error("resolving an unknown clock should report failure")
	}
}

// TestResolve_ClocksTickWithTheTurn is the integration point: background
// pressure accrues whether or not the player looked at it.
func TestResolve_ClocksTickWithTheTurn(t *testing.T) {
	t.Parallel()
	st := mustInit(t)
	st.Public.Clocks = []Clock{{
		ID: "debt", Label: "The creditors call in", Remaining: 5,
		Drain: map[string]int{"treasury": -4},
	}}
	before := st.Public.Resources["treasury"]

	tr, next, err := Resolve(st, "A")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if tr.ClockDeltas["treasury"] != -4 {
		t.Errorf("clock drain should be reported separately from the choice's cost; got %v", tr.ClockDeltas)
	}
	// The turn's own cost AND the clock drain both landed.
	if next.Public.Resources["treasury"] >= before-4 {
		t.Errorf("both the choice cost and the drain should apply: %d -> %d", before, next.Public.Resources["treasury"])
	}
	if next.Public.Clocks[0].Remaining != 4 {
		t.Errorf("clock should have ticked; got %d", next.Public.Clocks[0].Remaining)
	}
	// The parent is untouched, same as every other transition.
	if st.Public.Clocks[0].Remaining != 5 {
		t.Error("resolving mutated the parent's clocks")
	}
}
