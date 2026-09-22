package anthropic

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/jdpedrie/psmith/server/providers"
)

// happySSE serves a minimal successful text stream.
func happySSE(w http.ResponseWriter) {
	sseEvents(w,
		[2]string{"message_start", `{"type":"message_start","message":{"id":"msg_t","type":"message","role":"assistant","content":[],"model":"m","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0},"service_tier":"standard"}}}`},
		[2]string{"content_block_start", `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`},
		[2]string{"content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}`},
		[2]string{"content_block_stop", `{"type":"content_block_stop","index":0}`},
		[2]string{"message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}`},
		[2]string{"message_stop", `{"type":"message_stop"}`},
	)
}

// thinkingBody is the subset of the request body these tests inspect.
type thinkingBody struct {
	MaxTokens   int64 `json:"max_tokens"`
	Temperature *float64 `json:"temperature"`
	Thinking    *struct {
		Type         string `json:"type"`
		BudgetTokens *int   `json:"budget_tokens"`
	} `json:"thinking"`
	OutputConfig *struct {
		Effort string `json:"effort"`
	} `json:"output_config"`
}

// captureServer records each /v1/messages request body and responds per
// the supplied handler (indexed by request ordinal).
func captureServer(t *testing.T, respond func(n int, w http.ResponseWriter)) (*httptest.Server, func() []thinkingBody) {
	t.Helper()
	var mu sync.Mutex
	var bodies []thinkingBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b thinkingBody
		_ = json.NewDecoder(r.Body).Decode(&b)
		mu.Lock()
		bodies = append(bodies, b)
		n := len(bodies)
		mu.Unlock()
		respond(n, w)
	}))
	return srv, func() []thinkingBody {
		mu.Lock()
		defer mu.Unlock()
		return append([]thinkingBody(nil), bodies...)
	}
}

func thinkingSettings(effort providers.ThinkingEffort) providers.CallSettings {
	return providers.CallSettings{Thinking: &providers.ThinkingSettings{Effort: effort}}
}

func TestSend_AdaptiveThinkingBody(t *testing.T) {
	srv, bodies := captureServer(t, func(_ int, w http.ResponseWriter) { happySSE(w) })
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-fable-5",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: thinkingSettings(providers.ThinkingEffortHigh),
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	drainChunks(t, ch)

	got := bodies()
	if len(got) != 1 {
		t.Fatalf("want 1 request, got %d", len(got))
	}
	b := got[0]
	if b.Thinking == nil || b.Thinking.Type != "adaptive" {
		t.Errorf("thinking = %+v, want type adaptive", b.Thinking)
	}
	if b.Thinking != nil && b.Thinking.BudgetTokens != nil {
		t.Errorf("adaptive shape must not carry budget_tokens, got %d", *b.Thinking.BudgetTokens)
	}
	if b.OutputConfig == nil || b.OutputConfig.Effort != "high" {
		t.Errorf("output_config = %+v, want the level passed through as effort high", b.OutputConfig)
	}
}

// OFF sends no thinking configuration at all, on either generation: the
// model's own default applies, which is what "off" meant before too.
func TestSend_ThinkingOff_OmitsThinkingConfig(t *testing.T) {
	for _, model := range []string{"claude-sonnet-5", "claude-haiku-4-5"} {
		srv, bodies := captureServer(t, func(_ int, w http.ResponseWriter) { happySSE(w) })
		d := newTestDriver(t, srv.URL, nil)

		ch, err := d.Send(context.Background(), providers.SendRequest{
			ModelID:  model,
			Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
			Settings: thinkingSettings(providers.ThinkingEffortOff),
		})
		if err != nil {
			t.Fatalf("%s: Send: %v", model, err)
		}
		drainChunks(t, ch)
		srv.Close()

		got := bodies()
		if len(got) != 1 {
			t.Fatalf("%s: want 1 request, got %d", model, len(got))
		}
		if got[0].Thinking != nil || got[0].OutputConfig != nil {
			t.Errorf("%s: off must omit thinking and output_config, got thinking=%+v output_config=%+v", model, got[0].Thinking, got[0].OutputConfig)
		}
	}
}

func TestSend_LegacyThinkingBody(t *testing.T) {
	srv, bodies := captureServer(t, func(_ int, w http.ResponseWriter) { happySSE(w) })
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-haiku-4-5",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: thinkingSettings(providers.ThinkingEffortHigh),
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	drainChunks(t, ch)

	got := bodies()
	if len(got) != 1 {
		t.Fatalf("want 1 request, got %d", len(got))
	}
	b := got[0]
	if b.Thinking == nil || b.Thinking.Type != "enabled" {
		t.Errorf("thinking = %+v, want type enabled", b.Thinking)
	}
	if b.Thinking != nil && (b.Thinking.BudgetTokens == nil || *b.Thinking.BudgetTokens != 16384) {
		t.Errorf("legacy shape should carry the high-effort budget of 16384, got %+v", b.Thinking)
	}
	// The budget is charged against max_tokens, so it rides on top of the
	// default output allowance rather than eating into it.
	if b.MaxTokens != 4096+16384 {
		t.Errorf("max_tokens = %d, want the 4096 default plus the 16384 budget", b.MaxTokens)
	}
	if b.OutputConfig != nil {
		t.Errorf("legacy shape must not carry output_config, got %+v", b.OutputConfig)
	}
}

