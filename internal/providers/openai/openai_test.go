package openai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
)

// ---------- Test fakes ---------------------------------------------------

// fakeCatalog is a minimal modelmeta.Catalog stub: only LookupModel is
// exercised by the openai-compatible driver, the others return zero values.
type fakeCatalog struct {
	models map[string]*modelmeta.Model
}

func (f *fakeCatalog) LookupModel(_ context.Context, _, modelID string) (*modelmeta.Model, error) {
	if m, ok := f.models[modelID]; ok {
		return m, nil
	}
	return nil, modelmeta.ErrNotFound
}

func (f *fakeCatalog) LookupProvider(_ context.Context, _ string) (*modelmeta.Provider, error) {
	return nil, modelmeta.ErrNotFound
}

func (f *fakeCatalog) ListProviders(_ context.Context) ([]modelmeta.Provider, error) {
	return nil, nil
}

func (f *fakeCatalog) ListModelsByProvider(_ context.Context, _ string) ([]modelmeta.Model, error) {
	return nil, nil
}

func (f *fakeCatalog) Refresh(_ context.Context) error { return nil }

func (f *fakeCatalog) Status(_ context.Context) (modelmeta.Status, error) {
	return modelmeta.Status{}, nil
}

// validConfig returns a json.RawMessage that satisfies New's required
// fields. base_url is filled in by the caller.
//
// Doesn't set UseChatCompletions — the routing rule in New() forces
// non-OpenAI base URLs (httptest's localhost) to chat-completions, so
// stored UseChatCompletions=false would be ignored anyway. Tests that
// need the Responses-API path call `forceResponsesAPI(p)` after New().
// Tests that want chat-completions just use validConfig as-is.
func validConfig(t *testing.T, baseURL, catalogProviderID string) json.RawMessage {
	t.Helper()
	cfg := Config{
		APIKey:            "test-key",
		BaseURL:           baseURL,
		CatalogProviderID: catalogProviderID,
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal cfg: %v", err)
	}
	return raw
}

// forceResponsesAPI flips a freshly-built Driver from chat-completions
// (the auto-detected default for httptest base URLs) over to the
// Responses-API path. The routing rule production code uses requires the
// base URL to be api.openai.com to pick Responses, which httptest can't
// satisfy — so tests exercising the Responses code path post-mutate the
// unexported flag here.
func forceResponsesAPI(t *testing.T, p providers.Provider) providers.Provider {
	t.Helper()
	d, ok := p.(*Driver)
	if !ok {
		t.Fatalf("provider is not *Driver: %T", p)
	}
	d.chatCompletions = false
	return p
}

// ---------- New() --------------------------------------------------------

func TestNew_Valid(t *testing.T) {
	cfg := validConfig(t, "http://example/v1", "openai")
	p, err := New(providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if p.Type() != "openai-compatible" {
		t.Errorf("Type=%q want openai-compatible", p.Type())
	}
	if p.Stateful() {
		t.Errorf("Stateful=true want false")
	}
}

func TestNew_MissingAPIKey(t *testing.T) {
	cfg := json.RawMessage(`{"base_url":"http://x/v1"}`)
	if _, err := New(providers.Deps{}, cfg); err == nil ||
		!strings.Contains(err.Error(), "api_key") {
		t.Errorf("expected api_key error, got %v", err)
	}
}

func TestNew_MissingBaseURL(t *testing.T) {
	cfg := json.RawMessage(`{"api_key":"x"}`)
	if _, err := New(providers.Deps{}, cfg); err == nil ||
		!strings.Contains(err.Error(), "base_url") {
		t.Errorf("expected base_url error, got %v", err)
	}
}

func TestNew_EmptyConfig(t *testing.T) {
	if _, err := New(providers.Deps{}, nil); err == nil {
		t.Error("expected error for nil config")
	}
	if _, err := New(providers.Deps{}, json.RawMessage{}); err == nil {
		t.Error("expected error for empty config")
	}
}

func TestNew_InvalidJSON(t *testing.T) {
	cfg := json.RawMessage(`{"api_key":`)
	if _, err := New(providers.Deps{}, cfg); err == nil {
		t.Error("expected JSON parse error")
	}
}

// ---------- DiscoverModels() ---------------------------------------------

// modelsHandler mounts /v1/models and returns a canned list payload.
func modelsHandler(t *testing.T, ids ...string) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("models: unexpected method %s", r.Method)
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			t.Errorf("models: missing bearer auth header (got %q)", auth)
		}
		w.Header().Set("Content-Type", "application/json")
		var data []map[string]any
		for _, id := range ids {
			data = append(data, map[string]any{
				"id":       id,
				"object":   "model",
				"created":  time.Now().Unix(),
				"owned_by": "test",
			})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"object": "list",
			"data":   data,
		})
	})
	return mux
}

