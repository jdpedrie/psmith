package modelmeta

import (
	"testing"
	"time"
)

func TestParseSnapshot_BasicShape(t *testing.T) {
	payload := []byte(`{
        "anthropic": {
            "id": "anthropic",
            "name": "Anthropic",
            "api": "https://api.anthropic.com/v1",
            "env": ["ANTHROPIC_API_KEY"],
            "doc": "https://docs.anthropic.com",
            "models": {
                "claude-opus-4-5": {
                    "id": "claude-opus-4-5",
                    "name": "Claude Opus 4.5",
                    "limit": {"context": 200000, "output": 8192},
                    "cost": {"input": 15, "output": 75, "cache_read": 1.5, "cache_write": 18.75},
                    "modalities": {"input": ["text", "image"], "output": ["text"]},
                    "knowledge": "2024-10",
                    "reasoning": true,
                    "tool_call": true
                }
            }
        }
    }`)

	fetched := time.Date(2026, 4, 25, 12, 0, 0, 0, time.UTC)
	snap, err := ParseSnapshot(payload, fetched)
	if err != nil {
		t.Fatalf("ParseSnapshot: %v", err)
	}
	if got := len(snap.Providers); got != 1 {
		t.Fatalf("got %d providers, want 1", got)
	}

	p := snap.Providers[0]
	if p.Provider.ID != "anthropic" || p.Provider.Name != "Anthropic" {
		t.Errorf("provider mismatch: %+v", p.Provider)
	}
	if p.Provider.APIBase != "https://api.anthropic.com/v1" {
		t.Errorf("api_base: %q", p.Provider.APIBase)
	}
	if p.Provider.EnvKey != "ANTHROPIC_API_KEY" {
		t.Errorf("env_key: %q", p.Provider.EnvKey)
	}
	if p.Provider.DocURL != "https://docs.anthropic.com" {
		t.Errorf("doc_url: %q", p.Provider.DocURL)
	}
	if !p.Provider.FetchedAt.Equal(fetched) {
		t.Errorf("fetched_at mismatch")
	}
	if len(p.RawJSON) == 0 {
		t.Error("expected RawJSON to be populated")
	}

	if got := len(p.Models); got != 1 {
		t.Fatalf("got %d models, want 1", got)
	}
	m := p.Models[0].Model
	if m.ID != "claude-opus-4-5" || m.DisplayName != "Claude Opus 4.5" {
		t.Errorf("model mismatch: %+v", m)
	}
	if m.ContextWindow != 200000 || m.MaxOutputTokens != 8192 {
		t.Errorf("limits: ctx=%d out=%d", m.ContextWindow, m.MaxOutputTokens)
	}
	if m.Pricing == nil ||
		m.Pricing.InputPerMillion != 15 ||
		m.Pricing.OutputPerMillion != 75 ||
		m.Pricing.CacheReadPerMillion != 1.5 ||
		m.Pricing.CacheWritePerMillion != 18.75 {
		t.Errorf("pricing mismatch: %+v", m.Pricing)
	}
	if !m.Capabilities.Thinking || !m.Capabilities.ToolUse {
		t.Errorf("expected thinking + tool_use, got %+v", m.Capabilities)
	}
	if !m.Capabilities.Vision {
		t.Error("expected vision (image in input modalities)")
	}
	if !m.Capabilities.PromptCaching {
		t.Error("expected prompt caching (cache pricing present)")
	}
	if got := m.Modalities; len(got) != 2 || got[0] != "text" || got[1] != "image" {
		t.Errorf("modalities mismatch: %v", got)
	}
	if m.KnowledgeCutoff == nil || m.KnowledgeCutoff.Year() != 2024 || int(m.KnowledgeCutoff.Month()) != 10 {
		t.Errorf("knowledge_cutoff: %+v", m.KnowledgeCutoff)
	}
}

func TestParseSnapshot_EmptyAndUnknownFields(t *testing.T) {
	payload := []byte(`{
        "weird": {"id": "weird", "name": "Weird", "models": {}}
    }`)
	snap, err := ParseSnapshot(payload, time.Now())
	if err != nil {
		t.Fatalf("ParseSnapshot: %v", err)
	}
	if len(snap.Providers) != 1 {
		t.Fatalf("got %d providers, want 1", len(snap.Providers))
	}
	if got := len(snap.Providers[0].Models); got != 0 {
		t.Errorf("expected zero models, got %d", got)
	}
}

func TestParseSnapshot_InvalidJSON(t *testing.T) {
	if _, err := ParseSnapshot([]byte("not json"), time.Now()); err == nil {
		t.Error("expected parse error")
	}
}

func TestParseSnapshot_MissingPricingMeansNilPricing(t *testing.T) {
	payload := []byte(`{
        "p": {"id": "p", "name": "P", "models": {
            "m": {"id": "m", "name": "M"}
        }}
    }`)
	snap, _ := ParseSnapshot(payload, time.Now())
	m := snap.Providers[0].Models[0].Model
	if m.Pricing != nil {
		t.Errorf("expected nil pricing, got %+v", m.Pricing)
	}
	if m.Capabilities.PromptCaching {
		t.Error("prompt caching should be false without cache pricing")
	}
}

func TestParseLooseDate(t *testing.T) {
	cases := []struct {
		in       string
		wantYear int
	}{
		{"2024-10-15", 2024},
		{"2024-10", 2024},
		{"2024", 2024},
	}
	for _, tc := range cases {
		got, err := parseLooseDate(tc.in)
		if err != nil {
			t.Errorf("parseLooseDate(%q): %v", tc.in, err)
			continue
		}
		if got.Year() != tc.wantYear {
			t.Errorf("parseLooseDate(%q): year %d want %d", tc.in, got.Year(), tc.wantYear)
		}
	}
	if _, err := parseLooseDate("not-a-date"); err == nil {
		t.Error("expected error on unparseable date")
	}
}

func TestFirstNonEmpty(t *testing.T) {
	if got := firstNonEmpty(nil); got != "" {
		t.Errorf("nil → %q", got)
	}
	if got := firstNonEmpty([]string{"", "", "x"}); got != "x" {
		t.Errorf("[, , x] → %q", got)
	}
	if got := firstNonEmpty([]string{"first", "second"}); got != "first" {
		t.Errorf("[first, second] → %q", got)
	}
}

func TestCollectModalitiesAndHasModality(t *testing.T) {
	m := &modelsDevModalities{Input: []string{"text", "image"}, Output: []string{"text"}}
	got := collectModalities(m)
	if len(got) != 2 || got[0] != "text" || got[1] != "image" {
		t.Errorf("collectModalities: %v", got)
	}
	if !hasModality(m, "input", "image") {
		t.Error("expected input image")
	}
	if hasModality(m, "input", "audio") {
		t.Error("did not expect input audio")
	}
	if hasModality(nil, "input", "anything") {
		t.Error("nil modalities should never match")
	}
}
