package profiles

import (
	"reflect"
	"testing"

	clarkv1 "github.com/jdpedrie/reeve/gen/clark/v1"
)

// --- helpers ---------------------------------------------------------------

func f64(v float64) *float64 { return &v }
func i32(v int32) *int32     { return &v }
func bp(v bool) *bool        { return &v }
func sp(v string) *string    { return &v }
func tier(v clarkv1.ServiceTier) *clarkv1.ServiceTier {
	return &v
}
func harm(v clarkv1.HarmThreshold) *clarkv1.HarmThreshold {
	return &v
}

// --- top-level merge -------------------------------------------------------

func TestMergeCallSettings_BothNil(t *testing.T) {
	if got := MergeCallSettings(nil, nil); got != nil {
		t.Fatalf("expected nil, got %+v", got)
	}
}

func TestMergeCallSettings_OnlyHigher(t *testing.T) {
	in := &clarkv1.CallSettings{Temperature: f64(0.5)}
	got := MergeCallSettings(in, nil)
	if got == nil || got.GetTemperature() != 0.5 {
		t.Fatalf("expected temp=0.5; got %+v", got)
	}
	// Defensive copy: mutating the result must not touch the input.
	*got.Temperature = 0.9
	if *in.Temperature != 0.5 {
		t.Errorf("MergeCallSettings should defensive-copy input; in.Temperature mutated to %v", *in.Temperature)
	}
}

func TestMergeCallSettings_OnlyLower(t *testing.T) {
	in := &clarkv1.CallSettings{TopP: f64(0.95)}
	got := MergeCallSettings(nil, in)
	if got == nil || got.GetTopP() != 0.95 {
		t.Fatalf("expected top_p=0.95; got %+v", got)
	}
}

func TestMergeCallSettings_HigherWinsPerField(t *testing.T) {
	higher := &clarkv1.CallSettings{
		Temperature: f64(0.7),
		// TopP unset → falls through.
		MaxOutputTokens: i32(1024),
		// TopK unset → falls through.
	}
	lower := &clarkv1.CallSettings{
		Temperature:     f64(0.2),  // overridden
		TopP:            f64(0.9),  // inherited
		MaxOutputTokens: i32(4096), // overridden
		TopK:            i32(40),   // inherited
	}
	got := MergeCallSettings(higher, lower)
	if got.GetTemperature() != 0.7 {
		t.Errorf("temperature: %v want 0.7", got.GetTemperature())
	}
	if got.GetTopP() != 0.9 {
		t.Errorf("top_p inherit: %v want 0.9", got.GetTopP())
	}
	if got.GetMaxOutputTokens() != 1024 {
		t.Errorf("max_output_tokens: %v want 1024", got.GetMaxOutputTokens())
	}
	if got.GetTopK() != 40 {
		t.Errorf("top_k inherit: %v want 40", got.GetTopK())
	}
}

func TestMergeCallSettings_StopSequencesWholeFieldOverride(t *testing.T) {
	higher := &clarkv1.CallSettings{StopSequences: []string{"X", "Y"}}
	lower := &clarkv1.CallSettings{StopSequences: []string{"A", "B", "C"}}

	// Higher set → wholly wins (no concatenation, no merge).
	got := MergeCallSettings(higher, lower)
	if !reflect.DeepEqual(got.StopSequences, []string{"X", "Y"}) {
		t.Errorf("higher set: got %v want [X Y]", got.StopSequences)
	}

	// Higher unset → lower passes through wholly.
	higher2 := &clarkv1.CallSettings{Temperature: f64(0.1)}
	got2 := MergeCallSettings(higher2, lower)
	if !reflect.DeepEqual(got2.StopSequences, []string{"A", "B", "C"}) {
		t.Errorf("higher unset: got %v want [A B C]", got2.StopSequences)
	}
}

func TestMergeCallSettings_PrecedenceMultipleLayers(t *testing.T) {
	// Three layers: top → middle → bottom. We compose nested merges to
	// simulate the assembleCallSettings call pattern.
	top := &clarkv1.CallSettings{Temperature: f64(0.7)} // wins on temp
	middle := &clarkv1.CallSettings{
		Temperature:     f64(0.4), // shadowed by top
		MaxOutputTokens: i32(2048), // wins
	}
	bottom := &clarkv1.CallSettings{
		Temperature:     f64(0.1), // shadowed
		MaxOutputTokens: i32(512), // shadowed
		TopP:            f64(0.95), // wins (only set here)
	}

	got := MergeCallSettings(top, MergeCallSettings(middle, bottom))
	if got.GetTemperature() != 0.7 {
		t.Errorf("temperature: %v want 0.7 (from top)", got.GetTemperature())
	}
	if got.GetMaxOutputTokens() != 2048 {
		t.Errorf("max_output_tokens: %v want 2048 (from middle)", got.GetMaxOutputTokens())
	}
	if got.GetTopP() != 0.95 {
		t.Errorf("top_p: %v want 0.95 (from bottom)", got.GetTopP())
	}
}

