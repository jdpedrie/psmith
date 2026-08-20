package codexsdk

import (
	"context"
	"encoding/json"
	"fmt"
)

// EventKind classifies a turn event.
type EventKind string

const (
	// EventText is a chunk of the assistant's visible reply.
	EventText EventKind = "text"
	// EventThinking is a chunk of reasoning summary. Codex emits these only
	// when the model is reasoning and the summary is enabled.
	EventThinking EventKind = "thinking"
	// EventUsage carries the turn's token counts, emitted before completion.
	EventUsage EventKind = "usage"
	// EventDone marks the turn finished. Always the last event on a healthy
	// turn.
	EventDone EventKind = "done"
	// EventError carries a turn failure. WillRetry distinguishes a transient
	// hiccup Codex is handling from a terminal failure.
	EventError EventKind = "error"
)

// Event is one thing that happened during a turn.
type Event struct {
	Kind   EventKind
	Text   string
	TurnID string

	// Usage is populated on EventUsage.
	Usage Usage

	// Err and WillRetry are populated on EventError.
	Err       string
	WillRetry bool
}

// Usage is one turn's token accounting.
type Usage struct {
	InputTokens       int64
	CachedInputTokens int64
	OutputTokens      int64
	ReasoningTokens   int64
}

// Thread is a Codex conversation.
type Thread struct {
	client *Client
	id     string
	// forkedFrom is the parent thread id when this came from a fork, which
	// Codex records itself. Useful provenance; nothing here depends on it.
	forkedFrom string
}

// ID is the durable thread id. It survives process restarts: Codex persists
// threads on disk and resume takes this value.
func (t *Thread) ID() string { return t.id }

// ForkedFrom is the parent thread id, empty when this thread was started
// rather than forked.
func (t *Thread) ForkedFrom() string { return t.forkedFrom }

// StartThread opens a new conversation.
func (c *Client) StartThread(ctx context.Context, opts ThreadOptions) (*Thread, error) {
	raw, err := c.call(ctx, "thread/start", threadStartParams{
		Model:            opts.Model,
		BaseInstructions: opts.BaseInstructions,
		Sandbox:          opts.Sandbox,
		ApprovalPolicy:   opts.ApprovalPolicy,
	})
	if err != nil {
		return nil, err
	}
	return c.threadFrom(raw)
}

// ResumeThread reopens an existing conversation by id.
//
// Resuming MUTATES: a turn sent to a resumed thread appends to it, and the
// thread id does not change. Use ForkThread when the caller needs the original
// left alone.
func (c *Client) ResumeThread(ctx context.Context, threadID string, opts ThreadOptions) (*Thread, error) {
	if threadID == "" {
		return nil, fmt.Errorf("codexsdk: thread id is required")
	}
	raw, err := c.call(ctx, "thread/resume", threadResumeParams{
		ThreadID:         threadID,
		Model:            opts.Model,
		BaseInstructions: opts.BaseInstructions,
		Sandbox:          opts.Sandbox,
		ApprovalPolicy:   opts.ApprovalPolicy,
	})
	if err != nil {
		return nil, err
	}
	return c.threadFrom(raw)
}

// ForkThread branches a conversation into a new thread, leaving the original
// untouched.
//
// lastTurnID forks from that specific turn rather than the tip, which is what
// makes editing a historical message cheap: fork at the turn before it and
// send the replacement, with nothing replayed and no tokens re-spent. Empty
// forks from the tip.
func (c *Client) ForkThread(ctx context.Context, threadID, lastTurnID string, opts ThreadOptions) (*Thread, error) {
	if threadID == "" {
		return nil, fmt.Errorf("codexsdk: thread id is required")
	}
	raw, err := c.call(ctx, "thread/fork", threadForkParams{
		ThreadID:         threadID,
		LastTurnID:       lastTurnID,
		Model:            opts.Model,
		BaseInstructions: opts.BaseInstructions,
		Sandbox:          opts.Sandbox,
		ApprovalPolicy:   opts.ApprovalPolicy,
	})
	if err != nil {
		return nil, err
	}
	return c.threadFrom(raw)
}

func (c *Client) threadFrom(raw json.RawMessage) (*Thread, error) {
	var res threadResult
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, fmt.Errorf("codexsdk: decode thread: %w", err)
	}
	if res.Thread.ID == "" {
		return nil, fmt.Errorf("codexsdk: response carried no thread id")
	}
	return &Thread{client: c, id: res.Thread.ID, forkedFrom: res.Thread.ForkedFromID}, nil
}

