package web

import (
	"net/url"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// Every CallSettings field survives the defaults form: proto to form values,
// back through the parser, to the same proto.
func TestCallSettingsFormRoundTrip(t *testing.T) {
	t.Parallel()
	f := func(v float64) *float64 { return &v }
	i := func(v int32) *int32 { return &v }
	b := func(v bool) *bool { return &v }
	ttl := psmithv1.CacheTTL_CACHE_TTL_1H
	tier := psmithv1.ServiceTier_SERVICE_TIER_PRIORITY
	harm := psmithv1.HarmThreshold_HARM_THRESHOLD_BLOCK_ONLY_HIGH
	mime := "application/json"
	desc := "d"
	in := &psmithv1.CallSettings{
		Temperature: f(0.7), TopP: f(0.9), MaxOutputTokens: i(16384), TopK: i(40), StopSequences: []string{"</a>", "END"},
		Thinking:      &psmithv1.ThinkingSettings{Effort: psmithv1.ThinkingEffort_THINKING_EFFORT_XHIGH},
		ExplicitCache: b(true),
		Anthropic:     &psmithv1.AnthropicExtras{CacheEnabled: b(false), CacheTtl: &ttl},
		Openai: &psmithv1.OpenAIExtras{Seed: i(-5), FrequencyPenalty: f(-1.5), PresencePenalty: f(2), TopLogprobs: i(3), ParallelToolCalls: b(false), ServiceTier: &tier,
			ResponseFormat: &psmithv1.ResponseFormat{Kind: &psmithv1.ResponseFormat_JsonSchema{JsonSchema: &psmithv1.JsonSchema{Name: "n", Description: &desc, Schema: []byte(`{"type":"object"}`), Strict: b(true)}}},
			LogitBias:      map[int32]float64{50256: -100}},
		Google: &psmithv1.GoogleExtras{SafetySettings: &psmithv1.SafetySettings{Harassment: &harm, DangerousContent: &harm}, ResponseMimeType: &mime, ResponseSchema: []byte(`{}`), CandidateCount: i(2)},
	}
	form := csFromProto(in)
	v := url.Values{
		"temperature": {form.Temp}, "top_p": {form.TopP}, "max_output_tokens": {form.MaxTok}, "top_k": {form.TopK}, "stop": form.Stops,
		"effort": {form.Effort}, "explicit_cache": {form.Explicit}, "cache_enabled": {form.PCache}, "cache_ttl": {form.TTL},
		"seed": {form.Seed}, "frequency_penalty": {form.Freq}, "presence_penalty": {form.Pres}, "top_logprobs": {form.Logp},
		"parallel_tool_calls": {form.PTC}, "service_tier": {form.Tier}, "response_format": {form.RFmt},
		"schema_name": {form.SchemaName}, "schema_description": {form.SchemaDesc}, "schema": {form.Schema}, "schema_strict": {"on"},
		"logit_bias": {form.Bias}, "harassment": {form.Harass}, "hate_speech": {form.Hate}, "sexually_explicit": {form.Sex}, "dangerous_content": {form.Dang},
		"response_mime_type": {form.Mime}, "response_schema": {form.RSchema}, "candidate_count": {form.Cand},
	}
	out, err := csFormFromValues(v).toProto()
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(in, out) {
		t.Errorf("round trip changed settings:\n in: %v\nout: %v", in, out)
	}

	// An empty form stores nothing.
	empty, err := csFormFromValues(url.Values{}).toProto()
	if err != nil || !proto.Equal(empty, &psmithv1.CallSettings{}) {
		t.Errorf("empty form = %v, %v", empty, err)
	}
	for _, bad := range []url.Values{{"temperature": {"3"}}, {"top_k": {"x"}}, {"logit_bias": {"[]"}}, {"response_format": {"json_schema"}, "schema": {"{"}}, {"candidate_count": {"9"}}} {
		if _, err := csFormFromValues(bad).toProto(); err == nil {
			t.Errorf("%v accepted", bad)
		}
	}
}

func TestSettingsAFormatting(t *testing.T) {
	t.Parallel()
	for in, want := range map[float64]string{0: "$0.00", 0.0043: "$0.004", 0.05: "$0.05", 41.2: "$41.20", 12345.678: "$12,345.68"} {
		if got := saMoney(in); got != want {
			t.Errorf("saMoney(%v) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[int64]string{0: "0", 999: "999", 16384: "16,384", -1000000: "-1,000,000"} {
		if got := saGroupInt(in); got != want {
			t.Errorf("saGroupInt(%d) = %q", in, got)
		}
	}
	for in, want := range map[string]string{"": "Not set", "sk-ant-api03-xyz9999": "sk-ant-••••••••••••9999", "gsk_7Hq2vT9pXw4L": "gsk_••••••••••••Xw4L", "short": "••••••••••••"} {
		if got := saMaskKey(in); got != want {
			t.Errorf("saMaskKey(%q) = %q, want %q", in, got, want)
		}
	}
	h, w, tl := saKeySplit("sk-ant-••••••••••••4f2a")
	if h != "sk-ant-••••••••" || w != "••••" || tl != "4f2a" {
		t.Errorf("split = %q %q %q", h, w, tl)
	}
	if sel, c := saWarnChoice(100000); sel != "100000" || c != "" {
		t.Errorf("warn 100000 = %q %q", sel, c)
	}
	if sel, c := saWarnChoice(123456); sel != "custom" || c != "123,456" {
		t.Errorf("warn 123456 = %q %q", sel, c)
	}
}

func TestUsageWindow(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 11, 7, 15, 0, 0, 0, time.UTC)
	s, u, l := usageWindow(now, "month", "", "")
	if !s.Equal(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)) || u != nil || l != "November 1 to 7, 2026" {
		t.Errorf("month = %v %v %q", s, u, l)
	}
	s, _, l = usageWindow(now, "30d", "", "")
	if !s.Equal(time.Date(2026, 10, 9, 0, 0, 0, 0, time.UTC)) || l != "October 9 to November 7, 2026" {
		t.Errorf("30d = %v %q", s, l)
	}
	s, u, l = usageWindow(now, "custom", "2025-12-30", "2026-01-02")
	if !s.Equal(time.Date(2025, 12, 30, 0, 0, 0, 0, time.UTC)) || !u.Equal(time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)) || l != "December 30, 2025 to January 2, 2026" {
		t.Errorf("custom = %v %v %q", s, u, l)
	}
	if s, u, l := usageWindow(now, "custom", "", ""); s != nil || u != nil || l != "All time" {
		t.Errorf("open custom = %v %v %q", s, u, l)
	}
}

func TestProbeSummary(t *testing.T) {
	t.Parallel()
	res, rows := saProbeSummary(&psmithv1.ProbeUserModelResponse{
		Results: []*psmithv1.CapabilityProbeResult{
			{Capability: "vision", Outcome: psmithv1.ProbeOutcome_PROBE_OUTCOME_SUPPORTED},
			{Capability: "thinking", Outcome: psmithv1.ProbeOutcome_PROBE_OUTCOME_UNSUPPORTED, Detail: "no"},
		},
		Enabled: []string{"vision"}, Contradicted: []string{"thinking"},
	})
	if res.OK || res.Message != "Probe switched on Vision. Refused: Thinking. Turn those off if they stay refused." {
		t.Errorf("result = %+v", res)
	}
	if len(rows) != 2 || !rows[0].Good || rows[1].Outcome != "refused" {
		t.Errorf("rows = %+v", rows)
	}
}
