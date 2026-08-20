package conversations

// End-to-end live test of the stateful send path. Drives the real `codex`
// binary through SendMessage and spends the operator's own tokens, so it is
// opt-in:
//
//	PSMITH_LIVE_CODEX=1 go test ./server/conversations/ -run TestLiveStateful -v
//
// Unit tests prove the handle is resolved, stamped and forked correctly
// against a fake. Only this one proves the handles Psmith persists are handles
// a real harness will accept back.

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"

	// Register the harness drivers under test.
	_ "github.com/jdpedrie/psmith/server/providers/claudecode"
	_ "github.com/jdpedrie/psmith/server/providers/codex"
)

func requireLiveCodex(t *testing.T) string {
	t.Helper()
	if os.Getenv("PSMITH_LIVE_CODEX") == "" {
		t.Skip("set PSMITH_LIVE_CODEX=1 to run the live harness send test (spends tokens)")
	}
	if _, err := exec.LookPath("codex"); err != nil {
		t.Skip("codex not on PATH")
	}
	if m := os.Getenv("PSMITH_LIVE_CODEX_MODEL"); m != "" {
		return m
	}
	// The operator's configured model. A literal would fail on someone else's
	// account for reasons that have nothing to do with this path.
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

func requireLiveClaudeCode(t *testing.T) string {
	t.Helper()
	if os.Getenv("PSMITH_LIVE_CLAUDECODE") == "" {
		t.Skip("set PSMITH_LIVE_CLAUDECODE=1 to run the live Claude Code send test (spends tokens)")
	}
	if _, err := exec.LookPath("claude"); err != nil {
		t.Skip("claude not on PATH")
	}
	return "sonnet"
}

// Two turns through SendMessage against a real harness. The second turn only
// answers correctly if it landed in a session that already contains the first,
// which is the whole claim the stateful path makes.
//
// Both drivers are exercised because they reach the handle differently: Codex
// forks an existing thread, while Claude Code hands back a provisional handle
// that only becomes real once the CLI mints a session on the first turn.
func TestLiveStateful_SecondTurnRemembersTheFirst(t *testing.T) {
	t.Run("codex", func(t *testing.T) {
		liveTwoTurnRecall(t, "codex-app-server", requireLiveCodex(t))
	})
	t.Run("claudecode", func(t *testing.T) {
		liveTwoTurnRecall(t, "claude-code-subprocess", requireLiveClaudeCode(t))
	})
}

func liveTwoTurnRecall(t *testing.T, driverType, model string) {
	t.Helper()
	svc, q, sup := newFullSvc(t)
	ctx := context.Background()

	fx := seedLiveHarness(t, q, driverType, model)

	first := sendStateful(t, svc, fx, "Remember this word: BANANA. Reply with just: ok")
	r1, _ := uuid.Parse(first.StreamRun.Id)
	waitForLiveTerminal(t, sup, r1)

	second := sendStateful(t, svc, fx, "What was the word? Reply with the word alone.")
	r2, _ := uuid.Parse(second.StreamRun.Id)
	waitForLiveTerminal(t, sup, r2)

	rows, err := q.ListMessagesByContext(ctx, store.ListMessagesByContextParams{
		ContextID: fx.contextID, RowLimit: 100,
	})
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	var assistants []store.Message
	for _, r := range rows {
		if r.Role == "assistant" {
			assistants = append(assistants, r)
		}
	}
	if len(assistants) != 2 {
		t.Fatalf("got %d assistant rows, want 2", len(assistants))
	}
	for i, a := range assistants {
		if a.HarnessHandle == nil {
			t.Fatalf("assistant %d has no harness handle", i)
		}
		t.Logf("turn %d handle=%s content=%q", i, *a.HarnessHandle, a.Content)
	}
	if *assistants[0].HarnessHandle == *assistants[1].HarnessHandle {
		t.Error("both turns share a handle; forking per turn is what makes editing an old message possible")
	}
	if !strings.Contains(strings.ToUpper(assistants[1].Content), "BANANA") {
		t.Errorf("second turn = %q, want it to recall BANANA from the first", assistants[1].Content)
	}
}

func seedLiveHarness(t *testing.T, q *store.Queries, driverType, model string) sendFixture {
	t.Helper()
	ctx := context.Background()
	fx := seedSendable(t, q, driverType)

	// seedSendable registers its model under a fake id. A live harness needs
	// the real one, and the config blob is stored unencrypted because the test
	// service is built with crypto.Nop.
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID: fx.provider.ID,
		ModelID:             model,
		DisplayName:         model,
		MetadataSource:      "manual",
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}
	fx.modelID = model
	return fx
}

// Live turns take far longer than the fake ones: a real harness boots a
// subprocess and waits on a model.
func waitForLiveTerminal(t *testing.T, sup interface {
	Get(context.Context, uuid.UUID) (store.StreamRun, error)
}, runID uuid.UUID) store.StreamRun {
	t.Helper()
	deadline := time.Now().Add(3 * time.Minute)
	for {
		row, err := sup.Get(context.Background(), runID)
		if err != nil {
			t.Fatalf("supervisor.Get: %v", err)
		}
		if row.Status != "running" {
			if row.Status != "completed" {
				t.Fatalf("run finished as %q: %s", row.Status, row.ErrorPayload)
			}
			return row
		}
		if time.Now().After(deadline) {
			t.Fatalf("run %s still running after 3m", runID)
		}
		time.Sleep(500 * time.Millisecond)
	}
}
