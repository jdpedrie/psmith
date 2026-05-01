package google

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/providers"
)

// TestLive_Send is a smoke test that hits the real Gemini API. It runs only
// when GOOGLE_API_KEY is set, so CI/normal `go test ./...` skips it. Useful
// for end-to-end verification of the SSE parser and request shape against
// the live endpoint.
//
// Run with:
//
//	GOOGLE_API_KEY=... go test -run TestLive_Send -v ./internal/providers/google/
func TestLive_Send(t *testing.T) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		t.Skip("GOOGLE_API_KEY not set; skipping live test")
	}

	cfg := Config{APIKey: apiKey}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	ch, err := p.(providers.StatelessProvider).Send(ctx, providers.SendRequest{
		ModelID: "gemini-2.5-flash",
		Messages: []providers.WireMessage{
			{Role: "system", Content: "Reply in one short sentence."},
			{Role: "user", Content: "What is the capital of France?"},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var assembled string
	var sawDone bool
	var usage *providers.Usage
	var sawError bool
	var errMessage string

	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			assembled += p.Text
			fmt.Printf("[text] %s", p.Text)
		case providers.ChunkThinking:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			fmt.Printf("[thinking] %s\n", p.Text)
		case providers.ChunkUsage:
			var u providers.Usage
			if err := json.Unmarshal(c.Payload, &u); err == nil {
				usage = &u
			}
		case providers.ChunkError:
			sawError = true
			var p struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			errMessage = p.Message
			fmt.Printf("[error] %s\n", p.Message)
		case providers.ChunkDone:
			sawDone = true
		}
	}
	fmt.Println()

	if sawError {
		t.Fatalf("got ChunkError: %s", errMessage)
	}
	if !sawDone {
		t.Error("expected ChunkDone")
	}
	if assembled == "" {
		t.Error("expected non-empty text")
	}
	if usage == nil {
		t.Error("expected ChunkUsage")
	} else {
		fmt.Printf("usage: in=%v out=%v cache_read=%v reasoning=%v\n",
			derefIntPtr(usage.InputTokens),
			derefIntPtr(usage.OutputTokens),
			derefIntPtr(usage.CacheReadTokens),
			derefIntPtr(usage.ReasoningTokens))
	}
	fmt.Printf("assembled response: %q\n", assembled)
}

// TestLive_Discover hits the real /models endpoint.
func TestLive_Discover(t *testing.T) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		t.Skip("GOOGLE_API_KEY not set; skipping live test")
	}

	cfg := Config{APIKey: apiKey}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	models, err := p.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) == 0 {
		t.Fatal("expected non-empty models list")
	}
	fmt.Printf("discovered %d models:\n", len(models))
	for _, m := range models[:min(5, len(models))] {
		fmt.Printf("  - %s (%s)\n", m.ID, m.DisplayName)
	}
}

// TestLive_CountTokens hits the real /countTokens endpoint.
func TestLive_CountTokens(t *testing.T) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		t.Skip("GOOGLE_API_KEY not set; skipping live test")
	}

	cfg := Config{APIKey: apiKey}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	n, err := p.(providers.TokenCounter).CountTokens(context.Background(),
		"gemini-2.5-flash",
		[]providers.WireMessage{
			{Role: "user", Content: "Hello, world!"},
		})
	if err != nil {
		t.Fatalf("CountTokens: %v", err)
	}
	if n <= 0 {
		t.Errorf("expected positive token count, got %d", n)
	}
	fmt.Printf("countTokens: %d\n", n)
}

func derefIntPtr(p *int) any {
	if p == nil {
		return "(nil)"
	}
	return *p
}

