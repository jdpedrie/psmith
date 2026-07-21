package conversations

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/psmith/internal/providers"
)

// scriptedProvider plays back one scripted chunk sequence per Send
// call and records every request it received, so tests can assert
// both the downstream chunk stream and the continuation context the
// wrapper constructed. textChunk / usageChunk / doneChunk helpers are
// shared with the send/compact test files.
type scriptedProvider struct {
	// Interface embedding for conformance; continuationSendFunc only
	// ever calls Send, so the nil embed's other methods are never hit.
	providers.StatelessProvider
	legs     [][]providers.Chunk
	requests []providers.SendRequest
}

func (p *scriptedProvider) Send(ctx context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	p.requests = append(p.requests, req)
	idx := len(p.requests) - 1
	ch := make(chan providers.Chunk, 32)
	go func() {
		defer close(ch)
		if idx >= len(p.legs) {
			return
		}
		for _, c := range p.legs[idx] {
			ch <- c
		}
	}()
	return ch, nil
}


// collect drains the wrapper's output and reconstructs the effective
// text the way consume.go does: concatenate text deltas, reset on
// ChunkContentReset.
func collect(t *testing.T, src <-chan providers.Chunk) (effective string, raw string, resets int, dones int) {
	t.Helper()
	var eff, all strings.Builder
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ch, ok := <-src:
			if !ok {
				return eff.String(), all.String(), resets, dones
			}
			switch ch.Type {
			case providers.ChunkText:
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(ch.Payload, &p)
				eff.WriteString(p.Text)
				all.WriteString(p.Text)
			case providers.ChunkContentReset:
				resets++
				eff.Reset()
			case providers.ChunkDone:
				dones++
			}
		case <-deadline:
			t.Fatalf("wrapper stream did not close within 5s")
		}
	}
}

// A clean resume: leg 2's text picks up deep in the document, nothing
// is reset, and the pieces concatenate in order.
func TestContinuation_ResumeAppends(t *testing.T) {
	leg1Text := "# Save\n\n## Section 1\nDetailed content of the first section that establishes the document opening. "
	leg2Text := "and here the second leg resumes the tail of the document with entirely different material, running long enough to satisfy the restart probe threshold before it decides."
	p := &scriptedProvider{legs: [][]providers.Chunk{
		{textChunk(leg1Text), usageChunk(t, 10, "max_tokens"), doneChunk()},
		{textChunk(leg2Text), usageChunk(t, 7, "end_turn"), doneChunk()},
	}}
	send := continuationSendFunc(p, providers.SendRequest{ModelID: "m"}, nil)
	src, err := send(context.Background())
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	effective, _, resets, dones := collect(t, src)
	if resets != 0 {
		t.Errorf("resets = %d, want 0", resets)
	}
	if dones != 1 {
		t.Errorf("dones = %d, want 1", dones)
	}
	if effective != leg1Text+leg2Text {
		t.Errorf("effective text mismatch:\n got: %q\nwant: %q", effective, leg1Text+leg2Text)
	}
	// The continuation request carried the partial as an assistant
	// turn plus the continue instruction.
	if len(p.requests) != 2 {
		t.Fatalf("requests = %d, want 2", len(p.requests))
	}
	msgs := p.requests[1].Messages
	if len(msgs) != 2 || msgs[0].Role != "assistant" || msgs[0].Content != leg1Text {
		t.Errorf("continuation messages malformed: %+v", msgs)
	}
}

// A restart: leg 2 re-begins the document from the top. The wrapper
// must emit ChunkContentReset so consumers discard the superseded
// leg-1 text, and the effective document is leg 2 alone.
func TestContinuation_RestartResets(t *testing.T) {
	docOpening := "# Save Range\nFrom: Thursday, June 14 (the bonfire)\nTo: Friday, July 27 (the text message)\n"
	leg1 := "I need to plan this carefully. " + docOpening + "More draft content follows here. Let me write."
	leg2 := docOpening + "## Changed Character Profiles\nThe full clean document body continues here."
	p := &scriptedProvider{legs: [][]providers.Chunk{
		{textChunk(leg1), usageChunk(t, 10, "max_tokens"), doneChunk()},
		// Split leg 2 into small deltas so the probe exercises its
		// buffering path rather than deciding on one big chunk.
		{
			textChunk(leg2[:10]), textChunk(leg2[10:25]),
			textChunk(leg2[25:80]), textChunk(leg2[80:]),
			usageChunk(t, 9, "end_turn"), doneChunk(),
		},
	}}
	send := continuationSendFunc(p, providers.SendRequest{ModelID: "m"}, nil)
	src, err := send(context.Background())
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	effective, raw, resets, dones := collect(t, src)
	if resets != 1 {
		t.Fatalf("resets = %d, want 1 (raw stream: %q)", resets, raw)
	}
	if dones != 1 {
		t.Errorf("dones = %d, want 1", dones)
	}
	if effective != leg2 {
		t.Errorf("effective text should be the restart leg alone:\n got: %q\nwant: %q", effective, leg2)
	}
}

// A leg-2 that ends before the probe threshold flushes undecided —
// short continuations must not be swallowed.
func TestContinuation_ShortSecondLegFlushes(t *testing.T) {
	leg1 := strings.Repeat("first leg content. ", 10)
	leg2 := " done."
	p := &scriptedProvider{legs: [][]providers.Chunk{
		{textChunk(leg1), usageChunk(t, 10, "length"), doneChunk()},
		{textChunk(leg2), usageChunk(t, 1, "stop"), doneChunk()},
	}}
	send := continuationSendFunc(p, providers.SendRequest{ModelID: "m"}, nil)
	src, err := send(context.Background())
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	effective, _, resets, _ := collect(t, src)
	if resets != 0 {
		t.Errorf("resets = %d, want 0", resets)
	}
	if effective != leg1+leg2 {
		t.Errorf("effective = %q, want %q", effective, leg1+leg2)
	}
}

// The probe's normalized comparison: whitespace and case differences
// between the restart and the original opening must not defeat it.
func TestRestartProbe_NormalizedMatch(t *testing.T) {
	doc := "**Save Range**  \nFrom: Thursday, June 14, 2007 (John arrives at the bonfire)\nTo: Friday"
	probe := newRestartProbe("deliberation first. " + doc + " and much more content after")
	probe.buf.WriteString("**save range**\nfrom:   thursday, june 14, 2007 (john arrives")
	if !probe.ready() {
		t.Fatalf("probe should be ready at %d chars", probe.buf.Len())
	}
	out := make(chan providers.Chunk, 8)
	var partial strings.Builder
	partial.WriteString("superseded")
	if !probe.flush(context.Background(), out, &partial, true) {
		t.Fatalf("flush aborted")
	}
	if !probe.restarted {
		t.Errorf("expected restart detection across case/whitespace differences")
	}
	if strings.Contains(partial.String(), "superseded") {
		t.Errorf("partial should have been reset, got %q", partial.String())
	}
}
