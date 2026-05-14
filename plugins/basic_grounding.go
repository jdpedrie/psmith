package plugins

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// BasicGroundingName is the registered name for the basic-grounding plugin.
const BasicGroundingName = "basic_grounding"

// Tag pair the plugin wraps grounding facts in. Stable across releases —
// changing it would orphan stripping on existing message rows. Picked to
// be unambiguous (an XML-style tag the user is unlikely to type
// verbatim) so the display strip can't false-positive on user content.
const (
	groundingOpenTag  = "<grounding>"
	groundingCloseTag = "</grounding>"
)

// basicGrounding adds small "ground facts" the model often gets wrong
// without help — currently just the current date/time, with room for
// more (location, user-specified facts, …) later.
//
// Implements the existing plugin interfaces:
//
//   - OutgoingUserTransformer: prepends a `<grounding>…</grounding>` block
//     to the outgoing user message at SEND time. The framework persists
//     the rewritten content on the user row, so the same wall-clock
//     value lands in history exactly once and stays put on every
//     subsequent build of the wire prefix. Re-rendering at history-build
//     time would tick "current time" forward each turn and bust the
//     provider-side prefix cache — which is the whole reason the value
//     is frozen at write time.
//   - DisplayTransformer: strips its own `<grounding>` block (delimiters
//     and content) so the chat UI never shows the framing.
//
// CacheStable: the persisted user message row is byte-stable after write,
// so the plugin's contribution doesn't bust the prefix cache as the
// conversation grows.
type basicGrounding struct {
	cfg basicGroundingConfig
	// now is a seam for tests. Production reads `time.Now()`; tests
	// inject a fixed clock.
	now func() time.Time
}

// basicGroundingConfig is the per-instance config blob. Every field is
// optional with sensible defaults.
type basicGroundingConfig struct {
	// IncludeDateTime toggles the time fact. Default on — the
	// model losing track of "today" was the original reason this
	// plugin exists, so it's the most useful single fact.
	IncludeDateTime bool `json:"include_date_time"`

	// TimeFormat picks the wall-clock format. One of
	// "datetime_iso", "datetime_human", "date_only". Empty = datetime_iso.
	TimeFormat string `json:"time_format"`

	// Timezone is the IANA zone the timestamp renders in (e.g.
	// "America/New_York"). Empty = the host's local timezone.
	Timezone string `json:"timezone"`

	// IncludeLocale renders "Locale: en-US" from the client-
	// supplied DeviceFactKeyLocale. Default on — zero permission
	// cost, lets the model pick units / date formats / language
	// without asking.
	IncludeLocale bool `json:"include_locale"`

	// IncludePlatform renders "Platform: iOS 26.5 / iPhone 17 Pro"
	// from the client-supplied DeviceFactKeyPlatform. Default on —
	// also zero permission cost; useful for tech-support framing
	// where the answer is OS/device-specific.
	IncludePlatform bool `json:"include_platform"`

	// IncludeLocation renders "Location: Brooklyn, NY" (and/or
	// the raw coords as a fallback) from the client-supplied
	// DeviceFactKeyLocationCity / DeviceFactKeyLocationCoords.
	// Default OFF — opt-in because it triggers an OS-level
	// location-permission prompt on the client.
	IncludeLocation bool `json:"include_location"`
}

func newBasicGrounding(configBytes json.RawMessage) (Plugin, error) {
	cfg := basicGroundingConfig{
		IncludeDateTime: true,
		TimeFormat:      "datetime_iso",
		IncludeLocale:   true,
		IncludePlatform: true,
		// IncludeLocation deliberately defaults off — permission
		// gate on the client.
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("basic_grounding: parse config: %w", err)
		}
		if cfg.TimeFormat == "" {
			cfg.TimeFormat = "datetime_iso"
		}
		if cfg.Timezone != "" {
			if _, err := time.LoadLocation(cfg.Timezone); err != nil {
				return nil, fmt.Errorf("basic_grounding: invalid timezone %q: %w", cfg.Timezone, err)
			}
		}
	}
	return &basicGrounding{cfg: cfg, now: time.Now}, nil
}

func init() {
	Register(BasicGroundingName, newBasicGrounding)
}

func (p *basicGrounding) Name() string        { return BasicGroundingName }
func (p *basicGrounding) DisplayName() string { return "Basic Grounding" }

func (p *basicGrounding) Description() string {
	return "Prepends small grounding facts (currently the wall-clock time) " +
		"to every outgoing user message and hides them from display. " +
		"Helps models that would otherwise hallucinate today's date or " +
		"reason as if it's their training-data cutoff."
}

// --- Configurable ---