// TestLive_ExplicitCaching exercises the cachedContents lifecycle end-to-end
// against the real Gemini API:
//
//  1. Create a cache with a deliberately large system_instruction (Gemini
//     enforces a per-model minimum — 4096 tokens on 2.5-flash; below the
//     floor the create call fails with INVALID_ARGUMENT).
//  2. Send a generation referencing the cache via CallSettings.Google.CachedContent.
//  3. Assert usageMetadata.cachedContentTokenCount > 0 — proof that the
//     prefix was reused, not re-billed.
//  4. Delete the cache to reclaim storage ahead of TTL.
//
// Skipped unless GOOGLE_API_KEY is set; runs as part of the live smoke
// suite.
func TestLive_ExplicitCaching(t *testing.T) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		t.Skip("GOOGLE_API_KEY not set; skipping live test")
	}

	cfg := Config{APIKey: apiKey}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	d := p.(*Driver)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// Build a system_instruction large enough to clear the per-model
	// minimum. ~10k characters of varied text comfortably exceeds the
	// 4096-token floor on gemini-2.5-flash.
	const modelID = "gemini-2.5-flash"
	bigSystem := buildLargeSystemPrompt()

	cc, err := d.CreateCachedContent(ctx, CreateCachedContentRequest{
		ModelID:           modelID,
		DisplayName:       "clark-live-test",
		SystemInstruction: bigSystem,
		TTL:               "300s",
	})
	if err != nil {
		t.Fatalf("CreateCachedContent: %v", err)
	}
	fmt.Printf("created cache: name=%s tokens=%v\n",
		cc.Name,
		func() any {
			if cc.UsageMetadata == nil {
				return "(nil)"
			}
			return cc.UsageMetadata.TotalTokenCount
		}())

	// Always clean up the cache, even on later failures — leaving these
	// around runs up storage cost and is hard to find later.
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := d.DeleteCachedContent(ctx, cc.Name); err != nil {
			t.Logf("DeleteCachedContent (cleanup): %v", err)
		}
	})

	if cc.Name == "" {
		t.Fatal("created cache has empty name")
	}

	// Roundtrip Get to confirm it's queryable.
	got, err := d.GetCachedContent(ctx, cc.Name)
	if err != nil {
		t.Fatalf("GetCachedContent: %v", err)
	}
	if got.Name != cc.Name {
		t.Errorf("get name=%q want %q", got.Name, cc.Name)
	}

	// Send a generation referencing the cache.
	cacheRef := cc.Name
	ch, err := d.Send(ctx, providers.SendRequest{
		ModelID:  modelID,
		Messages: []providers.WireMessage{{Role: "user", Content: "Reply with just the word OK."}},
		Settings: providers.CallSettings{
			Google: &providers.GoogleExtras{CachedContent: &cacheRef},
		},
	})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}

	var assembled string
	var usage *providers.Usage
	var sawError bool
	var errMessage string
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			assembled += p.Text
		case providers.ChunkUsage:
			var u providers.Usage
			if err := json.Unmarshal(c.Payload, &u); err == nil {
				usage = &u
			}
		case providers.ChunkError:
			sawError = true
			var p struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			errMessage = p.Message
		}
	}

	if sawError {
		t.Fatalf("got ChunkError: %s", errMessage)
	}
	if assembled == "" {
		t.Error("expected non-empty text")
	}
	if usage == nil {
		t.Fatal("expected ChunkUsage")
	}
	fmt.Printf("usage: in=%v out=%v cache_read=%v\n",
		derefIntPtr(usage.InputTokens),
		derefIntPtr(usage.OutputTokens),
		derefIntPtr(usage.CacheReadTokens))

	if usage.CacheReadTokens == nil || *usage.CacheReadTokens == 0 {
		t.Errorf("expected cache_read_tokens > 0 when referencing cached_content; got %v",
			usage.CacheReadTokens)
	}
}