// A model missing from the adaptive prefix table that rejects the legacy
// shape gets exactly one retry with the adaptive shape, invisibly to the
// consumer.
func TestSend_ThinkingShapeRetry_EnabledToAdaptive(t *testing.T) {
	srv, bodies := captureServer(t, func(n int, w http.ResponseWriter) {
		if n == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"thinking_type.enabled is not supported for this model. use thinking_type.adaptive and output_config.effort to control thinking behavior"}}`))
			return
		}
		happySSE(w)
	})
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-mystery-9", // not in the adaptive prefix table
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: thinkingSettings(providers.ThinkingEffortXHigh),
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	chunks := drainChunks(t, ch)
	for _, c := range chunks {
		if c.Type == providers.ChunkError {
			t.Fatalf("retry should hide the shape error, got error chunk: %s", c.Payload)
		}
	}

	got := bodies()
	if len(got) != 2 {
		t.Fatalf("want 2 requests (legacy then adaptive), got %d", len(got))
	}
	if got[0].Thinking == nil || got[0].Thinking.Type != "enabled" {
		t.Errorf("first attempt should be legacy, got %+v", got[0].Thinking)
	}
	if got[1].Thinking == nil || got[1].Thinking.Type != "adaptive" {
		t.Errorf("retry should be adaptive, got %+v", got[1].Thinking)
	}
	if got[1].OutputConfig == nil || got[1].OutputConfig.Effort != "xhigh" {
		t.Errorf("retry should carry the requested level through as effort xhigh, got %+v", got[1].OutputConfig)
	}
}

// The reverse direction: a model the table wrongly claims is adaptive
// falls back to the legacy shape when the API rejects the adaptive tag.
func TestSend_ThinkingShapeRetry_AdaptiveToEnabled(t *testing.T) {
	srv, bodies := captureServer(t, func(n int, w http.ResponseWriter) {
		if n == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"thinking: Input tag 'adaptive' found using 'type' does not match any of the expected tags: 'enabled', 'disabled'"}}`))
			return
		}
		happySSE(w)
	})
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-sonnet-4-6", // in the adaptive table
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: thinkingSettings(providers.ThinkingEffortHigh),
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	chunks := drainChunks(t, ch)
	for _, c := range chunks {
		if c.Type == providers.ChunkError {
			t.Fatalf("retry should hide the shape error, got error chunk: %s", c.Payload)
		}
	}

	got := bodies()
	if len(got) != 2 {
		t.Fatalf("want 2 requests (adaptive then legacy), got %d", len(got))
	}
	if got[0].Thinking == nil || got[0].Thinking.Type != "adaptive" {
		t.Errorf("first attempt should be adaptive, got %+v", got[0].Thinking)
	}
	if got[1].Thinking == nil || got[1].Thinking.Type != "enabled" {
		t.Errorf("retry should be legacy enabled, got %+v", got[1].Thinking)
	}
}

// Unrelated 400s surface as an error chunk after a single request — the
// flip retry is reserved for the thinking-shape mismatch.
func TestSend_ThinkingUnrelatedErrorNoRetry(t *testing.T) {
	srv, bodies := captureServer(t, func(_ int, w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens is too large"}}`))
	})
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-haiku-4-5",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: thinkingSettings(providers.ThinkingEffortHigh),
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	chunks := drainChunks(t, ch)
	if len(chunks) != 1 || chunks[0].Type != providers.ChunkError {
		t.Fatalf("want a single error chunk, got %+v", chunks)
	}
	if got := bodies(); len(got) != 1 {
		t.Errorf("unrelated error must not retry, got %d requests", len(got))
	}
}

func TestIsThinkingShapeError(t *testing.T) {
	yes := []string{
		"400: thinking_type.enabled is not supported for this model. use thinking_type.adaptive and output_config.effort to control thinking behavior",
		"thinking: Input tag 'adaptive' found using 'type' does not match any of the expected tags",
		"output_config: Extra inputs are not permitted",
	}
	for _, m := range yes {
		if !isThinkingShapeError(errors.New(m)) {
			t.Errorf("should match: %q", m)
		}
	}
	no := []string{
		"max_tokens is too large",
		"overloaded_error: Overloaded",
		"invalid x-api-key",
	}
	for _, m := range no {
		if isThinkingShapeError(errors.New(m)) {
			t.Errorf("should NOT match: %q", m)
		}
	}
	if isThinkingShapeError(nil) {
		t.Error("nil is not a shape error")
	}
}