func TestDiscoverModels_NoCatalogProviderID(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t, "gpt-test-a", "gpt-test-b"))
	defer srv.Close()

	cat := &fakeCatalog{models: map[string]*modelmeta.Model{
		// Even with this row present, no enrichment should happen because
		// CatalogProviderID is empty.
		"gpt-test-a": {ContextWindow: 999999},
	}}

	p, err := New(providers.Deps{Catalog: cat}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	models, err := p.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models, want 2", len(models))
	}
	for _, m := range models {
		if m.MetadataSource != modelmeta.SourceDriver {
			t.Errorf("model %q: source=%q want driver", m.ID, m.MetadataSource)
		}
		if m.ContextWindow != 0 {
			t.Errorf("model %q: ContextWindow leaked from catalog (%d)", m.ID, m.ContextWindow)
		}
	}
}

func TestDiscoverModels_CatalogHitAndMiss(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t, "gpt-known", "gpt-unknown"))
	defer srv.Close()

	cutoff := time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC)
	cat := &fakeCatalog{models: map[string]*modelmeta.Model{
		"gpt-known": {
			ID:              "gpt-known",
			DisplayName:     "GPT Known",
			ContextWindow:   123456,
			MaxOutputTokens: 8192,
			Pricing: &modelmeta.Pricing{
				InputPerMillion:  1.0,
				OutputPerMillion: 2.0,
			},
			Capabilities: modelmeta.Capabilities{
				Streaming: true,
				ToolUse:   true,
			},
			Modalities:      []string{"text"},
			KnowledgeCutoff: &cutoff,
		},
	}}

	p, err := New(providers.Deps{Catalog: cat}, validConfig(t, srv.URL+"/v1", "openai"))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	models, err := p.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models, want 2", len(models))
	}
	byID := map[string]providers.Model{}
	for _, m := range models {
		byID[m.ID] = m
	}

	hit := byID["gpt-known"]
	if hit.MetadataSource != modelmeta.SourceCatalog {
		t.Errorf("known: source=%q want catalog", hit.MetadataSource)
	}
	if hit.DisplayName != "GPT Known" {
		t.Errorf("known: DisplayName=%q want GPT Known", hit.DisplayName)
	}
	if hit.ContextWindow != 123456 {
		t.Errorf("known: ContextWindow=%d want 123456", hit.ContextWindow)
	}
	if hit.Pricing == nil || hit.Pricing.InputPerMillion != 1.0 {
		t.Errorf("known: Pricing not copied: %+v", hit.Pricing)
	}
	if !hit.Capabilities.ToolUse {
		t.Errorf("known: Capabilities.ToolUse not copied")
	}
	if hit.KnowledgeCutoff != "2025-06-01" {
		t.Errorf("known: KnowledgeCutoff=%q want 2025-06-01", hit.KnowledgeCutoff)
	}

	miss := byID["gpt-unknown"]
	if miss.MetadataSource != modelmeta.SourceDriver {
		t.Errorf("unknown: source=%q want driver", miss.MetadataSource)
	}
	if miss.ContextWindow != 0 {
		t.Errorf("unknown: ContextWindow=%d want 0", miss.ContextWindow)
	}
	if miss.DisplayName != "gpt-unknown" {
		t.Errorf("unknown: DisplayName=%q want fallback to ID", miss.DisplayName)
	}
}