// Send starts a turn and streams its events.
//
// The returned channel closes when the turn ends, and the caller must drain it
// or cancel ctx: the read loop delivers into it and a blocked subscriber would
// stall every other thread sharing this process.
//
// Only one turn per thread may be in flight. A second Send on a thread that is
// already streaming returns an error rather than interleaving two turns'
// deltas into one channel.
func (t *Thread) Send(ctx context.Context, text string, opts ThreadOptions) (<-chan Event, error) {
	out := make(chan Event, 64)

	t.client.mu.Lock()
	if _, busy := t.client.subs[t.id]; busy {
		t.client.mu.Unlock()
		return nil, fmt.Errorf("codexsdk: thread %s already has a turn in flight", t.id)
	}
	t.client.subs[t.id] = out
	t.client.mu.Unlock()

	unsub := func() {
		t.client.mu.Lock()
		if cur, ok := t.client.subs[t.id]; ok && cur == (chan<- Event)(out) {
			delete(t.client.subs, t.id)
		}
		t.client.mu.Unlock()
	}

	raw, err := t.client.call(ctx, "turn/start", turnStartParams{
		ThreadID: t.id,
		Input:    []textInput{{Type: "text", Text: text}},
		Model:    opts.Model,
	})
	if err != nil {
		unsub()
		close(out)
		return nil, err
	}
	var res turnStartResult
	_ = json.Unmarshal(raw, &res)

	// Cancellation is the caller's way out of a turn that will not finish.
	// Interrupt is best-effort: if the app-server has already completed the
	// turn, the notification arrives first and this is a no-op.
	go func() {
		<-ctx.Done()
		t.client.mu.Lock()
		_, live := t.client.subs[t.id]
		t.client.mu.Unlock()
		if !live {
			return
		}
		ictx, cancel := context.WithTimeout(context.Background(), interruptTimeout)
		defer cancel()
		_, _ = t.client.call(ictx, "turn/interrupt", turnInterruptParams{
			ThreadID: t.id, TurnID: res.Turn.ID,
		})
		unsub()
		close(out)
	}()

	return out, nil
}

// deliverNotification routes a server notification to its thread's subscriber.
//
// Unknown methods are dropped: the protocol carries dozens of notifications
// about approvals, filesystem changes and MCP status that a chat harness has
// no use for, and ignoring them is what keeps this package stable across
// protocol revisions.
func (c *Client) deliverNotification(msg response) {
	var (
		threadID string
		ev       Event
		terminal bool
	)
	switch msg.Method {
	case "item/agentMessage/delta":
		var p agentMessageDelta
		if json.Unmarshal(msg.Params, &p) != nil {
			return
		}
		threadID, ev = p.ThreadID, Event{Kind: EventText, Text: p.Delta, TurnID: p.TurnID}

	case "item/reasoning/summaryTextDelta":
		var p reasoningDelta
		if json.Unmarshal(msg.Params, &p) != nil {
			return
		}
		threadID, ev = p.ThreadID, Event{Kind: EventThinking, Text: p.Delta, TurnID: p.TurnID}

	case "thread/tokenUsage/updated":
		var p tokenUsageUpdated
		if json.Unmarshal(msg.Params, &p) != nil {
			return
		}
		threadID = p.ThreadID
		ev = Event{Kind: EventUsage, TurnID: p.TurnID, Usage: Usage{
			InputTokens:       p.TokenUsage.Last.InputTokens,
			CachedInputTokens: p.TokenUsage.Last.CachedInputTokens,
			OutputTokens:      p.TokenUsage.Last.OutputTokens,
			ReasoningTokens:   p.TokenUsage.Last.ReasoningTokens,
		}}

	case "turn/completed":
		var p turnCompleted
		if json.Unmarshal(msg.Params, &p) != nil {
			return
		}
		threadID, ev, terminal = p.ThreadID, Event{Kind: EventDone, TurnID: p.Turn.ID}, true

	case "error":
		var p errorNotification
		if json.Unmarshal(msg.Params, &p) != nil {
			return
		}
		threadID = p.ThreadID
		ev = Event{Kind: EventError, TurnID: p.TurnID, Err: p.Error.Message, WillRetry: p.WillRetry}
		// A retryable error is Codex telling us it is handling the problem.
		// Ending the turn there would abandon a stream that is about to
		// resume.
		terminal = !p.WillRetry

	default:
		return
	}

	c.mu.Lock()
	sub, ok := c.subs[threadID]
	if ok && terminal {
		delete(c.subs, threadID)
	}
	c.mu.Unlock()
	if !ok {
		return
	}

	select {
	case sub <- ev:
	default:
		// Subscriber is not keeping up. Dropping a delta is better than
		// blocking the reader that serves every other thread in this
		// process.
	}
	if terminal {
		close(sub)
	}
}
