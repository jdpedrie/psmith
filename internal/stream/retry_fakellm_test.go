package stream

import (
	"context"
	"fmt"
	"log/slog"
	"testing"
	"time"

	"github.com/jdpedrie/reeve/fakellm"
	"github.com/jdpedrie/reeve/internal/providers"
	_ "github.com/jdpedrie/reeve/internal/providers/openai" // registers openai-compatible
)

// End-to-end retry tests using fakellm + the real openai-compatible
// driver. Round-trips the supervisor's retry helper through:
//
//	helper SendFunc closure
//	  → openai-compatible driver (auto-routes to chat-completions for
//	    non-api.openai.com base_urls — fakellm's localhost URL fits)
//	    → fakellm HTTP server
//
// Per the user's "fakellm can test this, combine with a fake clock to
// keep run time reasonable" guidance. `shrinkRetryConfigForTest`
// (defined in send_retry_test.go) is the fake-clock equivalent —
// shrinks production seconds to milliseconds so the loop completes
// near-instantly while still exercising real wall-clock waits.
//
// These tests cover what the in-process scriptedSend tests can't:
// SDK-level error parsing (provider envelopes, status code
// classification) and wire-format SSE handling.

// TestRetry_FakeLLM_RecoverFromTransient503: fakellm returns HTTP 503
// on the first attempt, then a normal completion on the second.
// openStreamWithRetry should pick that up — attempt 1 fails (503),
// 1ms backoff, attempt 2 succeeds.
func TestRetry_FakeLLM_RecoverFromTransient503(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 2*time.Second)

	fake := fakellm.NewServer(t, fakellm.FlavorOpenAIChat)
	fake.Enqueue(fakellm.Script{
		Error: &fakellm.ErrorSpec{
			HTTPStatus: 503,
			Code:       "service_unavailable",
			Message:    "upstream temporarily unavailable",
		},
	})
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "hello"}},
		Usage:  &fakellm.Usage{InputTokens: 4, OutputTokens: 1},
	})

	driver := mustBuildOpenAIChatDriver(t, fake.URL())
	sf := func(ctx context.Context) (<-chan providers.Chunk, error) {
		return driver.Send(ctx, providers.SendRequest{
			ModelID:  "gpt-fake",
			Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		})
	}

	res, err := openStreamWithRetry(context.Background(), sf, slog.Default())
	if err != nil {
		t.Fatalf("retry should have recovered; got %v", err)
	}
	defer res.cancel()

	merged := reinjectFirstChunk(res)
	var sawText bool
	for c := range merged {
		if c.Type == providers.ChunkText {
			sawText = true
		}
	}
	if !sawText {
		t.Error("expected at least one text chunk from the recovered stream")
	}
	if got := fake.QueueLen(); got != 0 {
		t.Errorf("fakellm queue should be drained; remaining=%d", got)
	}
}

// TestRetry_FakeLLM_AllAttemptsFail: every attempt gets 503. Helper
// exhausts retries; the openStreamWithRetry call returns an error so
// the supervisor falls through to syntheticErrorStream.
func TestRetry_FakeLLM_AllAttemptsFail(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 2*time.Second)

	fake := fakellm.NewServer(t, fakellm.FlavorOpenAIChat)
	for i := 0; i < 5; i++ {
		fake.Enqueue(fakellm.Script{
			Error: &fakellm.ErrorSpec{
				HTTPStatus: 503,
				Code:       "service_unavailable",
				Message:    "down for everything",
			},
		})
	}
	driver := mustBuildOpenAIChatDriver(t, fake.URL())
	sf := func(ctx context.Context) (<-chan providers.Chunk, error) {
		return driver.Send(ctx, providers.SendRequest{
			ModelID:  "gpt-fake",
			Messages: []providers.WireMessage{{Role: "user", Content: "hi"}},
		})
	}
	if _, err := openStreamWithRetry(context.Background(), sf, slog.Default()); err == nil {
		t.Fatal("expected error after all attempts failed")
	}
	// 3 attempts → 3 scripts consumed → 2 left in queue.
	if got := fake.QueueLen(); got != 2 {
		t.Errorf("expected 3 attempts to consume 3 scripts; %d left in queue", got)
	}
}

// mustBuildOpenAIChatDriver wires up the openai-compatible driver
// pointed at fakellm. Auto-routes to chat-completions because fakellm's
// localhost URL doesn't match `api.openai.com` (per the routing rule
// in `openai.resolveChatCompletions`).
func mustBuildOpenAIChatDriver(t *testing.T, baseURL string) providers.StatelessProvider {
	t.Helper()
	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, baseURL+"/v1"))
	d, err := providers.Build("openai-compatible", providers.Deps{Logger: slog.Default()}, cfg)
	if err != nil {
		t.Fatalf("Build openai-compatible: %v", err)
	}
	stateless, ok := d.(providers.StatelessProvider)
	if !ok {
		t.Fatal("driver is not StatelessProvider")
	}
	return stateless
}
