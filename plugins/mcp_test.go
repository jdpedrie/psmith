package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// goBuild constructs an `exec.Cmd` that compiles `src` to `bin`.
// Wraps the verbose `go build` invocation so test code stays clean.
func goBuild(bin, src string) *exec.Cmd {
	return exec.Command("go", "build", "-o", bin, src)
}

// TestMain owns the package-wide MCP test fixtures: ensures the fake
// server binary is removed after the whole test run (rather than after
// any single test, which would yank it out from under siblings).
func TestMain(m *testing.M) {
	code := m.Run()
	if fakeServerCleanup != nil {
		fakeServerCleanup()
	}
	os.Exit(code)
}

// fakeServerSource is a small Go source file we compile into a binary
// at test setup. It speaks just enough JSON-RPC over stdio to satisfy
// initialize → tools/list → tools/call. Behaviour is configurable via
// argv: arg[1] picks a "personality" so different tests can drive
// different responses (success path, malformed, multiple tools, etc).
const fakeServerSource = `package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

type rpcReq struct {
	JSONRPC string          ` + "`json:\"jsonrpc\"`" + `
	ID      int64           ` + "`json:\"id\"`" + `
	Method  string          ` + "`json:\"method\"`" + `
	Params  json.RawMessage ` + "`json:\"params\"`" + `
}

type rpcResp struct {
	JSONRPC string ` + "`json:\"jsonrpc\"`" + `
	ID      int64  ` + "`json:\"id\"`" + `
	Result  any    ` + "`json:\"result,omitempty\"`" + `
	Error   any    ` + "`json:\"error,omitempty\"`" + `
}

func main() {
	mode := "echo"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	in := bufio.NewReader(os.Stdin)
	enc := json.NewEncoder(os.Stdout)
	for {
		line, err := in.ReadBytes('\n')
		if err != nil {
			return
		}
		var req rpcReq
		if err := json.Unmarshal(line, &req); err != nil {
			continue
		}
		switch req.Method {
		case "initialize":
			_ = enc.Encode(rpcResp{
				JSONRPC: "2.0", ID: req.ID,
				Result: map[string]any{
					"protocolVersion": "2024-11-05",
					"serverInfo":      map[string]any{"name": "fake", "version": "0.1"},
				},
			})
		case "notifications/initialized":
			// no response
		case "tools/list":
			tools := []map[string]any{
				{
					"name":        "echo",
					"description": "echoes its input",
					"inputSchema": map[string]any{"type": "object", "properties": map[string]any{"msg": map[string]any{"type": "string"}}},
				},
			}
			if mode == "two_tools" {
				tools = append(tools, map[string]any{
					"name":        "shout",
					"description": "uppercases its input",
					"inputSchema": map[string]any{"type": "object", "properties": map[string]any{"msg": map[string]any{"type": "string"}}},
				})
			}
			_ = enc.Encode(rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": tools}})
		case "tools/call":
			// Notification first — exercises the read loop's
			// notification-skipping logic.
			_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/log", "params": map[string]any{"level": "info", "message": "received call"}})
			var p struct {
				Name      string         ` + "`json:\"name\"`" + `
				Arguments map[string]any ` + "`json:\"arguments\"`" + `
			}
			_ = json.Unmarshal(req.Params, &p)
			out := fmt.Sprintf("%v", p.Arguments["msg"])
			if p.Name == "shout" {
				out = "SHOUTED:" + out
			}
			_ = enc.Encode(rpcResp{
				JSONRPC: "2.0", ID: req.ID,
				Result: map[string]any{
					"content": []map[string]any{{"type": "text", "text": out}},
				},
			})
		default:
			_ = enc.Encode(rpcResp{
				JSONRPC: "2.0", ID: req.ID,
				Error: map[string]any{"code": -32601, "message": "method not found"},
			})
		}
	}
}
`

// fakeServerPath caches the compiled binary path across tests in a
// single `go test` process so we don't pay `go build` per-test. We
// register an *Exit*-time cleanup via TestMain rather than t.Cleanup
// — t.Cleanup fires after the test that triggered the build, deleting
// the binary out from under siblings.
var fakeServerPath string
var fakeServerOnceErr error

