package anthropic

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
)

// fakeCatalog implements modelmeta.Catalog with an in-memory map.
// Only LookupModel is exercised by the driver; the rest are stubbed to
// satisfy the interface.
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
func (f *fakeCatalog) Refresh(_ context.Context) error                   { return nil }
func (f *fakeCatalog) Status(_ context.Context) (modelmeta.Status, error) { return modelmeta.Status{}, nil }

// newTestDriver builds a Driver pointed at the given httptest server.
func newTestDriver(t *testing.T, baseURL string, cat modelmeta.Catalog) *Driver {
	t.Helper()
	cfg, _ := json.Marshal(Config{APIKey: "sk-test", BaseURL: baseURL})
	p, err := New(providers.Deps{Catalog: cat}, cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return p.(*Driver)
}

// ---------------------------------------------------------------------
// New / construction
// ---------------------------------------------------------------------

func TestNew_Valid(t *testing.T) {
	cfg, _ := json.Marshal(Config{APIKey: "k"})
	p, err := New(providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if p.Type() != "anthropic" {
		t.Errorf("Type=%q want anthropic", p.Type())
	}
	if p.Stateful() {
		t.Error("Stateful() should be false for the HTTP driver")
	}
}

func TestNew_EmptyAPIKey(t *testing.T) {
	_, err := New(providers.Deps{}, json.RawMessage(`{}`))
	if err == nil {
		t.Fatal("expected error for missing api_key")
	}
}

func TestNew_NilConfig(t *testing.T) {
	// nil/empty config is treated as "no api key" → error.
	_, err := New(providers.Deps{}, nil)
	if err == nil {
		t.Fatal("expected error for nil config")
	}
}

func TestNew_InvalidJSON(t *testing.T) {
	_, err := New(providers.Deps{}, json.RawMessage(`{not json`))
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

// ---------------------------------------------------------------------
// Registry self-registration
// ---------------------------------------------------------------------

func TestRegistry_BuildAnthropic(t *testing.T) {
	cfg, _ := json.Marshal(Config{APIKey: "k"})
	p, err := providers.Build("anthropic", providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("providers.Build: %v", err)
	}
	if p == nil {
		t.Fatal("expected non-nil provider")
	}
	if p.Type() != "anthropic" {
		t.Errorf("Type=%q want anthropic", p.Type())
	}
}

// ---------------------------------------------------------------------
// DiscoverModels
// ---------------------------------------------------------------------

func TestDiscoverModels_EnrichesAndFallsBack(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/v1/models") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{
			"data": [
				{"id":"claude-opus-4-7","display_name":"Claude Opus 4.7","created_at":"2026-04-01T00:00:00Z","type":"model"},
				{"id":"claude-mystery-9","display_name":"Mystery","created_at":"2026-04-01T00:00:00Z","type":"model"}
			],
			"has_more": false,
			"first_id": "claude-opus-4-7",
			"last_id": "claude-mystery-9"
		}`))
	}))
	defer srv.Close()

	cutoff := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	cat := &fakeCatalog{models: map[string]*modelmeta.Model{
		"claude-opus-4-7": {
			ProviderID:      "anthropic",
			ID:              "claude-opus-4-7",
			ContextWindow:   1_000_000,
			MaxOutputTokens: 64_000,
			Pricing: &modelmeta.Pricing{
				InputPerMillion:      15,
				OutputPerMillion:     75,
				CacheReadPerMillion:  1.5,
				CacheWritePerMillion: 18.75,
			},
			Capabilities:    modelmeta.Capabilities{Streaming: true, Thinking: true, ToolUse: true, Vision: true, PromptCaching: true},
			Modalities:      []string{"text", "image"},
			KnowledgeCutoff: &cutoff,
		},
	}}

	d := newTestDriver(t, srv.URL, cat)

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models, want 2", len(models))
	}

	// First model: catalog hit
	hit := models[0]
	if hit.ID != "claude-opus-4-7" {
		t.Errorf("ID=%q", hit.ID)
	}
	if hit.MetadataSource != modelmeta.SourceCatalog {
		t.Errorf("MetadataSource=%q want catalog", hit.MetadataSource)
	}
	if hit.ContextWindow != 1_000_000 {
		t.Errorf("ContextWindow=%d", hit.ContextWindow)
	}
	if hit.MaxOutputTokens != 64_000 {
		t.Errorf("MaxOutputTokens=%d", hit.MaxOutputTokens)
	}
	if hit.Pricing == nil || hit.Pricing.InputPerMillion != 15 {
		t.Errorf("Pricing not enriched: %+v", hit.Pricing)
	}
	if !hit.Capabilities.Thinking || !hit.Capabilities.PromptCaching {
		t.Errorf("Capabilities not enriched: %+v", hit.Capabilities)
	}
	if hit.KnowledgeCutoff != "2026-01-01" {
		t.Errorf("KnowledgeCutoff=%q", hit.KnowledgeCutoff)
	}

	// Second model: catalog miss
	miss := models[1]
	if miss.ID != "claude-mystery-9" {
		t.Errorf("ID=%q", miss.ID)
	}
	if miss.MetadataSource != modelmeta.SourceDriver {
		t.Errorf("MetadataSource=%q want driver", miss.MetadataSource)
	}
	if miss.ContextWindow != 0 || miss.Pricing != nil {
		t.Errorf("expected zero metadata for catalog miss, got %+v", miss)
	}
}

func TestDiscoverModels_NoCatalog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"id":"x","display_name":"X","created_at":"2026-04-01T00:00:00Z","type":"model"}],"has_more":false,"first_id":"x","last_id":"x"}`))
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil) // no catalog injected

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 1 || models[0].MetadataSource != modelmeta.SourceDriver {
		t.Errorf("expected single driver-sourced entry, got %+v", models)
	}
}