// --- ThinkingSettings ------------------------------------------------------

func TestMergeCallSettings_ThinkingPerFieldMerge(t *testing.T) {
	// higher sets only enabled; lower sets only budget. Merged: both.
	higher := &clarkv1.CallSettings{Thinking: &clarkv1.ThinkingSettings{Enabled: bp(true)}}
	lower := &clarkv1.CallSettings{Thinking: &clarkv1.ThinkingSettings{BudgetTokens: i32(4000)}}
	got := MergeCallSettings(higher, lower)
	if got.GetThinking() == nil {
		t.Fatal("thinking nil after merge")
	}
	if !got.GetThinking().GetEnabled() {
		t.Error("enabled should be true (from higher)")
	}
	if got.GetThinking().GetBudgetTokens() != 4000 {
		t.Errorf("budget: %v want 4000 (from lower)", got.GetThinking().GetBudgetTokens())
	}
}

func TestMergeCallSettings_ThinkingHigherOverridesLower(t *testing.T) {
	higher := &clarkv1.CallSettings{Thinking: &clarkv1.ThinkingSettings{
		Enabled:      bp(false),
		BudgetTokens: i32(1000),
	}}
	lower := &clarkv1.CallSettings{Thinking: &clarkv1.ThinkingSettings{
		Enabled:      bp(true),
		BudgetTokens: i32(8000),
	}}
	got := MergeCallSettings(higher, lower)
	if got.GetThinking().GetEnabled() {
		t.Error("expected higher's enabled=false")
	}
	if got.GetThinking().GetBudgetTokens() != 1000 {
		t.Errorf("budget: %v want 1000", got.GetThinking().GetBudgetTokens())
	}
}

// --- OpenAIExtras ----------------------------------------------------------

func TestMergeCallSettings_OpenAIPerFieldMerge(t *testing.T) {
	// higher sets seed only; lower sets frequency_penalty and parallel_tool_calls.
	higher := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{Seed: i32(42)}}
	lower := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{
		FrequencyPenalty:  f64(0.5),
		ParallelToolCalls: bp(true),
	}}
	got := MergeCallSettings(higher, lower)
	oe := got.GetOpenai()
	if oe == nil {
		t.Fatal("openai nil after merge")
	}
	if oe.GetSeed() != 42 {
		t.Errorf("seed: %v want 42", oe.GetSeed())
	}
	if oe.GetFrequencyPenalty() != 0.5 {
		t.Errorf("frequency_penalty: %v want 0.5 (from lower)", oe.GetFrequencyPenalty())
	}
	if !oe.GetParallelToolCalls() {
		t.Errorf("parallel_tool_calls: %v want true (from lower)", oe.GetParallelToolCalls())
	}
}

func TestMergeCallSettings_OpenAIServiceTierEnumPickWins(t *testing.T) {
	higher := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{ServiceTier: tier(clarkv1.ServiceTier_SERVICE_TIER_PRIORITY)}}
	lower := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{ServiceTier: tier(clarkv1.ServiceTier_SERVICE_TIER_AUTO)}}
	got := MergeCallSettings(higher, lower)
	if got.GetOpenai().GetServiceTier() != clarkv1.ServiceTier_SERVICE_TIER_PRIORITY {
		t.Errorf("service_tier: %v want PRIORITY (higher wins)", got.GetOpenai().GetServiceTier())
	}

	higher2 := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{Seed: i32(1)}}
	got2 := MergeCallSettings(higher2, lower)
	if got2.GetOpenai().GetServiceTier() != clarkv1.ServiceTier_SERVICE_TIER_AUTO {
		t.Errorf("service_tier inherit: %v want AUTO", got2.GetOpenai().GetServiceTier())
	}
}

func TestMergeCallSettings_OpenAILogitBiasWholeFieldOverride(t *testing.T) {
	higher := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{LogitBias: map[int32]float64{100: 1.5}}}
	lower := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{LogitBias: map[int32]float64{200: -2.0, 300: 0.5}}}

	got := MergeCallSettings(higher, lower)
	if !reflect.DeepEqual(got.GetOpenai().GetLogitBias(), map[int32]float64{100: 1.5}) {
		t.Errorf("higher set: got %v want {100:1.5}", got.GetOpenai().GetLogitBias())
	}

	higher2 := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{Seed: i32(1)}}
	got2 := MergeCallSettings(higher2, lower)
	if !reflect.DeepEqual(got2.GetOpenai().GetLogitBias(), map[int32]float64{200: -2.0, 300: 0.5}) {
		t.Errorf("higher unset: got %v want lower's map", got2.GetOpenai().GetLogitBias())
	}
}

