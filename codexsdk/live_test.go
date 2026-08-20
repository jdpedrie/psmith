package codexsdk

// Live integration tests. See requireCodex for how to run them.

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Live tests drive the real `codex` binary and spend the operator's own
// tokens, so they are opt-in. Without the env var they skip, which keeps
// `go test ./...` free.
func requireCodex(t *testing.T) {
	t.Helper()
	if os.Getenv("PSMITH_LIVE_CODEX") == "" {
		t.Skip("set PSMITH_LIVE_CODEX=1 to run live Codex tests (spends tokens)")
	}
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex not on PATH")
	}
}

func collect(t *testing.T, ch <-chan Event) (text string, usage Usage, errs []string) {
	t.Helper()
	var b strings.Builder
	deadline := time.After(120 * time.Second)
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				return b.String(), usage, errs
			}
			switch ev.Kind {
			case EventText:
				b.WriteString(ev.Text)
			case EventUsage:
				usage = ev.Usage
			case EventError:
				errs = append(errs, ev.Err)
			}
		case <-deadline:
			t.Fatal("timed out waiting for turn events")
		}
	}
}

func TestLive_ForkAtTurnLeavesTheParentAlone(t *testing.T) {
	requireCodex(t)
	ctx := context.Background()
	c, err := New(ctx, Options{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer c.Close()

	th, err := c.StartThread(ctx, ThreadOptions{})
	if err != nil {
		t.Fatalf("StartThread: %v", err)
	}
	ch, err := th.Send(ctx, "Reply with exactly: ALPHA", ThreadOptions{})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	text, usage, errs := collect(t, ch)
	t.Logf("thread=%s reply=%q usage=%+v errs=%v", th.ID(), strings.TrimSpace(text), usage, errs)
	if !strings.Contains(text, "ALPHA") {
		t.Fatalf("expected ALPHA, got %q", text)
	}
	if usage.InputTokens == 0 {
		t.Errorf("expected usage to be reported, got %+v", usage)
	}

	// Fork, then send a different second message on the branch.
	fork, err := c.ForkThread(ctx, th.ID(), "", ThreadOptions{})
	if err != nil {
		t.Fatalf("ForkThread: %v", err)
	}
	if fork.ID() == th.ID() {
		t.Fatal("fork returned the same thread id; that is a mutation, not a fork")
	}
	t.Logf("fork=%s forkedFrom=%s", fork.ID(), fork.ForkedFrom())

	fch, err := fork.Send(ctx, "Reply with exactly: BETA", ThreadOptions{})
	if err != nil {
		t.Fatalf("fork Send: %v", err)
	}
	ftext, _, _ := collect(t, fch)
	if !strings.Contains(ftext, "BETA") {
		t.Fatalf("expected BETA on the fork, got %q", ftext)
	}

	// The parent must not know about BETA: resume it and ask.
	parent, err := c.ResumeThread(ctx, th.ID(), ThreadOptions{})
	if err != nil {
		t.Fatalf("ResumeThread: %v", err)
	}
	pch, err := parent.Send(ctx, "Have you said the word BETA in this conversation? Answer yes or no.", ThreadOptions{})
	if err != nil {
		t.Fatalf("parent Send: %v", err)
	}
	ptext, _, _ := collect(t, pch)
	t.Logf("parent says: %q", strings.TrimSpace(ptext))
	if strings.Contains(strings.ToLower(ptext), "yes") {
		t.Errorf("the fork leaked into the parent: %q", ptext)
	}
}
