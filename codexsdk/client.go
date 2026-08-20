package codexsdk

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"
)

// Client is one `codex app-server` subprocess.
//
// Long-lived and safe for concurrent use: the app-server multiplexes threads,
// so one process serves every conversation rather than one per turn. That is
// the main practical difference from claudesdk, which spawns per query.
type Client struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	enc    *json.Encoder
	nextID atomic.Int64

	// writeMu serializes writes. Encoder is not concurrency-safe and two
	// interleaved requests would corrupt the stream.
	writeMu sync.Mutex

	mu sync.Mutex
	// pending maps a request id to the channel awaiting its result.
	pending map[int64]chan response
	// subs maps a thread id to its live turn subscriber. One at a time: a
	// thread is a conversation and a conversation has one turn in flight.
	subs map[string]chan<- Event

	closed  atomic.Bool
	exited  chan struct{}
	exitErr error
}

// Options configure the subprocess.
type Options struct {
	// CLIPath overrides the `codex` binary. Empty resolves from PATH.
	CLIPath string
	// OnStderr receives the app-server's stderr lines. Codex logs warnings
	// there routinely, so this is diagnostics rather than failure.
	OnStderr func(string)
}

// New spawns the app-server and completes the initialize handshake.
func New(ctx context.Context, opts Options) (*Client, error) {
	bin := opts.CLIPath
	if bin == "" {
		bin = "codex"
	}
	// Detached from ctx on purpose: the client outlives the call that made
	// it, and Close is what stops the process.
	cmd := exec.Command(bin, "app-server")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("codexsdk: stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("codexsdk: stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("codexsdk: stderr: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("codexsdk: start %q: %w", bin, err)
	}

	c := &Client{
		cmd:     cmd,
		stdin:   stdin,
		enc:     json.NewEncoder(stdin),
		pending: map[int64]chan response{},
		subs:    map[string]chan<- Event{},
		exited:  make(chan struct{}),
	}
	go c.readLoop(stdout)
	go c.drainStderr(stderr, opts.OnStderr)

	if _, err := c.call(ctx, "initialize", initializeParams{
		ClientInfo: clientInfo{Name: "psmith", Version: "1"},
	}); err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("codexsdk: initialize: %w", err)
	}
	return c, nil
}

func (c *Client) drainStderr(r io.Reader, cb func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if cb != nil {
			cb(sc.Text())
		}
	}
}

// readLoop demultiplexes responses and notifications until stdout closes.
func (c *Client) readLoop(r io.Reader) {
	defer close(c.exited)
	sc := bufio.NewScanner(r)
	// App-server lines carry whole turns of content, so the default 64K
	// scanner limit is not enough.
	sc.Buffer(make([]byte, 0, 256*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg response
		if err := json.Unmarshal(line, &msg); err != nil {
			continue // not our framing; ignore rather than die
		}
		switch {
		case msg.ID != nil && msg.Method == "":
			// A response to something we asked.
			c.deliverResult(*msg.ID, msg)
		case msg.ID != nil && msg.Method != "":
			// A REQUEST from the server, which is waiting on our answer.
			// Distinguished from a notification only by carrying an id, and
			// getting that wrong is what made turns hang: an unanswered
			// approval request stalls the turn forever, so turn/completed
			// never arrives and the caller's channel never closes.
			c.answerServerRequest(*msg.ID, msg.Method)
		case msg.Method != "":
			c.deliverNotification(msg)
		}
	}
	c.exitErr = c.cmd.Wait()
	c.failPending()
}

// answerServerRequest declines anything the server asks us to decide.
//
// Codex asks the client to approve command execution, file changes, tool calls
// and MCP elicitations. A chat harness has no user sitting behind it to ask,
// and no business approving a command in the first place, so every request is
// declined.
//
// Answering at all is the part that matters. The server blocks the turn until
// it hears back, so silence is a hang rather than a refusal. The driver also
// pins the thread to read-only with approvals off, which should mean these
// never arrive; this is what makes a hang impossible if that ever fails to
// take effect.
func (c *Client) answerServerRequest(id int64, method string) {
	// "denied" is the ReviewDecision every approval-shaped request accepts.
	// Requests with other response shapes ignore the field and see an object
	// they can parse, which still unblocks them.
	resp := map[string]any{
		"id":     id,
		"result": map[string]any{"decision": "denied"},
	}
	c.writeMu.Lock()
	err := c.enc.Encode(resp)
	c.writeMu.Unlock()
	if err != nil {
		return
	}
	_ = method
}

func (c *Client) deliverResult(id int64, msg response) {
	c.mu.Lock()
	ch, ok := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if ok {
		ch <- msg
		close(ch)
	}
}

// failPending unblocks every in-flight call when the process dies, so a
// crashed app-server surfaces as an error rather than a hang.
func (c *Client) failPending() {
	c.mu.Lock()
	pending := c.pending
	c.pending = map[int64]chan response{}
	subs := c.subs
	c.subs = map[string]chan<- Event{}
	c.mu.Unlock()

	for _, ch := range pending {
		ch <- response{Error: &rpcError{Message: "app-server exited"}}
		close(ch)
	}
	for _, sub := range subs {
		close(sub)
	}
}

func (c *Client) call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	if c.closed.Load() {
		return nil, errors.New("codexsdk: client is closed")
	}
	id := c.nextID.Add(1)
	ch := make(chan response, 1)

	c.mu.Lock()
	c.pending[id] = ch
	c.mu.Unlock()

	c.writeMu.Lock()
	err := c.enc.Encode(request{ID: id, Method: method, Params: params})
	c.writeMu.Unlock()
	if err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("codexsdk: write %s: %w", method, err)
	}

	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, ctx.Err()
	case resp := <-ch:
		if resp.Error != nil {
			return nil, fmt.Errorf("codexsdk: %s: %s", method, resp.Error.Message)
		}
		return resp.Result, nil
	}
}

// Close stops the subprocess.
func (c *Client) Close() error {
	if c.closed.Swap(true) {
		return nil
	}
	_ = c.stdin.Close()
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	<-c.exited
	return nil
}

// interruptTimeout bounds the best-effort interrupt sent when a caller
// cancels a turn. Short: the caller has already walked away.
const interruptTimeout = 5 * time.Second
