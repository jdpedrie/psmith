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

func TestBasicGrounding_HeaderBlock(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC"}`)
	header, trailer := bg.OutgoingMessageEnvelope(nil)
	if trailer != "" {
		t.Errorf("basic_grounding contributes headers only, got trailer %q", trailer)
	}
	if !strings.HasPrefix(header, "<grounding>\n") {
		t.Errorf("expected grounding block at start, got %q", header)
	}
	if !strings.Contains(header, "Current time: 2026-05-02T14:45:00Z") {
		t.Errorf("expected ISO timestamp line, got %q", header)
	}
	if !strings.HasSuffix(header, "</grounding>") {
		t.Errorf("header should end with the close tag (the history builder owns the blank-line join), got %q", header)
	}
}

func TestBasicGrounding_DisplayStripsLegacyEmbeddedBlock(t *testing.T) {
	t.Parallel()
	// Rows written before message_headers existed carry the block
	// inline in content. The display strip must keep working for them.
	bg := newFixedClockGrounding(t, ``)
	original := "what's the weather like?"
	header, _ := bg.OutgoingMessageEnvelope(nil)
	legacy := header + "\n\n" + original
	displayed := bg.TransformForDisplay(legacy)
	if displayed != original {
		t.Errorf("legacy strip mismatch:\n  in:  %q\n  out: %q", legacy, displayed)
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
	header, trailer := bg.OutgoingMessageEnvelope(nil)
	if header != "" || trailer != "" {
		t.Errorf("with all facts disabled, no envelope should render; got header %q trailer %q", header, trailer)
	}
}

func TestBasicGrounding_TimezoneFactUsedWhenConfigEmpty(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, ``)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyTimezone: "America/New_York",
	})
	// fixedTime is 2026-05-02T14:45:00Z; in NYC that's 10:45 AM EDT
	// (-04:00).
	if !strings.Contains(out, "Current time: 2026-05-02T10:45:00-04:00") {
		t.Errorf("expected NYC-local ISO timestamp, got %q", out)
	}
}

func TestBasicGrounding_ConfigTimezoneBeatsFact(t *testing.T) {
	t.Parallel()
	// Explicit config wins over the device fact — predictable for users
	// who deliberately pinned a zone (e.g. a server-side smoke profile).
	bg := newFixedClockGrounding(t, `{"timezone":"Asia/Tokyo"}`)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyTimezone: "America/New_York",
	})
	if !strings.Contains(out, "Current time: 2026-05-02T23:45:00+09:00") {
		t.Errorf("expected Tokyo-local timestamp, got %q", out)
	}
}

func TestBasicGrounding_NoTimezoneFallsBackToUTC(t *testing.T) {
	t.Parallel()
	// No config, no fact → UTC (NOT server-local). This is the
	// whole point of the change: a cloud-hosted clarkd's "local"
	// time is meaningless to the user.
	bg := newFixedClockGrounding(t, ``)
	out, _ := bg.OutgoingMessageEnvelope(nil)
	if !strings.Contains(out, "Current time: 2026-05-02T14:45:00Z") {
		t.Errorf("expected UTC timestamp, got %q", out)
	}
}

func TestBasicGrounding_BadTimezoneFactFallsBackToUTC(t *testing.T) {
	t.Parallel()
	// Malformed device fact must not crash the send; silent fallback
	// is fine because the constructor already validates user-supplied
	// config and the device value comes from an untrusted client.
	bg := newFixedClockGrounding(t, ``)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyTimezone: "Pluto/Olympus",
	})
	if !strings.Contains(out, "Current time: 2026-05-02T14:45:00Z") {
		t.Errorf("expected UTC fallback, got %q", out)
	}
}

func TestBasicGrounding_RequestsTimezoneFactOnlyWhenNeeded(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name        string
		config      string
		wantInList  bool
		description string
	}{
		{
			name:        "default: requests timezone",
			config:      ``,
			wantInList:  true,
			description: "IncludeDateTime on + no Timezone config → need the fact for fallback",
		},
		{
			name:        "explicit timezone: skips request",
			config:      `{"timezone":"America/New_York"}`,
			wantInList:  false,
			description: "Config pins the zone, so the fact is unused",
		},
		{
			name:        "date_time off: skips request",
			config:      `{"include_date_time":false}`,
			wantInList:  false,
			description: "No timestamp to render, no need for tz",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pl, err := newBasicGrounding(json.RawMessage(tc.config))
			if err != nil {
				t.Fatalf("construct: %v", err)
			}
			r := pl.(DeviceFactRequester)
			got := r.RequestedDeviceFacts()
			has := false
			for _, k := range got {
				if k == DeviceFactKeyTimezone {
					has = true
					break
				}
			}
			if has != tc.wantInList {
				t.Errorf("%s: tz-in-requested=%v want %v", tc.description, has, tc.wantInList)
			}
		})
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
			out, _ := bg.OutgoingMessageEnvelope(nil)
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
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyLocale:         "en-US",
		DeviceFactKeyPlatform:       "iOS 26.5 / iPhone 17 Pro",
		DeviceFactKeyLocationCity:   "Brooklyn, NY",
		DeviceFactKeyLocationCoords: "40.6782,-73.9442",
	})
	wants := []string{
		"Current time: 2026-05-02T14:45:00Z",
		"Locale: en-US",
		"Platform: iOS 26.5 / iPhone 17 Pro",
		// City + coords on one line: city is the anchor, coords
		// give the model precision for distance / neighborhood math.
		"Location: Brooklyn, NY (40.6782,-73.9442)",
	}
	for _, want := range wants {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q\nfull: %q", want, out)
		}
	}
	if strings.Contains(out, "Location (coords)") {
		t.Errorf("with city present, the coords-only fallback line should not appear; full: %q", out)
	}
}

