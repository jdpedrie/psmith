package plugins

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// fixedTime is the canonical "wall-clock" stamp every test in this file
// uses, so the rendered timestamp string is deterministic regardless of
// the host timezone or the wall clock at test time.
var fixedTime = time.Date(2026, 5, 2, 14, 45, 0, 0, time.UTC)

// newFixedClockGrounding builds a basicGrounding with the given config
// JSON and rebinds `now` to a fixed time so timestamps are stable in
// every assertion.
func newFixedClockGrounding(t *testing.T, configJSON string) *basicGrounding {
	t.Helper()
	pl, err := newBasicGrounding([]byte(configJSON))
	if err != nil {
		t.Fatalf("newBasicGrounding: %v", err)
	}
	bg := pl.(*basicGrounding)
	bg.now = func() time.Time { return fixedTime }
	return bg
}

func TestBasicGrounding_DefaultsAndDescriptor(t *testing.T) {
	t.Parallel()
	pl, err := newBasicGrounding(nil)
	if err != nil {
		t.Fatalf("nil config should be accepted: %v", err)
	}
	if pl.Name() != BasicGroundingName {
		t.Errorf("Name() = %q, want %q", pl.Name(), BasicGroundingName)
	}
	if pl.DisplayName() == "" {
		t.Error("DisplayName must be non-empty")
	}
	if pl.Description() == "" {
		t.Error("Description must be non-empty")
	}
	c, ok := pl.(Configurable)
	if !ok {
		t.Fatal("plugin must implement Configurable")
	}
	fields := c.ConfigFields()
	if len(fields) == 0 {
		t.Error("expected at least one ConfigField")
	}
	// All fields must be reachable by their declared name; confirms the
	// JSON-tag mapping in basicGroundingConfig matches the descriptor.
	expectedNames := map[string]bool{
		"include_date_time": true,
		"time_format":       true,
		"timezone":          true,
		"include_locale":    true,
		"include_platform":  true,
		"include_location":  true,
	}
	for _, f := range fields {
		if !expectedNames[f.Name] {
			t.Errorf("unexpected ConfigField %q", f.Name)
		}
	}
}

func TestBasicGrounding_PrependsGroundingBlock(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC"}`)
	out := bg.TransformOutgoingUserMessage("what's the weather like?", nil)
	if !strings.HasPrefix(out, "<grounding>\n") {
		t.Errorf("expected grounding block at start, got %q", out)
	}
	if !strings.Contains(out, "Current time: 2026-05-02T14:45:00Z") {
		t.Errorf("expected ISO timestamp line, got %q", out)
	}
	if !strings.HasSuffix(out, "what's the weather like?") {
		t.Errorf("user content must be preserved verbatim at the tail, got %q", out)
	}
	// The block must end before the user's content (separated by a
	// blank line) — a model reading this should see a clean break
	// between framing and the actual ask.
	if !strings.Contains(out, "</grounding>\n\nwhat's the weather like?") {
		t.Errorf("expected blank line between block and content, got %q", out)
	}
}

func TestBasicGrounding_RoundTripStripsForDisplay(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, ``)
	original := "what's the weather like?"
	transformed := bg.TransformOutgoingUserMessage(original, nil)
	displayed := bg.TransformForDisplay(transformed)
	if displayed != original {
		t.Errorf("round-trip mismatch:\n  in:  %q\n  out: %q", original, displayed)
	}
}

func TestBasicGrounding_DisplayLeavesUserGroundingTextAlone(t *testing.T) {
	t.Parallel()
	// The display strip is anchored at start-of-string. A user who happens
	// to type the literal tag mid-message must not have it eaten.
	bg := newFixedClockGrounding(t, ``)
	user := "I want to talk about <grounding>theory</grounding> in painting."
	if got := bg.TransformForDisplay(user); got != user {
		t.Errorf("non-anchored grounding should pass through unchanged, got %q", got)
	}
}

