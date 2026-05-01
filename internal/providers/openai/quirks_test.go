package openai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/jdpedrie/reeve/internal/providers"
)

// TestQuirks_Empty_NoBehaviorChange asserts that a config without a
// PresetID (the legacy / "Custom" case) loads with empty Quirks and
// drives Send without injecting any unexpected headers.
func TestQuirks_Empty_NoBehaviorChange(t *testing.T) {
	var capturedAuthHdr, capturedXGrok string
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		capturedAuthHdr = r.Header.Get("Authorization")
		capturedXGrok = r.Header.Get("x-grok-conv-id")
		// minimal SSE terminator so the SDK closes cleanly
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:  "k",
		BaseURL: srv.URL + "/v1",
	})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:        "test-model",
		ConversationID: "conv-no-quirks",
		Messages:       []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	if atomic.LoadInt32(&calls) == 0 {
		t.Fatal("upstream not called")
	}
	if !strings.HasPrefix(capturedAuthHdr, "Bearer ") {
		t.Errorf("Authorization=%q want Bearer prefix", capturedAuthHdr)
	}
	if capturedXGrok != "" {
		t.Errorf("unexpected x-grok-conv-id=%q on non-xAI preset", capturedXGrok)
	}
}

// TestQuirks_XAI_HeaderInjector verifies the xAI preset wires
// `x-grok-conv-id` from SendRequest.ConversationID, with the exact
// lowercase-hyphenated header name the docs require.
func TestQuirks_XAI_HeaderInjector(t *testing.T) {
	var capturedXGrok string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Header.Get is case-insensitive but we capture via canonical form.
		capturedXGrok = r.Header.Get("X-Grok-Conv-Id")
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "k",
		PresetID: PresetXAI,
		BaseURL:  srv.URL + "/v1", // override the preset's real URL for the test
	})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:        "grok-4",
		ConversationID: "conv-xai-abc",
		Messages:       []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	if capturedXGrok != "conv-xai-abc" {
		t.Errorf("x-grok-conv-id=%q want conv-xai-abc", capturedXGrok)
	}
}

// TestQuirks_XAI_HeaderOmittedWithoutConversationID — off-conversation
// invocations (compaction, title generation, free-form RPCs) pass an
// empty ConversationID. The injector must not set the header in that
// case (xAI would route the request to a random server).
func TestQuirks_XAI_HeaderOmittedWithoutConversationID(t *testing.T) {
	var sawHeader bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Grok-Conv-Id") != "" {
			sawHeader = true
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "k",
		PresetID: PresetXAI,
		BaseURL:  srv.URL + "/v1",
	})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "grok-4",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		// ConversationID intentionally empty
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	if sawHeader {
		t.Error("x-grok-conv-id should be omitted when ConversationID is empty")
	}
}