func TestDiscoverModels_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"boom"}`, 500)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	if _, err := d.DiscoverModels(context.Background()); err == nil {
		t.Fatal("expected error from 500 response")
	}
}

// ---------------------------------------------------------------------
// Send / streaming
// ---------------------------------------------------------------------

// sseEvents writes an Anthropic-style SSE stream with the given (event, data) pairs.
func sseEvents(w http.ResponseWriter, pairs ...[2]string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	for _, p := range pairs {
		_, _ = w.Write([]byte("event: " + p[0] + "\ndata: " + p[1] + "\n\n"))
		if flusher != nil {
			flusher.Flush()
		}
	}
}

func TestSend_TextStream(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/v1/messages") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		sseEvents(w,
			[2]string{"message_start", `{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
			[2]string{"content_block_start", `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`},
			[2]string{"content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}`},
			[2]string{"content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}`},
			[2]string{"content_block_stop", `{"type":"content_block_stop","index":0}`},
			[2]string{"message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}`},
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	temp := 0.7
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-opus-4-7",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "You are helpful."},
			{Role: "user", Content: "Hi"},
		},
		Settings: providers.CallSettings{Temperature: &temp},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	got := drainChunks(t, ch)
	wantTypes := []providers.ChunkType{
		providers.ChunkText, providers.ChunkText, providers.ChunkUsage, providers.ChunkDone,
	}
	if len(got) != len(wantTypes) {
		t.Fatalf("got %d chunks, want %d: %+v", len(got), len(wantTypes), got)
	}
	for i, c := range got {
		if c.Type != wantTypes[i] {
			t.Errorf("chunk %d type=%q want %q", i, c.Type, wantTypes[i])
		}
	}

	// Verify text payloads concatenate to "Hello world".
	var text string
	for _, c := range got {
		if c.Type == providers.ChunkText {
			var p struct{ Text string }
			if err := json.Unmarshal(c.Payload, &p); err != nil {
				t.Fatalf("unmarshal payload: %v", err)
			}
			text += p.Text
		}
	}
	if text != "Hello world" {
		t.Errorf("assembled text=%q want %q", text, "Hello world")
	}
}

func TestSend_ThinkingAndToolUseStream(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		sseEvents(w,
			[2]string{"message_start", `{"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
			// Block 0: thinking
			[2]string{"content_block_start", `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`},
			[2]string{"content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reasoning..."}}`},
			[2]string{"content_block_stop", `{"type":"content_block_stop","index":0}`},
			// Block 1: tool_use
			[2]string{"content_block_start", `{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"calculator","input":{}}}`},
			[2]string{"content_block_delta", `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"x\":"}}`},
			[2]string{"content_block_delta", `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"42}"}}`},
			[2]string{"content_block_stop", `{"type":"content_block_stop","index":1}`},
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	enabled := true
	budget := 1024
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-opus-4-7",
		Messages: []providers.WireMessage{{Role: "user", Content: "compute"}},
		Settings: providers.CallSettings{ThinkingEnabled: &enabled, ThinkingBudgetTokens: &budget},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	got := drainChunks(t, ch)
	want := []providers.ChunkType{
		providers.ChunkThinking,
		providers.ChunkToolUseStart,
		providers.ChunkToolUseDelta,
		providers.ChunkToolUseDelta,
		providers.ChunkToolUseEnd,
		providers.ChunkUsage,
		providers.ChunkDone,
	}
	if len(got) != len(want) {
		t.Fatalf("got %d chunks, want %d: %+v", len(got), len(want), got)
	}
	for i, c := range got {
		if c.Type != want[i] {
			t.Errorf("chunk %d type=%q want %q", i, c.Type, want[i])
		}
	}

	// First tool_use_start payload has id+name.
	var startPayload struct{ ID, Name string }
	if err := json.Unmarshal(got[1].Payload, &startPayload); err != nil {
		t.Fatalf("unmarshal start payload: %v", err)
	}
	if startPayload.ID != "toolu_1" || startPayload.Name != "calculator" {
		t.Errorf("tool_use_start payload=%+v", startPayload)
	}

	// First tool_use_delta payload has partial_json fragment.
	var deltaPayload struct {
		PartialJSON string `json:"partial_json"`
	}
	if err := json.Unmarshal(got[2].Payload, &deltaPayload); err != nil {
		t.Fatalf("unmarshal delta payload: %v", err)
	}
	if deltaPayload.PartialJSON != `{"x":` {
		t.Errorf("partial_json=%q", deltaPayload.PartialJSON)
	}
}

func TestSend_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"upstream"}`, 503)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-opus-4-7",
		Messages: []providers.WireMessage{{Role: "user", Content: "x"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	got := drainChunks(t, ch)
	if len(got) != 1 || got[0].Type != providers.ChunkError {
		t.Fatalf("expected single error chunk, got %+v", got)
	}
	var p struct{ Message string }
	if err := json.Unmarshal(got[0].Payload, &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.Message == "" {
		t.Error("error chunk should have non-empty message")
	}
}

func TestSend_AssistantWithThinkingHistory(t *testing.T) {
	// Verify that an assistant turn carrying stored Thinking JSON is rendered
	// back into the request body as native ThinkingBlock + text. We snoop the
	// outbound request body in the handler.
	var bodyBytes []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf, _ := io.ReadAll(r.Body)
		bodyBytes = buf
		sseEvents(w,
			[2]string{"message_stop", `{"type":"message_stop"}`},
		)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	thinking := json.RawMessage(`[{"type":"thinking","thinking":"prior","signature":"sig"}]`)
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-opus-4-7",
		Messages: []providers.WireMessage{
			{Role: "user", Content: "Q1"},
			{Role: "assistant", Content: "A1", Thinking: thinking},
			{Role: "user", Content: "Q2"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	// Drain so the request actually completes before we inspect the body.
	for range ch {
	}

	body := string(bodyBytes)
	if !strings.Contains(body, `"signature":"sig"`) {
		t.Errorf("request body missing thinking signature, body=%s", body)
	}
	if !strings.Contains(body, `"thinking":"prior"`) {
		t.Errorf("request body missing thinking text, body=%s", body)
	}
}

// ---------------------------------------------------------------------
// CountTokens
// ---------------------------------------------------------------------

func TestCountTokens(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/v1/messages/count_tokens") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"input_tokens": 1234}`))
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	n, err := d.CountTokens(context.Background(), "claude-opus-4-7", []providers.WireMessage{
		{Role: "system", Content: "S"},
		{Role: "user", Content: "U"},
	})
	if err != nil {
		t.Fatalf("CountTokens: %v", err)
	}
	if n != 1234 {
		t.Errorf("got %d, want 1234", n)
	}
}

