package codexsdk

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeServer builds a stand-in `codex` binary that speaks just enough of the
// app-server protocol to exercise this package.
//
// A scripted subprocess rather than an in-process transport: the framing, the
// scanner buffer, the process lifecycle and the demultiplexing are the parts
// most likely to be wrong, and an in-process fake would skip all of them.
func fakeServer(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte(script), 0o644); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	bin := filepath.Join(dir, "codex")
	build := exec.Command("go", "build", "-o", bin, src)
	build.Env = append(os.Environ(), "GOFLAGS=")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build fake: %v\n%s", err, out)
	}
	return bin
}

// respondingServer answers initialize/thread/turn and emits the notifications
// named in `emit` after a turn starts.
const respondingServer = `package main

import ("bufio";"encoding/json";"fmt";"os")

func main() {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		var req struct {
			ID     int64           ` + "`json:\"id\"`" + `
			Method string          ` + "`json:\"method\"`" + `
			Params json.RawMessage ` + "`json:\"params\"`" + `
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil { continue }
		switch req.Method {
		case "initialize":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{}}` + \"\\n\"" + `, req.ID)
		case "thread/start":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"t-new\"},\"model\":\"m\"}}` + \"\\n\"" + `, req.ID)
		case "thread/fork":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"t-fork\",\"forkedFromId\":\"t-new\"},\"model\":\"m\"}}` + \"\\n\"" + `, req.ID)
		case "thread/resume":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"t-new\"},\"model\":\"m\"}}` + \"\\n\"" + `, req.ID)
		case "turn/start":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"running\"}}}` + \"\\n\"" + `, req.ID)
			fmt.Println(` + "`{\"method\":\"item/reasoning/summaryTextDelta\",\"params\":{\"delta\":\"pondering\",\"threadId\":\"t-new\",\"turnId\":\"turn-1\"}}`" + `)
			fmt.Println(` + "`{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"He\",\"threadId\":\"t-new\",\"turnId\":\"turn-1\"}}`" + `)
			fmt.Println(` + "`{\"method\":\"fs/changed\",\"params\":{\"noise\":true}}`" + `)
			fmt.Println(` + "`{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"llo\",\"threadId\":\"t-new\",\"turnId\":\"turn-1\"}}`" + `)
			fmt.Println(` + "`{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"t-new\",\"turnId\":\"turn-1\",\"tokenUsage\":{\"last\":{\"inputTokens\":11,\"cachedInputTokens\":4,\"outputTokens\":2,\"reasoningOutputTokens\":1},\"total\":{}}}}`" + `)
			fmt.Println(` + "`{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t-new\",\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}`" + `)
		default:
			fmt.Printf(` + "`{\"id\":%d,\"error\":{\"code\":-1,\"message\":\"unknown method\"}}` + \"\\n\"" + `, req.ID)
		}
	}
}
`

func newFake(t *testing.T, script string) *Client {
	t.Helper()
	bin := fakeServer(t, script)
	c, err := New(context.Background(), Options{CLIPath: bin})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func drain(t *testing.T, ch <-chan Event) []Event {
	t.Helper()
	var out []Event
	deadline := time.After(10 * time.Second)
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				return out
			}
			out = append(out, ev)
		case <-deadline:
			t.Fatal("timed out draining events")
		}
	}
}

func TestSend_StreamsTextThinkingUsageAndDone(t *testing.T) {
	c := newFake(t, respondingServer)
	th, err := c.StartThread(context.Background(), ThreadOptions{})
	if err != nil {
		t.Fatalf("StartThread: %v", err)
	}
	ch, err := th.Send(context.Background(), "hi", ThreadOptions{})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	evs := drain(t, ch)

	var text, thinking strings.Builder
	var usage Usage
	var done bool
	for _, e := range evs {
		switch e.Kind {
		case EventText:
			text.WriteString(e.Text)
		case EventThinking:
			thinking.WriteString(e.Text)
		case EventUsage:
			usage = e.Usage
		case EventDone:
			done = true
		}
	}
	if text.String() != "Hello" {
		t.Errorf("text = %q, want Hello (deltas must arrive in order)", text.String())
	}
	if thinking.String() != "pondering" {
		t.Errorf("thinking = %q", thinking.String())
	}
	if usage.InputTokens != 11 || usage.CachedInputTokens != 4 || usage.OutputTokens != 2 || usage.ReasoningTokens != 1 {
		t.Errorf("usage = %+v", usage)
	}
	if !done {
		t.Error("no EventDone; the channel must end with a terminal event")
	}
	if evs[len(evs)-1].Kind != EventDone {
		t.Errorf("last event was %v, want done", evs[len(evs)-1].Kind)
	}
}

