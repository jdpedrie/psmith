package protoconv

import (
	"testing"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/providers"
)

func TestCallSettings_NilReturnsZero(t *testing.T) {
	t.Parallel()
	out := CallSettings(nil)
	// providers.CallSettings contains a slice, so a == comparison
	// to the zero value won't compile. Hand-check each load-bearing
	// field instead.
	if out.Temperature != nil || out.TopP != nil ||
		out.MaxOutputTokens != nil || out.TopK != nil ||
		len(out.StopSequences) != 0 ||
		out.Thinking != nil || out.Anthropic != nil ||
		out.OpenAI != nil || out.Google != nil ||
		out.ExplicitCache != nil {
		t.Errorf("nil input should yield zero-value CallSettings; got %+v", out)
	}
}

func TestCallSettings_TopLevelFieldsRoundTrip(t *testing.T) {
	t.Parallel()
	temp := 0.4
	topP := 0.95
	maxTok := int32(2048)
	topK := int32(40)
	enabled := true
	cache := true
	out := CallSettings(&spaltv1.CallSettings{
		Temperature:     &temp,
		TopP:            &topP,
		MaxOutputTokens: &maxTok,
		TopK:            &topK,
		StopSequences:   []string{"END", "STOP"},
		Thinking: &spaltv1.ThinkingSettings{
			Enabled: &enabled,
		},
		ExplicitCache: &cache,
	})
	if out.Temperature == nil || *out.Temperature != 0.4 {
		t.Errorf("Temperature=%v", out.Temperature)
	}
	if out.MaxOutputTokens == nil || *out.MaxOutputTokens != 2048 {
		t.Errorf("MaxOutputTokens=%v", out.MaxOutputTokens)
	}
	if out.TopK == nil || *out.TopK != 40 {
		t.Errorf("TopK=%v", out.TopK)
	}
	if len(out.StopSequences) != 2 || out.StopSequences[0] != "END" {
		t.Errorf("StopSequences=%v", out.StopSequences)
	}
	if out.Thinking == nil || out.Thinking.Enabled == nil || !*out.Thinking.Enabled {
		t.Errorf("Thinking.Enabled=%v", out.Thinking)
	}
	if out.ExplicitCache == nil {
		t.Error("ExplicitCache lost")
	}
}

func TestCallSettings_ThinkingBudgetTokensConverted(t *testing.T) {
	t.Parallel()
	budget := int32(8000)
	out := CallSettings(&spaltv1.CallSettings{
		Thinking: &spaltv1.ThinkingSettings{BudgetTokens: &budget},
	})
	if out.Thinking == nil || out.Thinking.BudgetTokens == nil || *out.Thinking.BudgetTokens != 8000 {
		t.Errorf("BudgetTokens=%v", out.Thinking)
	}
}

func TestCallSettings_AnthropicExtras(t *testing.T) {
	t.Parallel()
	on := true
	ttl5 := spaltv1.CacheTTL_CACHE_TTL_5M
	out := CallSettings(&spaltv1.CallSettings{
		Anthropic: &spaltv1.AnthropicExtras{
			CacheEnabled: &on,
			CacheTtl:     &ttl5,
		},
	})
	if out.Anthropic == nil {
		t.Fatal("Anthropic lost")
	}
	if out.Anthropic.CacheEnabled == nil || !*out.Anthropic.CacheEnabled {
		t.Errorf("CacheEnabled=%v", out.Anthropic.CacheEnabled)
	}
	if out.Anthropic.CacheTTL != providers.CacheTTL5m {
		t.Errorf("CacheTTL=%v", out.Anthropic.CacheTTL)
	}
}