func TestDiscoverModels_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"message":"boom"}}`))
	}))
	defer srv.Close()

	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := p.DiscoverModels(context.Background()); err == nil {
		t.Error("expected error from upstream 500")
	}
}

// ---------- Send() (Responses API streaming) -----------------------------

// sseLine writes a single SSE event with a JSON-encoded data payload.
func sseLine(w http.ResponseWriter, eventType string, data any) {
	raw, _ := json.Marshal(data)
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", eventType, raw)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// responsesStreamHandler emits a canned event sequence containing one
// reasoning summary delta, two text deltas, and a completion event.
func responsesStreamHandler(t *testing.T) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/responses", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("responses: unexpected method %s", r.Method)
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")

		sseLine(w, "response.created", map[string]any{
			"type":            "response.created",
			"sequence_number": 1,
			"response":        map[string]any{"id": "resp_test", "status": "in_progress"},
		})
		sseLine(w, "response.reasoning_summary_text.delta", map[string]any{
			"type":            "response.reasoning_summary_text.delta",
			"sequence_number": 2,
			"item_id":         "rs_1",
			"output_index":    0,
			"summary_index":   0,
			"delta":           "thinking about it",
		})
		sseLine(w, "response.output_text.delta", map[string]any{
			"type":            "response.output_text.delta",
			"sequence_number": 3,
			"item_id":         "msg_1",
			"output_index":    1,
			"content_index":   0,
			"logprobs":        []any{},
			"delta":           "Hello, ",
		})
		sseLine(w, "response.output_text.delta", map[string]any{
			"type":            "response.output_text.delta",
			"sequence_number": 4,
			"item_id":         "msg_1",
			"output_index":    1,
			"content_index":   0,
			"logprobs":        []any{},
			"delta":           "world!",
		})
		sseLine(w, "response.completed", map[string]any{
			"type":            "response.completed",
			"sequence_number": 5,
			"response":        map[string]any{"id": "resp_test", "status": "completed"},
		})
	})
	return mux
}

func TestSend_StreamsTextAndThinking(t *testing.T) {
	srv := httptest.NewServer(responsesStreamHandler(t))
	defer srv.Close()

	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	p = forceResponsesAPI(t, p)
	stateless, ok := p.(providers.StatelessProvider)
	if !ok {
		t.Fatal("driver does not satisfy StatelessProvider")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ch, err := stateless.Send(ctx, providers.SendRequest{
		ModelID: "gpt-test",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "be brief"},
			{Role: "user", Content: "hi"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var got []providers.Chunk
	for c := range ch {
		got = append(got, c)
	}

	wantTypes := []providers.ChunkType{
		providers.ChunkThinking,
		providers.ChunkText,
		providers.ChunkText,
		providers.ChunkDone,
	}
	if len(got) != len(wantTypes) {
		t.Fatalf("got %d chunks, want %d: %+v", len(got), len(wantTypes), got)
	}
	for i, w := range wantTypes {
		if got[i].Type != w {
			t.Errorf("chunk[%d].Type=%q want %q", i, got[i].Type, w)
		}
	}

	// First text chunk carries "Hello, "
	var p1 struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(got[1].Payload, &p1); err != nil {
		t.Fatalf("text payload[1]: %v", err)
	}
	if p1.Text != "Hello, " {
		t.Errorf("text payload[1].text=%q want %q", p1.Text, "Hello, ")
	}

	// Thinking chunk carries the reasoning summary.
	var pT struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(got[0].Payload, &pT); err != nil {
		t.Fatalf("thinking payload: %v", err)
	}
	if pT.Text != "thinking about it" {
		t.Errorf("thinking payload.text=%q", pT.Text)
	}
}

func TestSend_ErrorEvent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		sseLine(w, "error", map[string]any{
			"type":            "error",
			"sequence_number": 1,
			"code":            "rate_limited",
			"message":         "slow down",
			"param":           "",
		})
		sseLine(w, "response.completed", map[string]any{
			"type":            "response.completed",
			"sequence_number": 2,
			"response":        map[string]any{"id": "x", "status": "completed"},
		})
	}))
	defer srv.Close()

	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	p = forceResponsesAPI(t, p)
	ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
		ModelID:  "gpt-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var sawError, sawDone bool
	for c := range ch {
		switch c.Type {
		case providers.ChunkError:
			sawError = true
			var p struct {
				Message string `json:"message"`
				Code    string `json:"code"`
			}
			if err := json.Unmarshal(c.Payload, &p); err != nil {
				t.Fatalf("error payload: %v", err)
			}
			if p.Message != "slow down" || p.Code != "rate_limited" {
				t.Errorf("error payload=%+v", p)
			}
		case providers.ChunkDone:
			sawDone = true
		}
	}
	if !sawError {
		t.Error("expected ChunkError")
	}
	if !sawDone {
		t.Error("expected ChunkDone after error")
	}
}

func TestSend_MissingModelID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("upstream should not be called when ModelID is empty")
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := p.(providers.StatelessProvider).Send(
		context.Background(),
		providers.SendRequest{ModelID: "", Messages: []providers.WireMessage{{Role: "user", Content: "hi"}}},
	); err == nil {
		t.Error("expected error for missing model_id")
	}
}

func TestSend_ChatCompletions_Streams(t *testing.T) {
	// Mock a Chat Completions SSE stream with two text deltas, the
	// finish_reason chunk, and a trailing usage-bearing chunk (emitted by the
	// server when stream_options.include_usage=true, which the driver always sets).
	const sse = "data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"},\"finish_reason\":\"\"}]}\n\n" +
		"data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"\"}]}\n\n" +
		"data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
		"data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15,\"prompt_tokens_details\":{\"cached_tokens\":4},\"completion_tokens_details\":{\"reasoning_tokens\":1}}}\n\n" +
		"data: [DONE]\n\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(sse))
	}))
	defer srv.Close()

	cfg := Config{APIKey: "k", BaseURL: srv.URL, UseChatCompletions: boolPtr(true)}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ch, err := p.(providers.StatelessProvider).Send(
		context.Background(),
		providers.SendRequest{ModelID: "gpt", Messages: []providers.WireMessage{{Role: "user", Content: "hi"}}},
	)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	var got []providers.ChunkType
	var text string
	var usage *providers.Usage
	for c := range ch {
		got = append(got, c.Type)
		switch c.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		case providers.ChunkUsage:
			var u providers.Usage
			if err := json.Unmarshal(c.Payload, &u); err != nil {
				t.Errorf("usage payload unmarshal: %v", err)
			}
			usage = &u
		}
	}
	if text != "Hello" {
		t.Errorf("assembled text %q, want %q", text, "Hello")
	}
	wantDone := false
	for _, t := range got {
		if t == providers.ChunkDone {
			wantDone = true
		}
	}
	if !wantDone {
		t.Errorf("expected ChunkDone in %v", got)
	}
	if usage == nil {
		t.Fatal("expected ChunkUsage to be emitted")
	}
	if usage.InputTokens == nil || *usage.InputTokens != 12 {
		t.Errorf("input_tokens=%v want 12", usage.InputTokens)
	}
	if usage.OutputTokens == nil || *usage.OutputTokens != 3 {
		t.Errorf("output_tokens=%v want 3", usage.OutputTokens)
	}
	if usage.CacheReadTokens == nil || *usage.CacheReadTokens != 4 {
		t.Errorf("cache_read_tokens=%v want 4", usage.CacheReadTokens)
	}
	if usage.ReasoningTokens == nil || *usage.ReasoningTokens != 1 {
		t.Errorf("reasoning_tokens=%v want 1", usage.ReasoningTokens)
	}
}

// ---------- RenderThinkingToText() ---------------------------------------

func TestRenderThinkingToText(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"nil", "", ""},
		{"empty-string", `""`, ""},
		{"reasoning-item", `{"id":"rs_1","type":"reasoning","summary":[{"text":"first thought","type":"summary_text"},{"text":"second thought","type":"summary_text"}]}`, "first thought\n\nsecond thought"},
		{"string-array", `["thought a","thought b"]`, "thought a\n\nthought b"},
		{"object-array", `[{"text":"a"},{"text":"b"}]`, "a\n\nb"},
		{"single-text-object", `{"text":"alone"}`, "alone"},
		{"malformed", `{not json}`, ""},
		{"unknown-shape", `{"foo":"bar"}`, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := RenderThinkingToText(json.RawMessage(c.in))
			if got != c.want {
				t.Errorf("got %q want %q", got, c.want)
			}
		})
	}
}

func TestRenderThinkingToText_NoPanicOnNil(t *testing.T) {
	var d Driver
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("panic on nil thinking: %v", r)
		}
	}()
	if got := d.RenderThinkingToText(nil); got != "" {
		t.Errorf("nil thinking: got %q want empty", got)
	}
}

// ---------- CallSettings translation -------------------------------------

// captureRequest mounts a /chat/completions or /responses handler that
// records the request body and emits a minimal terminal SSE so the driver
// returns cleanly.
func captureRequest(t *testing.T, path string, terminator string) (*httptest.Server, *string) {
	t.Helper()
	var captured string
	mux := http.NewServeMux()
	mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 64*1024)
		n, _ := r.Body.Read(buf)
		captured = string(buf[:n])
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(terminator))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &captured
}

func TestSend_ChatCompletions_AllNewFields(t *testing.T) {
	const term = "data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
	srv, captured := captureRequest(t, "/chat/completions", term)

	cfg := Config{APIKey: "k", BaseURL: srv.URL, UseChatCompletions: boolPtr(true)}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	seed := 42
	freqPen := 0.5
	presPen := -0.25
	topL := 3
	parTool := false
	tier := providers.ServiceTierPriority
	jsonObj := true
	ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
		ModelID:        "gpt-test",
		ConversationID: "cv-12345",
		Messages:       []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{
			Temperature:   f64Ptr(0.42),
			TopP:          f64Ptr(0.9),
			StopSequences: []string{"END"},
			OpenAI: &providers.OpenAIExtras{
				Seed:              &seed,
				FrequencyPenalty:  &freqPen,
				PresencePenalty:   &presPen,
				TopLogprobs:       &topL,
				ParallelToolCalls: &parTool,
				ServiceTier:       &tier,
				ResponseFormat: &providers.ResponseFormat{
					JSONObject: &jsonObj,
				},
				LogitBias: map[int32]float64{50256: -100, 198: 1},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	body := *captured
	checks := []struct {
		name     string
		fragment string
	}{
		{"temperature", `"temperature":0.42`},
		{"top_p", `"top_p":0.9`},
		{"stop", `"stop":["END"]`},
		{"seed", `"seed":42`},
		{"frequency_penalty", `"frequency_penalty":0.5`},
		{"presence_penalty", `"presence_penalty":-0.25`},
		{"top_logprobs", `"top_logprobs":3`},
		{"logprobs", `"logprobs":true`},
		{"parallel_tool_calls", `"parallel_tool_calls":false`},
		{"service_tier", `"service_tier":"priority"`},
		{"response_format json_object", `"type":"json_object"`},
		{"prompt_cache_key", `"prompt_cache_key":"cv-12345"`},
		{"logit_bias 50256", `"50256":-100`},
		{"logit_bias 198", `"198":1`},
	}
	for _, c := range checks {
		if !strings.Contains(body, c.fragment) {
			t.Errorf("%s: expected fragment %q in body; body=%s", c.name, c.fragment, body)
		}
	}
}

// TestSend_ChatCompletions_JSONSchemaResponseFormat covers the json_schema
// branch of the response_format oneof, which decodes the raw bytes into a
// proper JSON value (so the SDK doesn't string-quote them on the wire).
func TestSend_ChatCompletions_JSONSchemaResponseFormat(t *testing.T) {
	const term = "data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
	srv, captured := captureRequest(t, "/chat/completions", term)

	cfg := Config{APIKey: "k", BaseURL: srv.URL, UseChatCompletions: boolPtr(true)}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	desc := "shape of the answer"
	strict := true
	ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
		ModelID:  "gpt-test",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{
			OpenAI: &providers.OpenAIExtras{
				ResponseFormat: &providers.ResponseFormat{
					JSONSchema: &providers.JSONSchema{
						Name:        "answer",
						Description: &desc,
						Strict:      &strict,
						Schema:      []byte(`{"type":"object","properties":{"x":{"type":"integer"}}}`),
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	body := *captured
	if !strings.Contains(body, `"type":"json_schema"`) {
		t.Errorf("expected json_schema type marker; body=%s", body)
	}
	if !strings.Contains(body, `"name":"answer"`) {
		t.Errorf("expected schema name; body=%s", body)
	}
	if !strings.Contains(body, `"description":"shape of the answer"`) {
		t.Errorf("expected schema description; body=%s", body)
	}
	if !strings.Contains(body, `"strict":true`) {
		t.Errorf("expected strict=true; body=%s", body)
	}
	// Schema bytes must round-trip as a JSON object, NOT a quoted string.
	if !strings.Contains(body, `"properties":{"x":{"type":"integer"}}`) {
		t.Errorf("schema body should be inlined as JSON, not a string; body=%s", body)
	}
}

func TestSend_Responses_AllNewFields(t *testing.T) {
	srv, captured := captureRequest(t, "/v1/responses", "event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":1,\"response\":{\"id\":\"r\",\"status\":\"completed\"}}\n\n")

	p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	p = forceResponsesAPI(t, p)

	tier := providers.ServiceTierAuto
	enabled := true
	budget := 6000 // medium effort
	ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
		ModelID:        "gpt-5",
		ConversationID: "conv-abc",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "be brief"},
			{Role: "user", Content: "hi"},
		},
		Settings: providers.CallSettings{
			Temperature:   f64Ptr(0.3),
			TopP:          f64Ptr(0.85),
			Thinking:      &providers.ThinkingSettings{Enabled: &enabled, BudgetTokens: &budget},
			StopSequences: []string{"END"}, // dropped on Responses; should not error
			OpenAI: &providers.OpenAIExtras{
				ServiceTier: &tier,
				// These should silently drop on Responses path.
				FrequencyPenalty: f64Ptr(0.5),
				PresencePenalty:  f64Ptr(-0.5),
				TopLogprobs:      intPtr(3),
				LogitBias:        map[int32]float64{50256: -10},
				ResponseFormat: &providers.ResponseFormat{
					JSONObject: boolPtr(true),
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for range ch {
	}

	body := *captured
	if !strings.Contains(body, `"temperature":0.3`) {
		t.Errorf("temperature missing; body=%s", body)
	}
	if !strings.Contains(body, `"top_p":0.85`) {
		t.Errorf("top_p missing; body=%s", body)
	}
	if !strings.Contains(body, `"prompt_cache_key":"conv-abc"`) {
		t.Errorf("prompt_cache_key missing; body=%s", body)
	}
	if !strings.Contains(body, `"service_tier":"auto"`) {
		t.Errorf("service_tier missing; body=%s", body)
	}
	if !strings.Contains(body, `"effort":"medium"`) {
		t.Errorf("reasoning effort missing (budget=6000 should derive medium); body=%s", body)
	}
	// These should NOT appear in the body — Responses doesn't surface them.
	for _, fragment := range []string{
		`"frequency_penalty"`,
		`"presence_penalty"`,
		`"top_logprobs"`,
		`"logit_bias"`,
		`"response_format"`,
	} {
		if strings.Contains(body, fragment) {
			t.Errorf("Responses body should NOT contain %s; body=%s", fragment, body)
		}
	}
}

// TestSend_Responses_ReasoningEffortFromBudget exercises the budget→effort
// mapping (<2k → low, 2-8k → medium, >8k → high).
func TestSend_Responses_ReasoningEffortFromBudget(t *testing.T) {
	cases := []struct {
		name   string
		budget int
		effort string
	}{
		{"low", 1500, "low"},
		{"medium-low-edge", 2000, "medium"},
		{"medium-high-edge", 8000, "medium"},
		{"high", 12000, "high"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, captured := captureRequest(t, "/v1/responses",
				"event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":1,\"response\":{\"id\":\"r\",\"status\":\"completed\"}}\n\n")
			p, err := New(providers.Deps{}, validConfig(t, srv.URL+"/v1", ""))
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			p = forceResponsesAPI(t, p)
			enabled := true
			b := tc.budget
			ch, err := p.(providers.StatelessProvider).Send(context.Background(), providers.SendRequest{
				ModelID:  "gpt-5",
				Messages: []providers.WireMessage{{Role: "user", Content: "x"}},
				Settings: providers.CallSettings{
					Thinking: &providers.ThinkingSettings{Enabled: &enabled, BudgetTokens: &b},
				},
			})
			if err != nil {
				t.Fatalf("Send: %v", err)
			}
			for range ch {
			}
			if !strings.Contains(*captured, `"effort":"`+tc.effort+`"`) {
				t.Errorf("budget=%d expected effort=%s; body=%s", tc.budget, tc.effort, *captured)
			}
		})
	}
}

func f64Ptr(v float64) *float64 { return &v }
func intPtr(v int) *int         { return &v }
func boolPtr(v bool) *bool      { return &v }

// ---------- Registry round trip ------------------------------------------

func TestRegistry_BuildOpenAICompatible(t *testing.T) {
	cfg := validConfig(t, "http://example/v1", "")
	p, err := providers.Build("openai-compatible", providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if p == nil {
		t.Fatal("Build returned nil provider")
	}
	if p.Type() != "openai-compatible" {
		t.Errorf("Type=%q want openai-compatible", p.Type())
	}
	if _, ok := p.(providers.StatelessProvider); !ok {
		t.Error("driver should satisfy StatelessProvider")
	}
}

// Ensure the driver satisfies the interface contracts at compile time.
var (
	_ providers.Provider          = (*Driver)(nil)
	_ providers.StatelessProvider = (*Driver)(nil)
)

// quiet "imported and not used" if any test path is removed.
var _ = errors.New
