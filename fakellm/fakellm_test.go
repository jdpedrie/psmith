package fakellm_test

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"testing"

	"github.com/jdpedrie/psmith/fakellm"
	"github.com/jdpedrie/psmith/internal/providers"
	_ "github.com/jdpedrie/psmith/internal/providers/anthropic" // registers driver
	"github.com/jdpedrie/psmith/internal/providers/openai"      // registers openai-compatible driver
)

// TestAnthropicRoundTrip drives the real Anthropic driver against the fake
// server. The driver should parse the SSE stream into the normalized chunk
// vocabulary, including the terminal usage chunk and the request body should
// reflect what the SDK serialized.
func TestAnthropicRoundTrip(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "Hello, "},
			{Type: fakellm.EventText, Text: "world!"},
		},
		Usage: &fakellm.Usage{InputTokens: 12, OutputTokens: 5, CacheReadTokens: 3},
	})

	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, fake.URL()))
	driver, err := providers.Build("anthropic", providers.Deps{Logger: slog.Default()}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		t.Fatal("anthropic driver is not StatelessProvider")
	}

	ch, err := stateless.Send(context.Background(), providers.SendRequest{
		ModelID: "claude-fake",
		Messages: []providers.WireMessage{
			{Role: "user", Content: "hi"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var (
		text     string
		gotUsage providers.Usage
		sawDone  bool
		sawError bool
	)
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct{ Text string }
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		case providers.ChunkUsage:
			_ = json.Unmarshal(c.Payload, &gotUsage)
		case providers.ChunkDone:
			sawDone = true
		case providers.ChunkError:
			sawError = true
			t.Logf("error chunk: %s", string(c.Payload))
		}
	}

	if sawError {
		t.Fatal("unexpected error chunk")
	}
	if !sawDone {
		t.Error("expected ChunkDone")
	}
	if text != "Hello, world!" {
		t.Errorf("text=%q want %q", text, "Hello, world!")
	}
	if gotUsage.InputTokens == nil || *gotUsage.InputTokens != 12 {
		t.Errorf("input_tokens: %+v want 12", gotUsage.InputTokens)
	}
	if gotUsage.OutputTokens == nil || *gotUsage.OutputTokens != 5 {
		t.Errorf("output_tokens: %+v want 5", gotUsage.OutputTokens)
	}
	if gotUsage.CacheReadTokens == nil || *gotUsage.CacheReadTokens != 3 {
		t.Errorf("cache_read_tokens: %+v want 3", gotUsage.CacheReadTokens)
	}

	// The driver should have made one POST to /v1/messages with the model
	// + user message in the body, and an Authorization-or-x-api-key header.
	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("got %d requests, want 1", len(reqs))
	}
	r := reqs[0]
	if r.Method != "POST" {
		t.Errorf("method=%q want POST", r.Method)
	}
	var body map[string]any
	if err := json.Unmarshal(r.Body, &body); err != nil {
		t.Fatalf("body unmarshal: %v (body=%s)", err, r.Body)
	}
	if body["model"] != "claude-fake" {
		t.Errorf("model=%v want claude-fake", body["model"])
	}
	msgs, _ := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages len=%d want 1", len(msgs))
	}
}

// TestAnthropicRoundTrip_ThinkingBlock confirms thinking deltas round-trip
// through the SDK as the thinking_delta event type.
func TestAnthropicRoundTrip_ThinkingBlock(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventThinking, Text: "Let me consider..."},
			{Type: fakellm.EventText, Text: "Here is my answer."},
		},
	})

	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, fake.URL()))
	driver, _ := providers.Build("anthropic", providers.Deps{Logger: slog.Default()}, cfg)
	stateless := driver.(providers.StatelessProvider)
	ch, err := stateless.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-fake",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var (
		text, thinking string
	)
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct{ Text string }
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		case providers.ChunkThinking:
			var p struct{ Text string }
			_ = json.Unmarshal(c.Payload, &p)
			thinking += p.Text
		}
	}
	if thinking != "Let me consider..." {
		t.Errorf("thinking=%q want %q", thinking, "Let me consider...")
	}
	if text != "Here is my answer." {
		t.Errorf("text=%q want %q", text, "Here is my answer.")
	}
}

// TestAnthropicRoundTrip_HTTPError surfaces transport errors via the driver's
// error chunk.
func TestAnthropicRoundTrip_HTTPError(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Error: &fakellm.ErrorSpec{
			HTTPStatus: 429,
			Code:       "rate_limit_error",
			Message:    "slow down",
		},
	})

	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, fake.URL()))
	driver, _ := providers.Build("anthropic", providers.Deps{Logger: slog.Default()}, cfg)
	stateless := driver.(providers.StatelessProvider)
	ch, err := stateless.Send(context.Background(), providers.SendRequest{
		ModelID:  "claude-fake",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		// The SDK may return the HTTP error eagerly via Send rather than
		// through the channel. Either path is acceptable; assert one.
		if !containsAll(err.Error(), "429") {
			t.Errorf("Send error %v should mention 429", err)
		}
		return
	}

	var sawError bool
	for c := range ch {
		if c.Type == providers.ChunkError {
			sawError = true
		}
	}
	if !sawError {
		t.Error("expected ChunkError for 429 transport failure")
	}
}