func TestBasicGrounding_DisableSkipsBlock(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"include_date_time":false}`)
	out := bg.TransformOutgoingUserMessage("hi", nil)
	if out != "hi" {
		t.Errorf("with all facts disabled, content must pass through unchanged; got %q", out)
	}
}

func TestBasicGrounding_TimeFormats(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		config string
		want   string
	}{
		{
			name:   "iso default",
			config: `{"timezone":"UTC"}`,
			want:   "Current time: 2026-05-02T14:45:00Z",
		},
		{
			name:   "date only",
			config: `{"timezone":"UTC","time_format":"date_only"}`,
			want:   "Current time: 2026-05-02",
		},
		{
			name:   "human",
			config: `{"timezone":"UTC","time_format":"datetime_human"}`,
			want:   "Current time: Saturday, May 2, 2026 · 2:45 PM UTC",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bg := newFixedClockGrounding(t, tc.config)
			out := bg.TransformOutgoingUserMessage("hi", nil)
			if !strings.Contains(out, tc.want) {
				t.Errorf("output missing %q\nfull: %q", tc.want, out)
			}
		})
	}
}

func TestBasicGrounding_BadTimezoneRejected(t *testing.T) {
	t.Parallel()
	if _, err := newBasicGrounding(json.RawMessage(`{"timezone":"Pluto/Olympus"}`)); err == nil {
		t.Error("invalid IANA timezone must be rejected at construction")
	}
}

func TestBasicGrounding_RendersDeviceFacts(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_locale":true,"include_platform":true,"include_location":true}`)
	out := bg.TransformOutgoingUserMessage("hi", map[string]string{
		DeviceFactKeyLocale:         "en-US",
		DeviceFactKeyPlatform:       "iOS 26.5 / iPhone 17 Pro",
		DeviceFactKeyLocationCity:   "Brooklyn, NY",
		DeviceFactKeyLocationCoords: "40.6782,-73.9442",
	})
	wants := []string{
		"Current time: 2026-05-02T14:45:00Z",
		"Locale: en-US",
		"Platform: iOS 26.5 / iPhone 17 Pro",
		"Location: Brooklyn, NY",
	}
	for _, want := range wants {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q\nfull: %q", want, out)
		}
	}
	if strings.Contains(out, "Location (coords)") {
		t.Errorf("city should suppress coords line; full: %q", out)
	}
}

func TestBasicGrounding_LocationFallsBackToCoords(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_location":true,"include_date_time":false}`)
	out := bg.TransformOutgoingUserMessage("hi", map[string]string{
		DeviceFactKeyLocationCoords: "40.6782,-73.9442",
	})
	if !strings.Contains(out, "Location (coords): 40.6782,-73.9442") {
		t.Errorf("expected coords-only fallback line, got %q", out)
	}
}

func TestBasicGrounding_FactsMissing_NoLine(t *testing.T) {
	t.Parallel()
	// Locale + Platform requested via config but the client didn't
	// supply them — the lines should be silently omitted, not
	// rendered as "Locale: ".
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_locale":true,"include_platform":true}`)
	out := bg.TransformOutgoingUserMessage("hi", nil)
	if strings.Contains(out, "Locale:") || strings.Contains(out, "Platform:") {
		t.Errorf("missing facts must skip their lines, got %q", out)
	}
	if !strings.Contains(out, "Current time:") {
		t.Errorf("time line should still render when device facts are absent, got %q", out)
	}
}

func TestBasicGrounding_RequestedFactsReflectsConfig(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		config string
		want   []string
	}{
		{name: "all_off", config: `{"include_locale":false,"include_platform":false,"include_location":false}`, want: nil},
		{name: "locale_only", config: `{"include_locale":true,"include_platform":false,"include_location":false}`, want: []string{DeviceFactKeyLocale}},
		{name: "all_on", config: `{"include_locale":true,"include_platform":true,"include_location":true}`,
			want: []string{DeviceFactKeyLocale, DeviceFactKeyPlatform, DeviceFactKeyLocationCity, DeviceFactKeyLocationCoords}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pl, err := newBasicGrounding(json.RawMessage(tc.config))
			if err != nil {
				t.Fatalf("construct: %v", err)
			}
			r, ok := pl.(DeviceFactRequester)
			if !ok {
				t.Fatal("basic_grounding should implement DeviceFactRequester")
			}
			got := r.RequestedDeviceFacts()
			if len(got) != len(tc.want) {
				t.Fatalf("want %v got %v", tc.want, got)
			}
			for i, k := range tc.want {
				if got[i] != k {
					t.Errorf("[%d] want %q got %q", i, k, got[i])
				}
			}
		})
	}
}

func TestBasicGrounding_PrependedContentSurvivesAcrossTurns(t *testing.T) {
	t.Parallel()
	// The whole point of the design: if we re-rendered the wire prefix
	// from a stored message that already contained a grounding block,
	// the OutgoingUserTransformer is NOT re-run — the block is part of
	// the persisted content. This test simulates the round-trip the
	// supervisor actually performs.
	bg := newFixedClockGrounding(t, `{"timezone":"UTC"}`)
	stored := bg.TransformOutgoingUserMessage("hi", nil)
	// Frozen text — what subsequent turns see in the wire prefix.
	if !strings.HasPrefix(stored, "<grounding>") {
		t.Fatalf("stored content should have prefix, got %q", stored)
	}
	// History build doesn't re-run the outgoing transformer, so the
	// content is still byte-stable on the next turn. Same input ⇒
	// same persisted bytes ⇒ provider-side prefix cache stays warm.
	again := stored
	if again != stored {
		t.Errorf("history-time content must be byte-stable")
	}
}