// Adaptive-generation models lock temperature at 1.0; the driver must
// omit an explicit temperature rather than forward a value the API will
// reject. Older models keep passing it through.
func TestSend_TemperatureOmittedWhenLocked(t *testing.T) {
	srv, bodies := captureServer(t, func(_ int, w http.ResponseWriter) { happySSE(w) })
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	temp := 0.7
	for _, model := range []string{"claude-fable-5", "claude-opus-4-7", "claude-haiku-4-5"} {
		ch, err := d.Send(context.Background(), providers.SendRequest{
			ModelID:  model,
			Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
			Settings: providers.CallSettings{Temperature: &temp},
		})
		if err != nil {
			t.Fatalf("Send(%s): %v", model, err)
		}
		drainChunks(t, ch)
	}

	got := bodies()
	if len(got) != 3 {
		t.Fatalf("want 3 requests, got %d", len(got))
	}
	if got[0].Temperature != nil {
		t.Errorf("fable-5 is temperature-locked; body carried %v", *got[0].Temperature)
	}
	if got[1].Temperature != nil {
		t.Errorf("opus-4-7 is temperature-locked; body carried %v", *got[1].Temperature)
	}
	if got[2].Temperature == nil || *got[2].Temperature != 0.7 {
		t.Errorf("haiku-4-5 should pass temperature through, got %+v", got[2].Temperature)
	}
}

// A model the constraints table doesn't know that rejects an explicit
// temperature gets one retry with the sampling knobs stripped.
func TestSend_SamplingConstraintRetry(t *testing.T) {
	srv, bodies := captureServer(t, func(n int, w http.ResponseWriter) {
		if n == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"temperature may only be set to 1 for this model"}}`))
			return
		}
		happySSE(w)
	})
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	temp := 0.3
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-mystery-9",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: providers.CallSettings{Temperature: &temp},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	chunks := drainChunks(t, ch)
	for _, c := range chunks {
		if c.Type == providers.ChunkError {
			t.Fatalf("retry should hide the constraint error, got: %s", c.Payload)
		}
	}

	got := bodies()
	if len(got) != 2 {
		t.Fatalf("want 2 requests, got %d", len(got))
	}
	if got[0].Temperature == nil {
		t.Error("first attempt should carry the explicit temperature")
	}
	if got[1].Temperature != nil {
		t.Errorf("retry should omit temperature, got %v", *got[1].Temperature)
	}
}

// Both remedies compose: a fully unknown adaptive-generation model that
// rejects the thinking shape and then the temperature recovers in three
// requests, invisibly.
func TestSend_ThinkingAndSamplingRemediesCompose(t *testing.T) {
	srv, bodies := captureServer(t, func(n int, w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		switch n {
		case 1:
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"thinking_type.enabled is not supported for this model. use thinking_type.adaptive and output_config.effort to control thinking behavior"}}`))
		case 2:
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"temperature may only be set to 1 for this model"}}`))
		default:
			happySSE(w)
		}
	})
	defer srv.Close()
	d := newTestDriver(t, srv.URL, nil)

	temp := 0.5
	settings := thinkingSettings(providers.ThinkingEffortHigh)
	settings.Temperature = &temp
	ch, err := d.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-mystery-9",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		Settings: settings,
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	chunks := drainChunks(t, ch)
	for _, c := range chunks {
		if c.Type == providers.ChunkError {
			t.Fatalf("remedies should hide both errors, got: %s", c.Payload)
		}
	}

	got := bodies()
	if len(got) != 3 {
		t.Fatalf("want 3 requests (legacy, adaptive, adaptive sans sampling), got %d", len(got))
	}
	final := got[2]
	if final.Thinking == nil || final.Thinking.Type != "adaptive" {
		t.Errorf("final attempt should keep the adaptive flip, got %+v", final.Thinking)
	}
	if final.Temperature != nil {
		t.Errorf("final attempt should omit temperature, got %v", *final.Temperature)
	}
}

func TestIsSamplingConstraintError(t *testing.T) {
	yes := []string{
		"temperature may only be set to 1 for this model",
		"400: unsupported parameter: top_p",
		"top_k is not supported for this model",
		"invalid value for temperature",
	}
	for _, m := range yes {
		if !isSamplingConstraintError(errors.New(m)) {
			t.Errorf("should match: %q", m)
		}
	}
	no := []string{
		"overloaded_error: Overloaded",
		"max_tokens is too large",
		"the temperature in the room is pleasant", // names the knob, no rejection wording
	}
	for _, m := range no {
		if isSamplingConstraintError(errors.New(m)) {
			t.Errorf("should NOT match: %q", m)
		}
	}
}