// The protocol carries dozens of notifications a chat harness has no use for.
// Ignoring them is what keeps this package stable across protocol revisions,
// so it is worth pinning that an unknown method is dropped rather than
// surfaced or fatal. The fake emits fs/changed mid-stream.
func TestSend_IgnoresUnknownNotifications(t *testing.T) {
	c := newFake(t, respondingServer)
	th, _ := c.StartThread(context.Background(), ThreadOptions{})
	ch, err := th.Send(context.Background(), "hi", ThreadOptions{})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for _, e := range drain(t, ch) {
		if e.Kind != EventText && e.Kind != EventThinking && e.Kind != EventUsage && e.Kind != EventDone {
			t.Errorf("unexpected event kind %q leaked through", e.Kind)
		}
	}
}

func TestForkThread_ReturnsANewIDAndRecordsItsParent(t *testing.T) {
	c := newFake(t, respondingServer)
	ctx := context.Background()
	th, _ := c.StartThread(ctx, ThreadOptions{})

	fork, err := c.ForkThread(ctx, th.ID(), "turn-1", ThreadOptions{})
	if err != nil {
		t.Fatalf("ForkThread: %v", err)
	}
	if fork.ID() == th.ID() {
		t.Fatal("fork returned the parent's id; that is a mutation, not a fork")
	}
	if fork.ForkedFrom() != th.ID() {
		t.Errorf("forkedFrom = %q, want %q", fork.ForkedFrom(), th.ID())
	}
}

// Resume deliberately keeps the same id: it appends in place. Pinning this
// stops anyone mistaking it for a fork.
func TestResumeThread_KeepsTheSameID(t *testing.T) {
	c := newFake(t, respondingServer)
	ctx := context.Background()
	th, _ := c.StartThread(ctx, ThreadOptions{})
	again, err := c.ResumeThread(ctx, th.ID(), ThreadOptions{})
	if err != nil {
		t.Fatalf("ResumeThread: %v", err)
	}
	if again.ID() != th.ID() {
		t.Errorf("resume changed the id: %q -> %q", th.ID(), again.ID())
	}
}

func TestThreadIDRequired(t *testing.T) {
	c := newFake(t, respondingServer)
	ctx := context.Background()
	if _, err := c.ForkThread(ctx, "", "", ThreadOptions{}); err == nil {
		t.Error("fork without a thread id should fail")
	}
	if _, err := c.ResumeThread(ctx, "", ThreadOptions{}); err == nil {
		t.Error("resume without a thread id should fail")
	}
}

// One turn per thread. Two in flight would interleave their deltas into one
// channel, which the caller has no way to untangle.
func TestSend_RefusesASecondConcurrentTurn(t *testing.T) {
	c := newFake(t, quietServer)
	ctx := context.Background()
	th, _ := c.StartThread(ctx, ThreadOptions{})
	if _, err := th.Send(ctx, "first", ThreadOptions{}); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	_, err := th.Send(ctx, "second", ThreadOptions{})
	if err == nil {
		t.Fatal("expected the second concurrent turn to be refused")
	}
	if !strings.Contains(err.Error(), "in flight") {
		t.Errorf("error should explain why: %v", err)
	}
}

// quietServer starts a turn and then says nothing, so the turn stays open.
const quietServer = `package main

import ("bufio";"encoding/json";"fmt";"os")

func main() {
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		var req struct {
			ID     int64  ` + "`json:\"id\"`" + `
			Method string ` + "`json:\"method\"`" + `
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil { continue }
		switch req.Method {
		case "initialize":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{}}` + \"\\n\"" + `, req.ID)
		case "thread/start":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"t-new\"}}}` + \"\\n\"" + `, req.ID)
		case "turn/start":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}` + \"\\n\"" + `, req.ID)
		default:
			fmt.Printf(` + "`{\"id\":%d,\"result\":{}}` + \"\\n\"" + `, req.ID)
		}
	}
}
`

// A crashed app-server must surface as an error, not a hang: every in-flight
// call is unblocked when the process dies.
func TestCall_FailsWhenTheServerDies(t *testing.T) {
	const dies = `package main

import "os"

func main() { os.Exit(1) }
`
	bin := fakeServer(t, dies)
	_, err := New(context.Background(), Options{CLIPath: bin})
	if err == nil {
		t.Fatal("expected initialize against a dead server to fail")
	}
}

func TestNew_ReportsAMissingBinary(t *testing.T) {
	_, err := New(context.Background(), Options{CLIPath: "/nonexistent/codex"})
	if err == nil {
		t.Fatal("expected a missing binary to fail")
	}
}

var _ = json.Marshal