// TestLive_ImplicitCaching verifies Gemini's implicit cache fires when the
// same large prefix is sent on consecutive turns:
//
//  1. Send a turn with a large stable system_instruction. First call: no
//     cache hit (cachedContentTokenCount may be zero).
//  2. Send the SAME prefix immediately. Gemini's implicit cache should
//     pick it up — usageMetadata.cachedContentTokenCount > 0.
//
// Implicit caching is server-controlled and best-effort, so the assert
// is on the second call only. Per Gemini docs, implicit caching has
// minimum-prefix sizes (1024 tokens on 2.5-flash, 4096 on 2.5-pro); the
// shared buildLargeSystemPrompt clears both.
//
// To make implicit caching deterministic across runs, the user-turn text
// is also fixed — Gemini hashes the entire prefix (system + history) up
// to the cache boundary.
func TestLive_ImplicitCaching(t *testing.T) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		t.Skip("GOOGLE_API_KEY not set; skipping live test")
	}

	cfg := Config{APIKey: apiKey}
	raw, _ := json.Marshal(cfg)
	p, err := New(providers.Deps{}, raw)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	d := p.(*Driver)

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	const modelID = "gemini-2.5-flash"
	bigSystem := buildLargeSystemPrompt()

	// Run the same call twice. Second call should hit implicit cache.
	send := func(label string) *providers.Usage {
		ch, err := d.Send(ctx, providers.SendRequest{
			ModelID: modelID,
			Messages: []providers.WireMessage{
				{Role: "system", Content: bigSystem},
				{Role: "user", Content: "Reply with exactly the word OK."},
			},
		})
		if err != nil {
			t.Fatalf("[%s] Send: %v", label, err)
		}
		var usage *providers.Usage
		var sawError bool
		var errMessage string
		for c := range ch {
			switch c.Type {
			case providers.ChunkUsage:
				var u providers.Usage
				if err := json.Unmarshal(c.Payload, &u); err == nil {
					usage = &u
				}
			case providers.ChunkError:
				sawError = true
				var p struct {
					Message string `json:"message"`
				}
				_ = json.Unmarshal(c.Payload, &p)
				errMessage = p.Message
			}
		}
		if sawError {
			t.Fatalf("[%s] got ChunkError: %s", label, errMessage)
		}
		if usage == nil {
			t.Fatalf("[%s] expected ChunkUsage", label)
		}
		fmt.Printf("[%s] in=%v out=%v cache_read=%v\n",
			label,
			derefIntPtr(usage.InputTokens),
			derefIntPtr(usage.OutputTokens),
			derefIntPtr(usage.CacheReadTokens))
		return usage
	}

	first := send("first")
	second := send("second")

	// First call: implicit cache may or may not have a hit (e.g. if a
	// recent unrelated test seeded the same prefix). Don't assert.
	_ = first

	// Second call: must show a cache_read. If this fails consistently
	// against a quiet account the model probably raised the implicit
	// minimum — bump buildLargeSystemPrompt's size.
	if second.CacheReadTokens == nil || *second.CacheReadTokens == 0 {
		t.Errorf("expected cache_read_tokens > 0 on second call (implicit cache); got %v",
			second.CacheReadTokens)
	}
}

// buildLargeSystemPrompt returns a deterministic chunk of text big enough
// to satisfy Gemini's minimum cacheable size on gemini-2.5-flash (4096
// tokens ≈ 16k–20k chars of English). We pad with a repeating but
// non-trivial paragraph rather than random bytes so the prefix is stable
// across runs (helps if Gemini ever reuses the same cache by content
// hash).
func buildLargeSystemPrompt() string {
	const paragraph = `You are a concise assistant. Respond only with what was asked, in the fewest words possible. ` +
		`Do not add disclaimers, follow-up questions, or commentary. Treat every prompt literally. ` +
		`When the user asks for a single word, reply with exactly that word and nothing else. ` +
		`When the user asks for a number, reply with the digits only. When the user asks a yes/no question, ` +
		`reply with "yes" or "no" — lowercase, no punctuation. `
	var b strings.Builder
	for b.Len() < 24*1024 {
		b.WriteString(paragraph)
	}
	return b.String()
}