// TestOpenAIChatRoundTrip drives the openai-compatible driver in
// chat-completions mode against the fake server.
func TestOpenAIChatRoundTrip(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorOpenAIChat)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "Hello, "},
			{Type: fakellm.EventText, Text: "world!"},
		},
		Usage: &fakellm.Usage{InputTokens: 10, OutputTokens: 4},
	})

	cfg := []byte(fmt.Sprintf(
		`{"api_key":"x","base_url":%q,"use_chat_completions":true}`, fake.URL()+"/v1"))
	driver, err := providers.Build("openai-compatible", providers.Deps{Logger: slog.Default()}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	stateless := driver.(providers.StatelessProvider)
	ch, err := stateless.Send(context.Background(), providers.SendRequest{
		ModelID:  "gpt-fake",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var (
		text     string
		gotUsage providers.Usage
		sawDone  bool
	)
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct{ Text string }
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		case providers.ChunkUsage:
			_ = json.Unmarshal(c.Payload, &gotUsage)
		case providers.ChunkDone:
			sawDone = true
		case providers.ChunkError:
			t.Logf("error chunk: %s", string(c.Payload))
		}
	}
	if !sawDone {
		t.Error("expected ChunkDone")
	}
	if text != "Hello, world!" {
		t.Errorf("text=%q want %q", text, "Hello, world!")
	}
	if gotUsage.InputTokens == nil || *gotUsage.InputTokens != 10 {
		t.Errorf("input_tokens=%+v want 10", gotUsage.InputTokens)
	}
	if gotUsage.OutputTokens == nil || *gotUsage.OutputTokens != 4 {
		t.Errorf("output_tokens=%+v want 4", gotUsage.OutputTokens)
	}

	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("requests=%d want 1", len(reqs))
	}
	if reqs[0].Path != "/v1/chat/completions" {
		t.Errorf("path=%q want /v1/chat/completions", reqs[0].Path)
	}
}

// TestOpenAIResponsesRoundTrip drives the openai-compatible driver in
// Responses-API mode (the default) against the fake server.
func TestOpenAIResponsesRoundTrip(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorOpenAIResponses)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "Hello, "},
			{Type: fakellm.EventText, Text: "world!"},
		},
		Usage: &fakellm.Usage{InputTokens: 7, OutputTokens: 3, ReasoningTokens: 2},
	})

	// Force Responses-API routing — this test asserts the Responses path
	// works end-to-end. Default routing (chat-completions for non-OpenAI
	// base URLs) would otherwise route this through chat-completions, and
	// the new routing rule ignores stored use_chat_completions=false on
	// non-OpenAI URLs (it's stale data from when the field defaulted to
	// false). The driver exposes a test-only escape hatch to flip the
	// flag after construction.
	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, fake.URL()+"/v1"))
	driver, err := providers.Build("openai-compatible", providers.Deps{Logger: slog.Default()}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	openai.ForceResponsesAPIForTest(driver)
	stateless := driver.(providers.StatelessProvider)
	ch, err := stateless.Send(context.Background(), providers.SendRequest{
		ModelID:  "gpt-fake",
		Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var (
		text     string
		gotUsage providers.Usage
		sawDone  bool
	)
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct{ Text string }
			_ = json.Unmarshal(c.Payload, &p)
			text += p.Text
		case providers.ChunkUsage:
			_ = json.Unmarshal(c.Payload, &gotUsage)
		case providers.ChunkDone:
			sawDone = true
		case providers.ChunkError:
			t.Logf("error chunk: %s", string(c.Payload))
		}
	}
	if !sawDone {
		t.Error("expected ChunkDone")
	}
	if text != "Hello, world!" {
		t.Errorf("text=%q want %q", text, "Hello, world!")
	}
	if gotUsage.InputTokens == nil || *gotUsage.InputTokens != 7 {
		t.Errorf("input_tokens=%+v want 7", gotUsage.InputTokens)
	}
	if gotUsage.OutputTokens == nil || *gotUsage.OutputTokens != 3 {
		t.Errorf("output_tokens=%+v want 3", gotUsage.OutputTokens)
	}
	if gotUsage.ReasoningTokens == nil || *gotUsage.ReasoningTokens != 2 {
		t.Errorf("reasoning_tokens=%+v want 2", gotUsage.ReasoningTokens)
	}

	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("requests=%d want 1", len(reqs))
	}
	if reqs[0].Path != "/v1/responses" {
		t.Errorf("path=%q want /v1/responses", reqs[0].Path)
	}
}

func containsAll(s string, subs ...string) bool {
	for _, sub := range subs {
		found := false
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