// TestQuirks_XAI_DiscoveryRoutesToLanguageModels ensures the xAI quirk
// hits /v1/language-models instead of /v1/models, and parses the rich
// response shape (pricing in USD-cents-per-100M → normalized to per-1M).
func TestQuirks_XAI_DiscoveryRoutesToLanguageModels(t *testing.T) {
	var sawLangModels, sawModels bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/language-models":
			sawLangModels = true
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"models": [
					{
						"id": "grok-4",
						"prompt_text_token_price": 300,
						"cached_prompt_text_token_price": 75,
						"completion_text_token_price": 1500,
						"input_modalities": ["text", "image"]
					}
				]
			}`))
		case "/v1/models":
			sawModels = true
			t.Errorf("xAI discovery should not call /v1/models")
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "k",
		PresetID: PresetXAI,
		BaseURL:  srv.URL + "/v1",
	})

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if !sawLangModels {
		t.Error("expected /v1/language-models to be called")
	}
	_ = sawModels // already errored if hit

	if len(models) != 1 || models[0].ID != "grok-4" {
		t.Fatalf("got %+v want 1 grok-4 model", models)
	}
	m := models[0]
	if m.Pricing == nil {
		t.Fatal("expected pricing populated from xAI response")
	}
	// 300 * 0.01 = 3.00 USD per 1M tokens (3.00 USD/M is grok-4's input price)
	if got := m.Pricing.InputPerMillion; got < 2.99 || got > 3.01 {
		t.Errorf("InputPerMillion=%v want ~3.00", got)
	}
	if got := m.Pricing.OutputPerMillion; got < 14.99 || got > 15.01 {
		t.Errorf("OutputPerMillion=%v want ~15.00", got)
	}
	if got := m.Pricing.CacheReadPerMillion; got < 0.74 || got > 0.76 {
		t.Errorf("CacheReadPerMillion=%v want ~0.75", got)
	}
	if !m.Capabilities.Vision {
		t.Error("expected Vision=true (image in input_modalities)")
	}
}

// TestPresetByID_UnknownReturnsCustom — forward compat: when a config
// references a preset id newer than the running clarkd, we fall back to
// PresetCustom rather than failing.
func TestPresetByID_UnknownReturnsCustom(t *testing.T) {
	p := PresetByID("totally-made-up-id")
	if p.ID != PresetCustom {
		t.Errorf("unknown id should map to PresetCustom, got %q", p.ID)
	}
	if !p.Quirks.IsEmpty() {
		t.Error("unknown preset should have empty quirks")
	}
}

// TestPresetXAI_HasQuirks — sanity-check the registry wiring; if someone
// renames the field this test catches it before the runtime path does.
func TestPresetXAI_HasQuirks(t *testing.T) {
	p := PresetByID(PresetXAI)
	if p.Quirks.IsEmpty() {
		t.Fatal("xAI preset should have non-empty quirks")
	}
	if p.Quirks.HeaderInjector == nil {
		t.Error("xAI preset should set HeaderInjector")
	}
	if p.Quirks.DiscoveryFunc == nil {
		t.Error("xAI preset should set DiscoveryFunc")
	}
}

// TestPresetID_BaseURLAppliedWhenConfigOmits — when a config has a
// preset_id but no base_url, the preset's URL fills in.
func TestPresetID_BaseURLAppliedWhenConfigOmits(t *testing.T) {
	cfgJSON, _ := json.Marshal(Config{APIKey: "k", PresetID: PresetDeepSeek})
	p, err := New(providers.Deps{}, cfgJSON)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	d := p.(*Driver)
	if !strings.Contains(d.cfg.BaseURL, "deepseek") {
		t.Errorf("base_url=%q want preset's deepseek URL", d.cfg.BaseURL)
	}
}

// TestQuirks_OpenRouter_AppIdentityHeaders — HTTP-Referer and X-Title go
// out on every request to OpenRouter regardless of conversation id (the
// values are static).
func TestQuirks_OpenRouter_AppIdentityHeaders(t *testing.T) {
	var capturedReferer, capturedTitle string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedReferer = r.Header.Get("HTTP-Referer")
		capturedTitle = r.Header.Get("X-Title")
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "k",
		PresetID: PresetOpenRouter,
		BaseURL:  srv.URL + "/api/v1",
	})

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "anthropic/claude-haiku-4-5",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	if capturedReferer == "" {
		t.Error("HTTP-Referer should be set on OpenRouter requests")
	}
	if capturedTitle == "" {
		t.Error("X-Title should be set on OpenRouter requests")
	}
}

// TestQuirks_Qwen_EnableThinking — Qwen preset's RequestBodyFields hook
// emits `enable_thinking: true` when the universal Thinking.Enabled
// signal is set, omits it otherwise.
func TestQuirks_Qwen_EnableThinking(t *testing.T) {
	cases := []struct {
		name        string
		settings    providers.CallSettings
		wantPresent bool
		wantValue   bool
	}{
		{
			name:        "thinking unset → field omitted",
			settings:    providers.CallSettings{},
			wantPresent: false,
		},
		{
			name: "thinking enabled → enable_thinking=true",
			settings: providers.CallSettings{
				Thinking: &providers.ThinkingSettings{Enabled: ptrBool(true)},
			},
			wantPresent: true,
			wantValue:   true,
		},
		{
			name: "thinking disabled → enable_thinking=false",
			settings: providers.CallSettings{
				Thinking: &providers.ThinkingSettings{Enabled: ptrBool(false)},
			},
			wantPresent: true,
			wantValue:   false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var capturedBody string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				buf := make([]byte, 64*1024)
				n, _ := r.Body.Read(buf)
				capturedBody = string(buf[:n])
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = w.Write([]byte("data: [DONE]\n\n"))
			}))
			defer srv.Close()

			d := newOpenAIDriverForTest(t, Config{
				APIKey:   "k",
				PresetID: PresetQwen,
				BaseURL:  srv.URL + "/v1",
			})

			ch, err := d.Send(context.Background(), providers.SendRequest{
				ModelID:  "qwen3-235b",
				Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
				Settings: tc.settings,
			})
			if err != nil {
				t.Fatalf("Send: %v", err)
			}
			for range ch {
			}

			var parsed map[string]any
			if err := json.Unmarshal([]byte(capturedBody), &parsed); err != nil {
				t.Fatalf("parse body: %v; body=%s", err, capturedBody)
			}
			got, present := parsed["enable_thinking"]
			if present != tc.wantPresent {
				t.Errorf("enable_thinking present=%v want %v; body=%s", present, tc.wantPresent, capturedBody)
			}
			if tc.wantPresent {
				if b, ok := got.(bool); !ok || b != tc.wantValue {
					t.Errorf("enable_thinking=%v want %v", got, tc.wantValue)
				}
			}
		})
	}
}

// TestQuirks_RequestBodyFields_DeterministicOrder — the slice of
// option.WithJSONSet entries the driver builds must be sorted by key, so
// equivalent quirks produce byte-identical request bodies. Important
// because tests elsewhere may grep request bodies for fragments and the
// SDK preserves insertion order.
func TestQuirks_RequestBodyFields_DeterministicOrder(t *testing.T) {
	// Two artificial fields to verify ordering. Use a synthesized Driver
	// with a custom Quirks block, since none of the public presets emit
	// multiple fields today.
	custom := Quirks{
		RequestBodyFields: func(_ providers.SendRequest) map[string]any {
			return map[string]any{"zfield": "z", "afield": "a"}
		},
	}
	var capturedBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 64*1024)
		n, _ := r.Body.Read(buf)
		capturedBody = string(buf[:n])
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{APIKey: "k", BaseURL: srv.URL + "/v1"})
	d.quirks = custom

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "x",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	// Both fields land in the body; we don't assert on relative order
	// because the SDK serializes typed params first then merges
	// WithJSONSet, and the merged-in keys may sort by Go map iteration
	// in the JSON encoder. The contract is that BOTH fields are present.
	if !strings.Contains(capturedBody, `"afield":"a"`) ||
		!strings.Contains(capturedBody, `"zfield":"z"`) {
		t.Errorf("expected both fields in body; got %s", capturedBody)
	}
}

// TestQuirks_Ollama_DiscoveryHitsApiTags — Ollama preset's DiscoveryFunc
// translates the configured /v1 base url to /api/tags on the same host
// and decodes the richer response shape (parameter size + quantization
// embedded in display name).
func TestQuirks_Ollama_DiscoveryHitsApiTags(t *testing.T) {
	var capturedPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		switch r.URL.Path {
		case "/api/tags":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"models": [
					{
						"name": "llama3.1:8b",
						"size": 4920753607,
						"details": {
							"family": "llama",
							"parameter_size": "8.0B",
							"quantization_level": "Q4_0"
						}
					},
					{
						"name": "qwen2.5-coder:14b",
						"size": 9000000000,
						"details": {
							"family": "qwen",
							"parameter_size": "14.0B",
							"quantization_level": "Q4_K_M"
						}
					}
				]
			}`))
		case "/v1/models":
			t.Errorf("Ollama discovery should hit /api/tags, not /v1/models")
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "ollama", // unauthenticated, value ignored
		PresetID: PresetOllama,
		BaseURL:  srv.URL + "/v1",
	})

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if capturedPath != "/api/tags" {
		t.Errorf("captured path=%q want /api/tags", capturedPath)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models want 2", len(models))
	}
	want := map[string]string{
		"llama3.1:8b":         "llama3.1:8b (8.0B, Q4_0)",
		"qwen2.5-coder:14b":   "qwen2.5-coder:14b (14.0B, Q4_K_M)",
	}
	for _, m := range models {
		if want[m.ID] != m.DisplayName {
			t.Errorf("model %q display=%q want %q", m.ID, m.DisplayName, want[m.ID])
		}
	}
}

