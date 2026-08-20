package codex

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/psmith/server/providers"
)

// recordingServer answers the protocol and writes every method it received to
// $CODEX_METHOD_LOG, so a test can assert which one the driver chose.
const recordingServer = `package main

import ("bufio";"encoding/json";"fmt";"os")

func main() {
	logPath := os.Getenv("CODEX_METHOD_LOG")
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		var req struct {
			ID     int64           ` + "`json:\"id\"`" + `
			Method string          ` + "`json:\"method\"`" + `
			Params json.RawMessage ` + "`json:\"params\"`" + `
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil { continue }
		if logPath != "" {
			if f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				fmt.Fprintf(f, "%s %s\n", req.Method, string(req.Params))
				f.Close()
			}
		}
		switch req.Method {
		case "initialize":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{}}` + \"\\n\"" + `, req.ID)
		case "thread/start":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"th-started\"}}}` + \"\\n\"" + `, req.ID)
		case "thread/fork":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"th-forked\",\"forkedFromId\":\"th-parent\"}}}` + \"\\n\"" + `, req.ID)
		case "thread/resume":
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"thread\":{\"id\":\"th-resumed\"}}}` + \"\\n\"" + `, req.ID)
		case "turn/start":
			var p struct{ ThreadId string ` + "`json:\"threadId\"`" + ` }
			json.Unmarshal(req.Params, &p)
			fmt.Printf(` + "`{\"id\":%d,\"result\":{\"turn\":{\"id\":\"turn-9\"}}}` + \"\\n\"" + `, req.ID)
			fmt.Printf(` + "`{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"hi\",\"threadId\":%q,\"turnId\":\"turn-9\"}}` + \"\\n\"" + `, p.ThreadId)
			fmt.Printf(` + "`{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":%q,\"turnId\":\"turn-9\",\"tokenUsage\":{\"last\":{\"inputTokens\":5,\"cachedInputTokens\":2,\"outputTokens\":1,\"reasoningOutputTokens\":0},\"total\":{}}}}` + \"\\n\"" + `, p.ThreadId)
			fmt.Printf(` + "`{\"method\":\"turn/completed\",\"params\":{\"threadId\":%q,\"turn\":{\"id\":\"turn-9\"}}}` + \"\\n\"" + `, p.ThreadId)
		default:
			fmt.Printf(` + "`{\"id\":%d,\"result\":{}}` + \"\\n\"" + `, req.ID)
		}
	}
}
`

func buildRecorder(t *testing.T) (bin, logPath string) {
	t.Helper()
	dir := t.TempDir()
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte(recordingServer), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	bin = filepath.Join(dir, "codex")
	if out, err := exec.Command("go", "build", "-o", bin, src).CombinedOutput(); err != nil {
		t.Fatalf("build fake: %v\n%s", err, out)
	}
	logPath = filepath.Join(dir, "methods.log")
	t.Setenv("CODEX_METHOD_LOG", logPath)
	return bin, logPath
}

func drainChunks(t *testing.T, ch <-chan providers.Chunk) []providers.Chunk {
	t.Helper()
	var out []providers.Chunk
	deadline := time.After(15 * time.Second)
	for {
		select {
		case c, ok := <-ch:
			if !ok {
				return out
			}
			out = append(out, c)
		case <-deadline:
			t.Fatal("timed out draining chunks")
		}
	}
}

func methods(t *testing.T, logPath string) string {
	t.Helper()
	b, err := os.ReadFile(logPath)
	if err != nil {
		return ""
	}
	return string(b)
}