func TestMergeCallSettings_OpenAIResponseFormatWholeFieldOverride(t *testing.T) {
	higher := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{
		ResponseFormat: &clarkv1.ResponseFormat{
			Kind: &clarkv1.ResponseFormat_JsonObject{JsonObject: true},
		},
	}}
	lower := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{
		ResponseFormat: &clarkv1.ResponseFormat{
			Kind: &clarkv1.ResponseFormat_JsonSchema{JsonSchema: &clarkv1.JsonSchema{
				Name: "answer", Schema: []byte(`{}`),
			}},
		},
	}}
	got := MergeCallSettings(higher, lower)
	if _, ok := got.GetOpenai().ResponseFormat.GetKind().(*clarkv1.ResponseFormat_JsonObject); !ok {
		t.Errorf("response_format: %T want JsonObject", got.GetOpenai().ResponseFormat.GetKind())
	}

	higher2 := &clarkv1.CallSettings{Openai: &clarkv1.OpenAIExtras{Seed: i32(1)}}
	got2 := MergeCallSettings(higher2, lower)
	js, ok := got2.GetOpenai().ResponseFormat.GetKind().(*clarkv1.ResponseFormat_JsonSchema)
	if !ok {
		t.Fatalf("inherited response_format: %T want JsonSchema", got2.GetOpenai().ResponseFormat.GetKind())
	}
	if js.JsonSchema.GetName() != "answer" {
		t.Errorf("inherited schema name: %q", js.JsonSchema.GetName())
	}
}

// --- GoogleExtras ----------------------------------------------------------

func TestMergeCallSettings_GooglePerFieldMerge(t *testing.T) {
	higher := &clarkv1.CallSettings{Google: &clarkv1.GoogleExtras{
		ResponseMimeType: sp("application/json"),
	}}
	lower := &clarkv1.CallSettings{Google: &clarkv1.GoogleExtras{
		CandidateCount: i32(2),
		ResponseSchema: []byte(`{"type":"object"}`),
	}}
	got := MergeCallSettings(higher, lower)
	g := got.GetGoogle()
	if g.GetResponseMimeType() != "application/json" {
		t.Errorf("mime: %q (from higher)", g.GetResponseMimeType())
	}
	if g.GetCandidateCount() != 2 {
		t.Errorf("candidate_count: %v want 2 (from lower)", g.GetCandidateCount())
	}
	if string(g.GetResponseSchema()) != `{"type":"object"}` {
		t.Errorf("response_schema: %q", g.GetResponseSchema())
	}
}

func TestMergeCallSettings_SafetySettingsPerFieldMerge(t *testing.T) {
	higher := &clarkv1.CallSettings{Google: &clarkv1.GoogleExtras{
		SafetySettings: &clarkv1.SafetySettings{
			Harassment: harm(clarkv1.HarmThreshold_HARM_THRESHOLD_BLOCK_NONE),
		},
	}}
	lower := &clarkv1.CallSettings{Google: &clarkv1.GoogleExtras{
		SafetySettings: &clarkv1.SafetySettings{
			Harassment:       harm(clarkv1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH),
			DangerousContent: harm(clarkv1.HarmThreshold_HARM_THRESHOLD_BLOCK_LOW_AND_ABOVE),
		},
	}}
	got := MergeCallSettings(higher, lower)
	ss := got.GetGoogle().GetSafetySettings()
	if ss.GetHarassment() != clarkv1.HarmThreshold_HARM_THRESHOLD_BLOCK_NONE {
		t.Errorf("harassment: %v want BLOCK_NONE (higher wins)", ss.GetHarassment())
	}
	if ss.GetDangerousContent() != clarkv1.HarmThreshold_HARM_THRESHOLD_BLOCK_LOW_AND_ABOVE {
		t.Errorf("dangerous_content: %v want LOW_AND_ABOVE (from lower)", ss.GetDangerousContent())
	}
}

// --- AnthropicExtras --------------------------------------------------------

func TestMergeCallSettings_AnthropicExtrasPresenceOnly(t *testing.T) {
	higher := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{}}
	got := MergeCallSettings(higher, nil)
	if got.GetAnthropic() == nil {
		t.Error("expected anthropic block to survive merge")
	}
	got2 := MergeCallSettings(nil, &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{}})
	if got2.GetAnthropic() == nil {
		t.Error("expected anthropic block to survive merge from lower")
	}
}

func ttl(v clarkv1.CacheTTL) *clarkv1.CacheTTL { return &v }