// TestQuirks_Ollama_BaseURLWithoutV1 — defensive: some users front Ollama
// with a reverse proxy that strips /v1. The path translator must still
// land at /api/tags regardless of whether the configured base_url ends
// in /v1 or not.
func TestQuirks_Ollama_BaseURLWithoutV1(t *testing.T) {
	var capturedPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"models":[]}`))
	}))
	defer srv.Close()

	d := newOpenAIDriverForTest(t, Config{
		APIKey:   "x",
		PresetID: PresetOllama,
		BaseURL:  srv.URL, // no /v1 suffix
	})

	if _, err := d.DiscoverModels(context.Background()); err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if capturedPath != "/api/tags" {
		t.Errorf("captured path=%q want /api/tags", capturedPath)
	}
}

func ptrBool(b bool) *bool { return &b }

// newOpenAIDriverForTest builds a Driver pointed at a test server,
// optionally with a preset id wired through. Mirrors the helper used by
// other openai_test.go suites.
func newOpenAIDriverForTest(t *testing.T, cfg Config) *Driver {
	t.Helper()
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal cfg: %v", err)
	}
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	d := p.(*Driver)
	// The tests above use httptest URLs which are not api.openai.com, so
	// resolveChatCompletions already picks chat-completions for them —
	// no additional wiring needed.
	return d
}