func TestCallSettings_OpenAIExtras(t *testing.T) {
	t.Parallel()
	seed := int32(42)
	tlp := int32(5)
	tier := spaltv1.ServiceTier_SERVICE_TIER_PRIORITY
	freq, pres := 0.5, -0.2
	parallel := false
	out := CallSettings(&spaltv1.CallSettings{
		Openai: &spaltv1.OpenAIExtras{
			Seed:              &seed,
			TopLogprobs:       &tlp,
			ServiceTier:       &tier,
			FrequencyPenalty:  &freq,
			PresencePenalty:   &pres,
			ParallelToolCalls: &parallel,
			LogitBias:         map[int32]float64{50256: -100, 198: -2.5},
		},
	})
	if out.OpenAI == nil {
		t.Fatal("OpenAI lost")
	}
	if out.OpenAI.Seed == nil || *out.OpenAI.Seed != 42 {
		t.Errorf("Seed=%v", out.OpenAI.Seed)
	}
	if out.OpenAI.TopLogprobs == nil || *out.OpenAI.TopLogprobs != 5 {
		t.Errorf("TopLogprobs=%v", out.OpenAI.TopLogprobs)
	}
	if out.OpenAI.ServiceTier == nil || *out.OpenAI.ServiceTier != providers.ServiceTierPriority {
		t.Errorf("ServiceTier=%v", out.OpenAI.ServiceTier)
	}
	if out.OpenAI.FrequencyPenalty == nil || *out.OpenAI.FrequencyPenalty != 0.5 {
		t.Errorf("FrequencyPenalty=%v", out.OpenAI.FrequencyPenalty)
	}
	if out.OpenAI.ParallelToolCalls == nil || *out.OpenAI.ParallelToolCalls {
		t.Errorf("ParallelToolCalls=%v", out.OpenAI.ParallelToolCalls)
	}
	if v, ok := out.OpenAI.LogitBias[50256]; !ok || v != -100 {
		t.Errorf("LogitBias[50256]=%v", v)
	}
}

func TestCallSettings_GoogleExtras(t *testing.T) {
	t.Parallel()
	count := int32(4)
	mime := "application/json"
	thr := spaltv1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH
	out := CallSettings(&spaltv1.CallSettings{
		Google: &spaltv1.GoogleExtras{
			ResponseMimeType: &mime,
			CandidateCount:   &count,
			ResponseSchema:   []byte(`{"type":"object"}`),
			SafetySettings: &spaltv1.SafetySettings{
				DangerousContent: &thr,
			},
		},
	})
	if out.Google == nil {
		t.Fatal("Google lost")
	}
	if out.Google.ResponseMimeType == nil || *out.Google.ResponseMimeType != "application/json" {
		t.Errorf("ResponseMimeType=%v", out.Google.ResponseMimeType)
	}
	if out.Google.CandidateCount == nil || *out.Google.CandidateCount != 4 {
		t.Errorf("CandidateCount=%v", out.Google.CandidateCount)
	}
	if string(out.Google.ResponseSchema) != `{"type":"object"}` {
		t.Errorf("ResponseSchema=%s", out.Google.ResponseSchema)
	}
	if out.Google.SafetySettings == nil ||
		out.Google.SafetySettings.DangerousContent == nil ||
		*out.Google.SafetySettings.DangerousContent != providers.HarmThresholdBlockOnlyHigh {
		t.Errorf("SafetySettings.DangerousContent=%v", out.Google.SafetySettings)
	}
	// Unset thresholds stay nil — confirms HarmThreshold(nil) → nil.
	if out.Google.SafetySettings.Harassment != nil {
		t.Errorf("Harassment should be nil; got %v", out.Google.SafetySettings.Harassment)
	}
}