func TestMergeCallSettings_AnthropicCacheEnabled_HigherWins(t *testing.T) {
	higher := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheEnabled: bp(false)}}
	lower := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheEnabled: bp(true)}}
	got := MergeCallSettings(higher, lower).GetAnthropic()
	if got == nil || got.CacheEnabled == nil || *got.CacheEnabled != false {
		t.Errorf("expected cache_enabled=false from higher, got %+v", got)
	}
}

func TestMergeCallSettings_AnthropicCacheEnabled_FillsFromLower(t *testing.T) {
	higher := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{}}
	lower := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheEnabled: bp(false)}}
	got := MergeCallSettings(higher, lower).GetAnthropic()
	if got == nil || got.CacheEnabled == nil || *got.CacheEnabled != false {
		t.Errorf("expected cache_enabled=false (inherited from lower), got %+v", got)
	}
}

func TestMergeCallSettings_AnthropicCacheTTL_HigherWins(t *testing.T) {
	higher := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheTtl: ttl(clarkv1.CacheTTL_CACHE_TTL_1H)}}
	lower := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheTtl: ttl(clarkv1.CacheTTL_CACHE_TTL_5M)}}
	got := MergeCallSettings(higher, lower).GetAnthropic()
	if got == nil || got.CacheTtl == nil || *got.CacheTtl != clarkv1.CacheTTL_CACHE_TTL_1H {
		t.Errorf("expected ttl=1h from higher, got %+v", got)
	}
}

func TestMergeCallSettings_AnthropicCacheTTL_FillsFromLower(t *testing.T) {
	higher := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheEnabled: bp(true)}}
	lower := &clarkv1.CallSettings{Anthropic: &clarkv1.AnthropicExtras{CacheTtl: ttl(clarkv1.CacheTTL_CACHE_TTL_1H)}}
	got := MergeCallSettings(higher, lower).GetAnthropic()
	if got == nil {
		t.Fatalf("expected anthropic non-nil")
	}
	if got.CacheEnabled == nil || *got.CacheEnabled != true {
		t.Errorf("expected cache_enabled=true (from higher), got %+v", got.CacheEnabled)
	}
	if got.CacheTtl == nil || *got.CacheTtl != clarkv1.CacheTTL_CACHE_TTL_1H {
		t.Errorf("expected ttl=1h (inherited from lower), got %+v", got.CacheTtl)
	}
}

// --- Marshal/Unmarshal round trip -----------------------------------------

func TestCallSettingsCodec_RoundTrip(t *testing.T) {
	in := &clarkv1.CallSettings{
		Temperature:     f64(0.42),
		TopP:            f64(0.9),
		MaxOutputTokens: i32(2048),
		StopSequences:   []string{"END", "STOP"},
		TopK:            i32(50),
		Thinking: &clarkv1.ThinkingSettings{
			Enabled:      bp(true),
			BudgetTokens: i32(4096),
		},
		Openai: &clarkv1.OpenAIExtras{
			Seed:        i32(7),
			ServiceTier: tier(clarkv1.ServiceTier_SERVICE_TIER_PRIORITY),
			LogitBias:   map[int32]float64{42: 0.5},
		},
	}
	raw, err := MarshalCallSettings(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out, err := UnmarshalCallSettings(raw)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.GetTemperature() != 0.42 || out.GetTopP() != 0.9 {
		t.Errorf("scalars lost: %+v", out)
	}
	if !reflect.DeepEqual(out.StopSequences, []string{"END", "STOP"}) {
		t.Errorf("stop_sequences: %v", out.StopSequences)
	}
	if out.GetThinking().GetBudgetTokens() != 4096 {
		t.Errorf("thinking budget: %v", out.GetThinking().GetBudgetTokens())
	}
	if out.GetOpenai().GetSeed() != 7 || out.GetOpenai().GetServiceTier() != clarkv1.ServiceTier_SERVICE_TIER_PRIORITY {
		t.Errorf("openai: %+v", out.GetOpenai())
	}
	if got := out.GetOpenai().GetLogitBias()[42]; got != 0.5 {
		t.Errorf("logit_bias[42]: %v want 0.5", got)
	}
}

func TestCallSettingsCodec_NilAndEmpty(t *testing.T) {
	b, err := MarshalCallSettings(nil)
	if err != nil {
		t.Fatalf("marshal nil: %v", err)
	}
	if b != nil {
		t.Errorf("marshal nil should return nil bytes, got %q", b)
	}
	cs, err := UnmarshalCallSettings(nil)
	if err != nil {
		t.Fatalf("unmarshal nil: %v", err)
	}
	if cs != nil {
		t.Errorf("unmarshal nil should return nil cs, got %+v", cs)
	}
}
