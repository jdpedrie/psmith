package google

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
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
