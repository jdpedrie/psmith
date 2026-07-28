package modelmeta

import "testing"

func TestConstraintsFor_ExactMatchWinsOverDefault(t *testing.T) {
	c := ConstraintsFor("google", "gemini-3.1-pro-preview")
	if c.Temperature == nil || c.Temperature.Max == nil || *c.Temperature.Max != 1.5 {
		t.Fatalf("expected temperature.max=1.5 for gemini-3.1-pro-preview, got %+v", c.Temperature)
	}
}

func TestConstraintsFor_PrefixMatch(t *testing.T) {
	for _, mid := range []string{"gpt-5", "gpt-5-mini", "gpt-5-pro"} {
		c := ConstraintsFor("openai-compatible", mid)
		if c.Temperature == nil || c.Temperature.LockedAt == nil || *c.Temperature.LockedAt != 1.0 {
			t.Errorf("expected temperature.locked_at=1.0 for %s, got %+v", mid, c.Temperature)
		}
	}
}

func TestConstraintsFor_ProviderTypeDefault(t *testing.T) {
	c := ConstraintsFor("anthropic", "claude-haiku-4-5-20251001")
	if c.Temperature == nil || c.Temperature.Max == nil || *c.Temperature.Max != 1.0 {
		t.Fatalf("expected anthropic temperature.max=1.0, got %+v", c.Temperature)
	}
}

func TestConstraintsFor_UnknownProviderEmpty(t *testing.T) {
	c := ConstraintsFor("nonexistent", "whatever")
	if c.Temperature != nil || len(c.Unsupported) != 0 {
		t.Errorf("expected zero-value constraints for unknown provider, got %+v", c)
	}
}

func TestConstraintsFor_KnownProviderUnknownModelHonorsDefault(t *testing.T) {
	// Anthropic provider type with a model id we don't have an exact
	// or prefix entry for — should still pick up the per-driver default.
	c := ConstraintsFor("anthropic", "claude-future-9000")
	if c.Temperature == nil || c.Temperature.Max == nil || *c.Temperature.Max != 1.0 {
		t.Fatalf("expected default to apply, got %+v", c.Temperature)
	}
}

func TestConstraintsFor_OtherOpenAIModelsUnconstrained(t *testing.T) {
	// gpt-4o is in the openai-compatible family but isn't reasoning-
	// locked — should fall through to no constraint.
	c := ConstraintsFor("openai-compatible", "gpt-4o")
	if c.Temperature != nil {
		t.Errorf("expected gpt-4o to have no temperature constraint, got %+v", c.Temperature)
	}
}

// The adaptive-thinking generation locks temperature at 1.0; older
// Anthropic models keep the documented [0, 1] range from the provider
// default tier.
func TestConstraintsFor_AnthropicTemperatureLock(t *testing.T) {
	for _, id := range []string{
		"claude-fable-5", "claude-opus-4-7", "claude-opus-4-8",
		"claude-sonnet-4-6", "claude-sonnet-5",
	} {
		c := ConstraintsFor("anthropic", id)
		if c.Temperature == nil || c.Temperature.LockedAt == nil || *c.Temperature.LockedAt != 1.0 {
			t.Errorf("%s: want temperature locked at 1.0, got %+v", id, c.Temperature)
		}
	}
	// Pre-adaptive model: ranged, not locked.
	c := ConstraintsFor("anthropic", "claude-haiku-4-5")
	if c.Temperature == nil || c.Temperature.LockedAt != nil {
		t.Errorf("haiku-4-5: want ranged temperature, got %+v", c.Temperature)
	}
	if c.Temperature != nil && (c.Temperature.Min == nil || c.Temperature.Max == nil || *c.Temperature.Max != 1.0) {
		t.Errorf("haiku-4-5: want [0,1] range, got %+v", c.Temperature)
	}
}

func TestEffectiveTier(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	tiers := []PricingTier{
		{ThresholdTokens: 128_000, InputPerMillion: f(6.0)},
		{ThresholdTokens: 256_000, InputPerMillion: f(12.0)},
	}
	if got := EffectiveTier(tiers, 100_000); got != nil {
		t.Errorf("100k: got tier %+v, want base (nil)", got)
	}
	if got := EffectiveTier(tiers, 128_000); got != nil {
		t.Errorf("exactly at threshold: got tier %+v, want base (nil, strict >)", got)
	}
	if got := EffectiveTier(tiers, 130_000); got == nil || *got.InputPerMillion != 6.0 {
		t.Errorf("130k: got %+v, want 128k tier", got)
	}
	if got := EffectiveTier(tiers, 300_000); got == nil || *got.InputPerMillion != 12.0 {
		t.Errorf("300k: got %+v, want 256k tier", got)
	}
	if got := EffectiveTier(nil, 300_000); got != nil {
		t.Errorf("no tiers: got %+v, want nil", got)
	}
}