func (p *basicGrounding) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "include_date_time",
			Display:     "Include current date/time",
			Description: "Prepend the current wall-clock to every outgoing user message.",
			Type:        ConfigFieldBoolean,
			Default:     true,
		},
		{
			Name:        "time_format",
			Display:     "Time format",
			Description: "How the timestamp is formatted in the prepended block.",
			Type:        ConfigFieldSelect,
			Default:     "datetime_iso",
			Options: []ConfigOption{
				{Value: "datetime_iso", Label: "ISO 8601 (2026-05-02T14:45:00-04:00)"},
				{Value: "datetime_human", Label: "Human (Saturday, May 2, 2026 · 2:45 PM EDT)"},
				{Value: "date_only", Label: "Date only (2026-05-02)"},
			},
		},
		{
			Name:        "timezone",
			Display:     "Timezone (IANA)",
			Description: "Optional IANA zone for the timestamp (e.g. America/New_York). Empty = host's local zone.",
			Type:        ConfigFieldText,
		},
		{
			Name:        "include_locale",
			Display:     "Include locale",
			Description: "Send the user's locale (e.g. en-US) so the model can pick units, date formats, and language without asking. No OS permission required.",
			Type:        ConfigFieldBoolean,
			Default:     true,
		},
		{
			Name:        "include_platform",
			Display:     "Include platform",
			Description: "Send the OS + device (e.g. \"iOS 26.5 / iPhone 17 Pro\"). Useful for tech-support framing. No OS permission required.",
			Type:        ConfigFieldBoolean,
			Default:     true,
		},
		{
			Name:        "include_location",
			Display:     "Include current location",
			Description: "Send the user's current location (city/region; coordinates as fallback). Triggers an OS-level location-permission prompt on the device.",
			Type:        ConfigFieldBoolean,
			Default:     false,
		},
	}
}

// --- DeviceFactRequester ---

func (p *basicGrounding) RequestedDeviceFacts() []string {
	var keys []string
	if p.cfg.IncludeLocale {
		keys = append(keys, DeviceFactKeyLocale)
	}
	if p.cfg.IncludePlatform {
		keys = append(keys, DeviceFactKeyPlatform)
	}
	if p.cfg.IncludeLocation {
		keys = append(keys, DeviceFactKeyLocationCity, DeviceFactKeyLocationCoords)
	}
	return keys
}

// --- OutgoingUserTransformer ---

func (p *basicGrounding) TransformOutgoingUserMessage(content string, facts map[string]string) string {
	lines := p.factLines(facts)
	if len(lines) == 0 {
		return content
	}
	var b strings.Builder
	b.WriteString(groundingOpenTag)
	b.WriteByte('\n')
	for _, line := range lines {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	b.WriteString(groundingCloseTag)
	b.WriteString("\n\n")
	b.WriteString(content)
	return b.String()
}

// --- DisplayTransformer ---

// groundingBlockRe matches the plugin's wrapper, including any trailing
// whitespace, anchored at the start of the message (the only place the
// outgoing transformer ever writes it). Compiled once at package load —
// the pattern is closed-class.
var groundingBlockRe = regexp.MustCompile(
	`^` + regexp.QuoteMeta(groundingOpenTag) +
		`[\s\S]*?` + regexp.QuoteMeta(groundingCloseTag) +
		`[ \t]*\n*`,
)

func (p *basicGrounding) TransformForDisplay(content string) string {
	return groundingBlockRe.ReplaceAllString(content, "")
}

// --- Internal ---

// factLines returns one rendered "Key: value" line per enabled fact, in
// stable order. `facts` is the device-supplied envelope from the
// SendMessage request (may be nil); per-fact rendering tolerates
// missing keys and just skips the corresponding line. Empty slice
// when every enabled fact has nothing to render — caller skips the
// wrapping block entirely.
func (p *basicGrounding) factLines(facts map[string]string) []string {
	var lines []string
	if p.cfg.IncludeDateTime {
		lines = append(lines, "Current time: "+p.formatNow())
	}
	if p.cfg.IncludeLocale {
		if v := facts[DeviceFactKeyLocale]; v != "" {
			lines = append(lines, "Locale: "+v)
		}
	}
	if p.cfg.IncludePlatform {
		if v := facts[DeviceFactKeyPlatform]; v != "" {
			lines = append(lines, "Platform: "+v)
		}
	}
	if p.cfg.IncludeLocation {
		city := facts[DeviceFactKeyLocationCity]
		coords := facts[DeviceFactKeyLocationCoords]
		switch {
		case city != "" && coords != "":
			// Pair city + coords on one line — the city anchors
			// the human-readable answer, the coords give the
			// model precise enough geography to disambiguate
			// neighborhoods or do distance math.
			lines = append(lines, "Location: "+city+" ("+coords+")")
		case city != "":
			lines = append(lines, "Location: "+city)
		case coords != "":
			lines = append(lines, "Location (coords): "+coords)
		}
	}
	return lines
}

func (p *basicGrounding) formatNow() string {
	t := p.now()
	if p.cfg.Timezone != "" {
		if loc, err := time.LoadLocation(p.cfg.Timezone); err == nil {
			t = t.In(loc)
		}
	}
	switch p.cfg.TimeFormat {
	case "date_only":
		return t.Format("2006-01-02")
	case "datetime_human":
		// Mac-style human format with weekday + zone abbreviation.
		return t.Format("Monday, January 2, 2006 · 3:04 PM MST")
	default: // datetime_iso
		return t.Format(time.RFC3339)
	}
}