func TestCacheTTL_AllVariants(t *testing.T) {
	t.Parallel()
	cases := []struct {
		in   *spaltv1.CacheTTL
		want providers.CacheTTL
	}{
		{nil, providers.CacheTTLUnspecified},
		{ptr(spaltv1.CacheTTL_CACHE_TTL_5M), providers.CacheTTL5m},
		{ptr(spaltv1.CacheTTL_CACHE_TTL_1H), providers.CacheTTL1h},
		{ptr(spaltv1.CacheTTL_CACHE_TTL_UNSPECIFIED), providers.CacheTTLUnspecified},
	}
	for _, c := range cases {
		if got := CacheTTL(c.in); got != c.want {
			t.Errorf("CacheTTL(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestServiceTier_AllVariants(t *testing.T) {
	t.Parallel()
	cases := []struct {
		in   spaltv1.ServiceTier
		want providers.ServiceTier
	}{
		{spaltv1.ServiceTier_SERVICE_TIER_AUTO, providers.ServiceTierAuto},
		{spaltv1.ServiceTier_SERVICE_TIER_STANDARD, providers.ServiceTierStandard},
		{spaltv1.ServiceTier_SERVICE_TIER_PRIORITY, providers.ServiceTierPriority},
		{spaltv1.ServiceTier_SERVICE_TIER_UNSPECIFIED, providers.ServiceTierUnspecified},
	}
	for _, c := range cases {
		if got := ServiceTier(c.in); got != c.want {
			t.Errorf("ServiceTier(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestResponseFormat_Variants(t *testing.T) {
	t.Parallel()

	if got := ResponseFormat(nil); got != nil {
		t.Errorf("nil input → nil; got %v", got)
	}

	// Text variant.
	got := ResponseFormat(&spaltv1.ResponseFormat{
		Kind: &spaltv1.ResponseFormat_Text{Text: true},
	})
	if got == nil || got.Text == nil || !*got.Text {
		t.Errorf("Text variant lost: %+v", got)
	}

	// JsonObject variant.
	got = ResponseFormat(&spaltv1.ResponseFormat{
		Kind: &spaltv1.ResponseFormat_JsonObject{JsonObject: true},
	})
	if got == nil || got.JSONObject == nil || !*got.JSONObject {
		t.Errorf("JsonObject variant lost: %+v", got)
	}

	// JsonSchema variant — full payload including raw schema bytes
	// + strict flag (the most error-prone path; structured-output
	// shape regressions show up here first).
	strict := true
	desc := "user profile"
	got = ResponseFormat(&spaltv1.ResponseFormat{
		Kind: &spaltv1.ResponseFormat_JsonSchema{
			JsonSchema: &spaltv1.JsonSchema{
				Name:        "Profile",
				Description: &desc,
				Strict:      &strict,
				Schema:      []byte(`{"type":"object"}`),
			},
		},
	})
	if got == nil || got.JSONSchema == nil {
		t.Fatalf("JsonSchema variant lost: %+v", got)
	}
	if got.JSONSchema.Name != "Profile" {
		t.Errorf("Name=%q", got.JSONSchema.Name)
	}
	if got.JSONSchema.Description == nil || *got.JSONSchema.Description != "user profile" {
		t.Errorf("Description=%v", got.JSONSchema.Description)
	}
	if got.JSONSchema.Strict == nil || !*got.JSONSchema.Strict {
		t.Errorf("Strict=%v", got.JSONSchema.Strict)
	}
	if string(got.JSONSchema.Schema) != `{"type":"object"}` {
		t.Errorf("Schema=%s", got.JSONSchema.Schema)
	}
}

func TestHarmThreshold_AllVariants(t *testing.T) {
	t.Parallel()
	if got := HarmThreshold(nil); got != nil {
		t.Errorf("nil → nil; got %v", got)
	}
	cases := []struct {
		in   spaltv1.HarmThreshold
		want providers.HarmThreshold
	}{
		{spaltv1.HarmThreshold_HARM_THRESHOLD_BLOCK_NONE, providers.HarmThresholdBlockNone},
		{spaltv1.HarmThreshold_HARM_THRESHOLD_BLOCK_LOW_AND_ABOVE, providers.HarmThresholdBlockLowAndAbove},
		{spaltv1.HarmThreshold_HARM_THRESHOLD_BLOCK_MEDIUM_AND_ABOVE, providers.HarmThresholdBlockMediumAndAbove},
		{spaltv1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH, providers.HarmThresholdBlockOnlyHigh},
		{spaltv1.HarmThreshold_HARM_THRESHOLD_UNSPECIFIED, providers.HarmThresholdUnspecified},
	}
	for _, c := range cases {
		got := HarmThreshold(&c.in)
		if got == nil || *got != c.want {
			t.Errorf("HarmThreshold(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

// CallSettings should defensive-copy slice + map fields so a later
// mutation of the wire-side input doesn't bleed into the internal
// value (and vice versa).
func TestCallSettings_DefensiveCopiesProtectFromMutation(t *testing.T) {
	t.Parallel()
	stops := []string{"A", "B"}
	out := CallSettings(&spaltv1.CallSettings{
		StopSequences: stops,
		Google: &spaltv1.GoogleExtras{
			ResponseSchema: []byte("orig"),
		},
	})
	// Mutate originals.
	stops[0] = "MUTATED"
	// Internal value should still see the original "A".
	if out.StopSequences[0] != "A" {
		t.Errorf("StopSequences shared backing array; got %v", out.StopSequences)
	}
	// ResponseSchema clone.
	if out.Google == nil || string(out.Google.ResponseSchema) != "orig" {
		t.Errorf("ResponseSchema=%s", out.Google.ResponseSchema)
	}
}

func ptr[T any](v T) *T { return &v }