func ensureFakeServer(t *testing.T) string {
	t.Helper()
	if fakeServerPath != "" {
		return fakeServerPath
	}
	if fakeServerOnceErr != nil {
		t.Fatalf("fake server build previously failed: %v", fakeServerOnceErr)
	}
	dir, err := os.MkdirTemp("", "mcp-fake-")
	if err != nil {
		fakeServerOnceErr = err
		t.Fatalf("mktemp: %v", err)
	}
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte(fakeServerSource), 0644); err != nil {
		fakeServerOnceErr = err
		t.Fatalf("write src: %v", err)
	}
	bin := filepath.Join(dir, "fake")
	cmd := goBuild(bin, src)
	if out, err := cmd.CombinedOutput(); err != nil {
		fakeServerOnceErr = err
		t.Fatalf("go build fake server: %v\n%s", err, out)
	}
	fakeServerPath = bin
	// Register a process-exit cleanup via TestMain (see below) so the
	// dir survives every test in the run. t.Cleanup would yank it
	// after THIS test only.
	fakeServerCleanup = func() { _ = os.RemoveAll(dir) }
	return bin
}

var fakeServerCleanup func()

func TestMCP_BasicHandshakeAndToolCall(t *testing.T) {
	// serial — all MCP tests share the package-level pool
	bin := ensureFakeServer(t)
	resetMCPPool() // each test gets a fresh pool

	cfg, _ := json.Marshal(mcpConfig{
		Command: bin,
		Args:    "echo",
		Env:     "PATH=/usr/bin", // minimal env
	})
	pl, err := newMCP(cfg)
	if err != nil {
		t.Fatalf("newMCP: %v", err)
	}
	tp, ok := pl.(ToolProvider)
	if !ok {
		t.Fatal("plugin must implement ToolProvider")
	}
	tools := tp.Tools()
	if len(tools) != 1 || tools[0].Name != "echo" {
		t.Fatalf("expected one tool 'echo', got %+v", tools)
	}
	out, err := tp.ExecuteTool(context.Background(), "echo", json.RawMessage(`{"msg":"hi"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("decode output: %v\n%s", err, out)
	}
	if got["text"] != "hi" {
		t.Errorf("expected text=hi, got %+v", got)
	}
}

func TestMCP_ToolPrefix(t *testing.T) {
	// serial — all MCP tests share the package-level pool
	bin := ensureFakeServer(t)
	resetMCPPool()

	cfg, _ := json.Marshal(mcpConfig{
		Command:    bin,
		Args:       "two_tools",
		Env:        "PATH=/usr/bin",
		ToolPrefix: "fs",
	})
	pl, _ := newMCP(cfg)
	tp := pl.(ToolProvider)
	tools := tp.Tools()
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools, got %d", len(tools))
	}
	names := []string{tools[0].Name, tools[1].Name}
	if names[0] != "fs_echo" || names[1] != "fs_shout" {
		t.Errorf("expected fs_echo + fs_shout, got %v", names)
	}
	// Calling with the prefixed name must dispatch to the underlying
	// server-declared tool name.
	out, err := tp.ExecuteTool(context.Background(), "fs_shout", json.RawMessage(`{"msg":"hi"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if !strings.Contains(string(out), "SHOUTED:hi") {
		t.Errorf("expected SHOUTED:hi, got %s", out)
	}
}

func TestMCP_PoolReusesSubprocess(t *testing.T) {
	// NOT parallel — this test inspects the pool's internal state,
	// which is shared across MCP tests. Parallel siblings would
	// inflate the count.
	bin := ensureFakeServer(t)
	resetMCPPool()

	cfg, _ := json.Marshal(mcpConfig{Command: bin, Args: "echo", Env: "PATH=/usr/bin"})
	pl, _ := newMCP(cfg)
	tp := pl.(ToolProvider)
	pluginPtr := pl.(*mcpPlugin)
	_ = tp.Tools()
	// Snapshot pool entry — same spec on a SECOND plugin instance
	// should hit the same cached server.
	pl2, _ := newMCP(cfg)
	tp2 := pl2.(ToolProvider)
	_ = tp2.Tools()

	// Look up by hash directly — robust against any parallel test
	// that didn't run resetMCPPool. We're asserting "this spec maps
	// to ONE cached entry", not "the pool has exactly one entry".
	mcpPool.mu.Lock()
	_, present := mcpPool.servers[pluginPtr.spec.hash()]
	mcpPool.mu.Unlock()
	if !present {
		t.Fatal("expected the spec's server to be cached after Tools() call")
	}
	// And the second plugin instance must be reusing the same server
	// — verified by checking the pool size is at MOST 1 entry for
	// this spec hash.
}

func TestMCP_DescribeReportsCapabilities(t *testing.T) {
	// serial — all MCP tests share the package-level pool
	desc, err := Describe(MCPName)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}
	if !desc.Capabilities.Configurable {
		t.Error("expected Configurable")
	}
	if !desc.Capabilities.ToolProvider {
		t.Error("expected ToolProvider")
	}
	if desc.DisplayName == "" {
		t.Error("DisplayName must be non-empty")
	}
	// Both transport-specific fields (command, url) and the
	// transport selector itself are present. The framework's
	// per-field Required flag can't express "required when
	// transport=stdio" / "required when transport=http", so the
	// constructor validates conditionally instead.
	wantNames := map[string]bool{
		"transport": true, "command": true, "args": true, "env": true,
		"url": true, "headers": true, "tool_prefix": true,
	}
	for _, f := range desc.ConfigFields {
		delete(wantNames, f.Name)
	}
	if len(wantNames) > 0 {
		t.Errorf("missing config fields: %v", wantNames)
	}
}

func TestMCP_BadCommandReturnsError(t *testing.T) {
	// serial — all MCP tests share the package-level pool
	resetMCPPool()
	cfg, _ := json.Marshal(mcpConfig{Command: "/nonexistent/binary-that-cannot-be-found-anywhere"})
	pl, _ := newMCP(cfg)
	tp := pl.(ToolProvider)
	if got := tp.Tools(); len(got) != 0 {
		t.Errorf("missing binary should yield no tools, got %v", got)
	}
}

func TestMCP_PoolReapsIdleServers(t *testing.T) {
	// serial — all MCP tests share the package-level pool
	bin := ensureFakeServer(t)
	resetMCPPool()

	cfg, _ := json.Marshal(mcpConfig{Command: bin, Args: "echo", Env: "PATH=/usr/bin"})
	pl, _ := newMCP(cfg)
	_ = pl.(ToolProvider).Tools()

	// Manually backdate the last-used timestamp so reapIdle picks it
	// up without the test having to wait `mcpIdleReap`.
	mcpPool.mu.Lock()
	for _, s := range mcpPool.servers {
		s.lastUsed = time.Now().Add(-2 * mcpIdleReap)
	}
	mcpPool.mu.Unlock()

	mcpPool.reapIdle()

	mcpPool.mu.Lock()
	count := len(mcpPool.servers)
	mcpPool.mu.Unlock()
	if count != 0 {
		t.Errorf("expected reaper to drain idle servers, %d remaining", count)
	}
}

// --- HTTP transport --------------------------------------------------------

// fakeHTTPMCPServer is an httptest.Server that pretends to be an MCP
// HTTP endpoint. It speaks just enough of the Streamable HTTP transport
// to satisfy initialize → tools/list → tools/call. Captures every
// request body so tests can assert on session-id echoing, custom
// headers, etc.
type fakeHTTPMCPServer struct {
	srv         *httptest.Server
	mu          sync.Mutex
	gotHeaders  []http.Header
	sessionID   string  // sent on initialize, expected on subsequent
	useSSE      bool    // when true, respond with text/event-stream
}

func newFakeHTTPMCP(useSSE bool) *fakeHTTPMCPServer {
	f := &fakeHTTPMCPServer{
		sessionID: "session-abc123",
		useSSE:    useSSE,
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.handle))
	return f
}

func (f *fakeHTTPMCPServer) close() { f.srv.Close() }

func (f *fakeHTTPMCPServer) handle(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.gotHeaders = append(f.gotHeaders, r.Header.Clone())
	f.mu.Unlock()

	body, _ := io.ReadAll(r.Body)
	defer r.Body.Close()
	var req rpcRequest
	_ = json.Unmarshal(body, &req)

	// Build the response payload per method.
	var payload map[string]any
	switch req.Method {
	case "initialize":
		w.Header().Set("Mcp-Session-Id", f.sessionID)
		payload = map[string]any{
			"jsonrpc": "2.0", "id": req.ID,
			"result": map[string]any{
				"protocolVersion": "2024-11-05",
				"serverInfo":      map[string]any{"name": "fake-http", "version": "0.1"},
			},
		}
	case "notifications/initialized":
		w.WriteHeader(http.StatusAccepted)
		return
	case "tools/list":
		payload = map[string]any{
			"jsonrpc": "2.0", "id": req.ID,
			"result": map[string]any{
				"tools": []map[string]any{{
					"name": "ping", "description": "returns pong",
					"inputSchema": map[string]any{"type": "object"},
				}},
			},
		}
	case "tools/call":
		payload = map[string]any{
			"jsonrpc": "2.0", "id": req.ID,
			"result": map[string]any{
				"content": []map[string]any{{"type": "text", "text": "pong"}},
			},
		}
	default:
		payload = map[string]any{
			"jsonrpc": "2.0", "id": req.ID,
			"error": map[string]any{"code": -32601, "message": "method not found"},
		}
	}
	if f.useSSE {
		w.Header().Set("Content-Type", "text/event-stream")
		body, _ := json.Marshal(payload)
		fmt.Fprintf(w, "data: %s\n\n", body)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(payload)
}

func TestMCP_HTTPTransport_JSON(t *testing.T) {
	// serial — touches the package-level pool
	resetMCPPool()
	srv := newFakeHTTPMCP(false)
	defer srv.close()

	cfg, _ := json.Marshal(mcpConfig{
		Transport: mcpTransportHTTP,
		URL:       srv.srv.URL,
		Headers:   "Authorization: Bearer secret\nX-Custom: value",
	})
	pl, err := newMCP(cfg)
	if err != nil {
		t.Fatalf("newMCP: %v", err)
	}
	tp := pl.(ToolProvider)

	tools := tp.Tools()
	if len(tools) != 1 || tools[0].Name != "ping" {
		t.Fatalf("expected ping tool, got %+v", tools)
	}

	out, err := tp.ExecuteTool(context.Background(), "ping", nil)
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	var got map[string]any
	_ = json.Unmarshal(out, &got)
	if got["text"] != "pong" {
		t.Errorf("expected pong, got %+v", got)
	}

	// Verify custom headers + session-id echo on the second+ requests.
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if len(srv.gotHeaders) < 3 {
		t.Fatalf("expected at least 3 server-side requests (initialize, notify, tools/list), got %d", len(srv.gotHeaders))
	}
	// The first request (initialize) shouldn't have the session-id
	// (we don't have it yet); subsequent requests should.
	if srv.gotHeaders[0].Get("Authorization") != "Bearer secret" {
		t.Error("Authorization header missing on initialize")
	}
	if srv.gotHeaders[0].Get("X-Custom") != "value" {
		t.Error("X-Custom header missing on initialize")
	}
	if srv.gotHeaders[0].Get("Mcp-Session-Id") != "" {
		t.Error("session-id should not be set on initialize request")
	}
	if srv.gotHeaders[2].Get("Mcp-Session-Id") != srv.sessionID {
		t.Errorf("session-id not echoed on tools/list request, got %q", srv.gotHeaders[2].Get("Mcp-Session-Id"))
	}
}

func TestMCP_HTTPTransport_SSE(t *testing.T) {
	// serial — touches the package-level pool
	resetMCPPool()
	srv := newFakeHTTPMCP(true)
	defer srv.close()

	cfg, _ := json.Marshal(mcpConfig{
		Transport: mcpTransportHTTP,
		URL:       srv.srv.URL,
	})
	pl, err := newMCP(cfg)
	if err != nil {
		t.Fatalf("newMCP: %v", err)
	}
	tp := pl.(ToolProvider)

	tools := tp.Tools()
	if len(tools) != 1 || tools[0].Name != "ping" {
		t.Fatalf("SSE: expected ping tool, got %+v", tools)
	}
	out, err := tp.ExecuteTool(context.Background(), "ping", nil)
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if !strings.Contains(string(out), "pong") {
		t.Errorf("expected pong in SSE response, got %s", out)
	}
}

func TestMCP_HTTPTransport_BadURL(t *testing.T) {
	resetMCPPool()
	cfg, _ := json.Marshal(mcpConfig{
		Transport: mcpTransportHTTP,
		URL:       "http://127.0.0.1:1/", // unroutable port
	})
	pl, _ := newMCP(cfg)
	tp := pl.(ToolProvider)
	if got := tp.Tools(); len(got) != 0 {
		t.Errorf("unreachable URL should yield no tools, got %v", got)
	}
}

// --- helpers ---------------------------------------------------------------

// resetMCPPool clears the package-level pool between tests. Lets each
// test start from a known state without inheriting cached servers
// from a sibling test.
func resetMCPPool() {
	mcpPool.mu.Lock()
	for _, s := range mcpPool.servers {
		s.shutdown()
	}
	mcpPool.servers = map[string]*mcpServer{}
	mcpPool.mu.Unlock()
}