func TestCountTokens_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"x"}`, 500)
	}))
	defer srv.Close()

	d := newTestDriver(t, srv.URL, nil)

	if _, err := d.CountTokens(context.Background(), "claude-opus-4-7", nil); err == nil {
		t.Fatal("expected error")
	}
}

// ---------------------------------------------------------------------
// RenderThinkingToText
// ---------------------------------------------------------------------

func TestRenderThinkingToText(t *testing.T) {
	d := &Driver{}

	cases := []struct {
		name string
		in   json.RawMessage
		want string
	}{
		{"nil", nil, ""},
		{"empty", json.RawMessage(``), ""},
		{"empty-array", json.RawMessage(`[]`), ""},
		{"malformed", json.RawMessage(`{not json`), ""},
		{"single", json.RawMessage(`[{"type":"thinking","thinking":"hello","signature":"s"}]`), "hello"},
		{"multi", json.RawMessage(`[{"type":"thinking","thinking":"a","signature":"s1"},{"type":"thinking","thinking":"b","signature":"s2"}]`), "a\nb"},
		{"ignores-redacted", json.RawMessage(`[{"type":"redacted_thinking","data":"opaque"},{"type":"thinking","thinking":"visible","signature":"s"}]`), "visible"},
		{"unknown-type", json.RawMessage(`[{"type":"weird","thinking":"x"}]`), ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := d.RenderThinkingToText(tc.in)
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

func drainChunks(t *testing.T, ch <-chan providers.Chunk) []providers.Chunk {
	t.Helper()
	var out []providers.Chunk
	timeout := time.After(5 * time.Second)
	for {
		select {
		case c, ok := <-ch:
			if !ok {
				return out
			}
			out = append(out, c)
		case <-timeout:
			t.Fatal("timed out waiting for chunks")
		}
	}
}