// TestBasicGrounding_LocationRendersByDefault pins the default flip:
// when the client supplies location facts, the plugin renders the line
// out of the box — no per-plugin opt-in needed. The device-side
// Privacy toggle is the actual permission gate.
func TestBasicGrounding_LocationRendersByDefault(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC"}`)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyLocationCity:   "Brooklyn, NY",
		DeviceFactKeyLocationCoords: "40.6782,-73.9442",
	})
	if !strings.Contains(out, "Location: Brooklyn, NY (40.6782,-73.9442)") {
		t.Errorf("location should render under default config when device sent facts; got %q", out)
	}
}

// Explicit per-profile opt-out still works — useful for a "work" profile
// that wants to ignore location even when the device is supplying it.
func TestBasicGrounding_LocationExplicitOptOut(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_location":false}`)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyLocationCity:   "Brooklyn, NY",
		DeviceFactKeyLocationCoords: "40.6782,-73.9442",
	})
	if strings.Contains(out, "Location:") {
		t.Errorf("explicit include_location=false should suppress the line; got %q", out)
	}
}

func TestBasicGrounding_LocationCityOnly(t *testing.T) {
	t.Parallel()
	// City present but no coords (e.g. before reverse-geocode finished
	// or in a region where the gateway suppresses coords).
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_location":true,"include_date_time":false}`)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
		DeviceFactKeyLocationCity: "Brooklyn, NY",
	})
	if !strings.Contains(out, "Location: Brooklyn, NY\n") && !strings.HasSuffix(out, "Location: Brooklyn, NY") {
		t.Errorf("expected city-only line, got %q", out)
	}
	if strings.Contains(out, "(") {
		t.Errorf("city-only line should not include coords parens, got %q", out)
	}
}

func TestBasicGrounding_LocationFallsBackToCoords(t *testing.T) {
	t.Parallel()
	bg := newFixedClockGrounding(t, `{"timezone":"UTC","include_location":true,"include_date_time":false}`)
	out, _ := bg.OutgoingMessageEnvelope(map[string]string{
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
	out, _ := bg.OutgoingMessageEnvelope(nil)
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
		// IncludeDateTime defaults on and Timezone defaults empty, so
		// the timezone fact comes along for the ride whenever the
		// time-render path is live.
		{name: "all_off_except_datetime", config: `{"include_locale":false,"include_platform":false,"include_location":false}`,
			want: []string{DeviceFactKeyTimezone}},
		{name: "locale_only_with_datetime", config: `{"include_locale":true,"include_platform":false,"include_location":false}`,
			want: []string{DeviceFactKeyTimezone, DeviceFactKeyLocale}},
		{name: "all_on", config: `{"include_locale":true,"include_platform":true,"include_location":true}`,
			want: []string{DeviceFactKeyTimezone, DeviceFactKeyLocale, DeviceFactKeyPlatform, DeviceFactKeyLocationCity, DeviceFactKeyLocationCoords}},
		// Timestamp off → no timezone fact requested either.
		{name: "datetime_off", config: `{"include_date_time":false,"include_locale":false,"include_platform":false,"include_location":false}`,
			want: nil},
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

func TestBasicGrounding_HeaderRendersOnceAtWriteTime(t *testing.T) {
	t.Parallel()
	// The cache-stability contract: the envelope is rendered exactly
	// once, at SEND time, and persisted in message_headers. History
	// builds compose the STORED header — they never re-invoke the
	// plugin — so the wall-clock value is frozen and the provider-side
	// prefix cache stays warm as the conversation grows. This test
	// pins the render side; the compose side lives in the history
	// builder's tests.
	bg := newFixedClockGrounding(t, `{"timezone":"UTC"}`)
	stored, _ := bg.OutgoingMessageEnvelope(nil)
	if !strings.HasPrefix(stored, "<grounding>") {
		t.Fatalf("stored header should carry the block, got %q", stored)
	}
	again, _ := bg.OutgoingMessageEnvelope(nil)
	if again != stored {
		t.Errorf("same clock ⇒ byte-identical header; got drift:\n  %q\n  %q", stored, again)
	}
}
