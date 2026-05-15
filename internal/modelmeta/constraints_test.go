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
