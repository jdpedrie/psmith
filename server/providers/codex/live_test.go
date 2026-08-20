package codex

// Live integration test. Drives the real `codex` binary and spends the
// operator's own tokens, so it is opt-in:
//
//	PSMITH_LIVE_CODEX=1 go test ./server/providers/codex/ -run TestLive -v

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/server/providers"
)

func requireCodex(t *testing.T) {
	t.Helper()
	if os.Getenv("PSMITH_LIVE_CODEX") == "" {
		t.Skip("set PSMITH_LIVE_CODEX=1 to run live Codex tests (spends tokens)")
	}
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex not on PATH")
	}
}

// liveModel reads the operator's configured model rather than hardcoding one.
// Codex rejects model ids its account is not entitled to (a ChatGPT account
// cannot use gpt-5.1-codex, for instance), so a literal here would fail on
// someone else's machine for a reason that has nothing to do with this driver.
func liveModel(t *testing.T) string {
	t.Helper()
	if m := os.Getenv("PSMITH_LIVE_CODEX_MODEL"); m != "" {
		return m
	}
	b, err := os.ReadFile(os.ExpandEnv("$HOME/.codex/config.toml"))
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "model") && strings.Contains(line, "=") {
				v := strings.TrimSpace(strings.SplitN(line, "=", 2)[1])
				if m := strings.Trim(v, `"`); m != "" && !strings.Contains(m, "reasoning") {
					return m
				}
			}
		}
	}
	t.Skip("no model configured; set PSMITH_LIVE_CODEX_MODEL")
	return ""
}

// collect drains a turn into its text and the handle it produced.
func collect(t *testing.T, ch <-chan providers.Chunk) (text, handle string) {
	t.Helper()
	var b strings.Builder
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			b.WriteString(p.Text)
		case providers.ChunkSessionHandle:
			var p struct {
				SessionID string `json:"session_id"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			handle = p.SessionID
		case providers.ChunkError:
			t.Fatalf("turn errored: %s", c.Payload)
		}
	}
	return b.String(), handle
}

// The end-to-end property: each turn's handle is a snapshot, and sending to an
// OLD handle branches without disturbing the newer one. This is what makes
// editing a historical message work.
func TestLive_EditingAnOldMessageBranchesCleanly(t *testing.T) {
	requireCodex(t)
	ctx := context.Background()
	d := newDriver(t, `{}`)
	defer d.Close()

	start, err := d.StartSession(ctx, liveModel(t), providers.SessionConfig{
		SystemPrompt: "Answer in one word. Never explain.",
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}

	send := func(handle, text string) (string, string) {
		t.Helper()
		ch, err := d.SendInSession(ctx, handle,
			providers.WireMessage{Role: "user", Content: text}, providers.CallSettings{})
		if err != nil {
			t.Fatalf("SendInSession: %v", err)
		}
		return collect(t, ch)
	}

	// Turn 1 establishes a fact.
	_, h1 := send(start, "Remember the codeword APPLE. Reply: ok")
	if h1 == "" {
		t.Fatal("turn 1 produced no handle")
	}
	// Turn 2 changes it.
	_, h2 := send(h1, "Forget APPLE. The codeword is now BANANA. Reply: ok")
	if h2 == "" || h2 == h1 {
		t.Fatalf("turn 2 handle is missing or unchanged: %q vs %q", h2, h1)
	}

	// The tip knows the new word.
	tip, _ := send(h2, "What is the codeword?")
	t.Logf("tip says: %q", strings.TrimSpace(tip))
	if !strings.Contains(strings.ToUpper(tip), "BANANA") {
		t.Errorf("tip should know BANANA, said %q", tip)
	}

	// Now branch from the OLD handle, as an edit of message two would. It
	// must not know BANANA: that turn is not on this branch.
	branch, _ := send(h1, "What is the codeword?")
	t.Logf("branch says: %q", strings.TrimSpace(branch))
	if strings.Contains(strings.ToUpper(branch), "BANANA") {
		t.Errorf("the branch saw a turn that is not its ancestor: %q", branch)
	}
	if !strings.Contains(strings.ToUpper(branch), "APPLE") {
		t.Errorf("the branch lost its own history, said %q", branch)
	}
}