// The load-bearing property of this driver: a durable handle FORKS. Resuming
// would append in place and mutate the state other handles name, so a user
// editing message five would corrupt the branch they forked from.
func TestSendInSession_DurableHandleForksNeverResumes(t *testing.T) {
	bin, logPath := buildRecorder(t)
	d := newDriver(t, `{"cli_path":`+strconv.Quote(bin)+`}`)
	defer d.Close()

	handle := encodeHandle("gpt-x", "th-parent", "turn-3")
	ch, err := d.SendInSession(context.Background(), handle,
		providers.WireMessage{Role: "user", Content: "hello"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	drainChunks(t, ch)

	log := methods(t, logPath)
	if !strings.Contains(log, "thread/fork") {
		t.Fatalf("expected a fork, got methods:\n%s", log)
	}
	if strings.Contains(log, "thread/resume") {
		t.Fatalf("driver resumed instead of forking; that mutates the parent:\n%s", log)
	}
	// And it forked at the handle's turn, not the tip.
	if !strings.Contains(log, `"lastTurnId":"turn-3"`) {
		t.Errorf("fork did not carry the handle's turn id:\n%s", log)
	}
}

// A provisional handle has no thread upstream, so it starts one.
func TestSendInSession_ProvisionalHandleStartsAThread(t *testing.T) {
	bin, logPath := buildRecorder(t)
	d := newDriver(t, `{"cli_path":`+strconv.Quote(bin)+`}`)
	defer d.Close()

	handle, err := d.StartSession(context.Background(), "gpt-x", providers.SessionConfig{SystemPrompt: "be terse"})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	ch, err := d.SendInSession(context.Background(), handle,
		providers.WireMessage{Role: "user", Content: "hello"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	drainChunks(t, ch)

	log := methods(t, logPath)
	if !strings.Contains(log, "thread/start") {
		t.Fatalf("expected a start, got:\n%s", log)
	}
	if !strings.Contains(log, `"baseInstructions":"be terse"`) {
		t.Errorf("the system prompt did not reach thread/start:\n%s", log)
	}
	// The provisional handle is superseded once the turn lands.
	if _, err := d.resolveHandle(handle); err == nil {
		t.Error("provisional handle should be cleared after its first turn")
	}
}

// The system prompt is fixed for a conversation's lifetime, so a fork must not
// carry one: Codex would accept it, and a profile edit would silently change
// history's framing on the next branch.
func TestSendInSession_ForkDoesNotCarryTheSystemPrompt(t *testing.T) {
	bin, logPath := buildRecorder(t)
	d := newDriver(t, `{"cli_path":`+strconv.Quote(bin)+`}`)
	defer d.Close()

	ch, err := d.SendInSession(context.Background(), encodeHandle("m", "th-parent", "turn-1"),
		providers.WireMessage{Role: "user", Content: "hi"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	drainChunks(t, ch)

	for _, line := range strings.Split(methods(t, logPath), "\n") {
		if strings.HasPrefix(line, "thread/fork ") && strings.Contains(line, "baseInstructions") {
			t.Errorf("fork carried a system prompt: %s", line)
		}
	}
}

// The handle emitted for a turn is what the NEXT message forks from, so it has
// to name the thread just written to and the turn just produced.
func TestSendInSession_EmitsAHandleForThisTurn(t *testing.T) {
	bin, _ := buildRecorder(t)
	d := newDriver(t, `{"cli_path":`+strconv.Quote(bin)+`}`)
	defer d.Close()

	ch, err := d.SendInSession(context.Background(), encodeHandle("gpt-x", "th-parent", "turn-1"),
		providers.WireMessage{Role: "user", Content: "hi"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	chunks := drainChunks(t, ch)

	var handle string
	var kinds []string
	for _, c := range chunks {
		kinds = append(kinds, string(c.Type))
		if c.Type == providers.ChunkSessionHandle {
			var p map[string]string
			_ = json.Unmarshal(c.Payload, &p)
			handle = p["session_id"]
		}
	}
	if handle == "" {
		t.Fatalf("no session handle emitted; chunks were %v", kinds)
	}
	setup, err := d.resolveHandle(handle)
	if err != nil {
		t.Fatalf("emitted handle does not resolve: %v", err)
	}
	if setup.threadID != "th-forked" {
		t.Errorf("handle names %q, want the thread just written to", setup.threadID)
	}
	if setup.turnID != "turn-9" {
		t.Errorf("handle names turn %q, want the turn just produced", setup.turnID)
	}
	if kinds[len(kinds)-1] != string(providers.ChunkDone) {
		t.Errorf("stream must end with done, got %v", kinds)
	}
}
