package plugins

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// MCPName is the registered name for the MCP-server bridge plugin.
//
// One plugin instance = one MCP server. Users attach this plugin to a
// profile once per MCP server they want available; each instance carries
// its own command/args/env. Tool calls the model emits get dispatched
// to the right server via the conversations-side tool loop's
// owner-by-name map (so two MCP plugins can coexist as long as their
// tool names don't collide — see ToolPrefix config below).
const MCPName = "mcp"

// MCP protocol version this client speaks. Servers negotiate down via
// the initialize handshake; we accept whatever they reply with as long
// as the connection succeeds.
const mcpProtocolVersion = "2024-11-05"

// Idle window after which an unused MCP subprocess is reaped from the
// pool. Re-spawned automatically on the next call. Generous enough
// that a few minutes between turns doesn't cost a cold start; tight
// enough that long-idle servers (a profile not used for hours) don't
// hold subprocess + memory.
const mcpIdleReap = 5 * time.Minute

// Per-call deadline for tools/call. MCP servers vary wildly — a
// filesystem read is sub-millisecond, a remote-API wrapper might take
// seconds. 60s gives slow tools room while still preventing infinite
// hangs.
const mcpCallTimeout = 60 * time.Second

// ---------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------

type mcpPlugin struct {
	cfg  mcpConfig
	spec mcpServerSpec
}

type mcpConfig struct {
	// Command is the executable to spawn. Plain path or PATH-resolved
	// name (e.g. "npx", "/usr/local/bin/uvx", "python3"). No shell
	// parsing — the value is exec'd directly.
	Command string `json:"command"`
	// Args is one CLI argument per line. Whitespace is preserved
	// within an arg; lines are stripped of trailing/leading whitespace.
	// Empty lines are skipped.
	Args string `json:"args"`
	// Env is "KEY=VALUE" per line. Inherited environment is NOT
	// included — only what's listed here reaches the subprocess. (For
	// servers that need PATH or HOME, declare them explicitly.)
	Env string `json:"env"`
	// ToolPrefix is prepended to each tool name reported by the server,
	// joined with an underscore. Empty = no prefix. Use this when two
	// MCP plugin instances expose tools with the same name (the
	// conversations-side tool loop's owner-by-name map silently drops
	// duplicates; the prefix avoids the collision).
	ToolPrefix string `json:"tool_prefix"`
}

func newMCP(configBytes json.RawMessage) (Plugin, error) {
	cfg := mcpConfig{}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("mcp: parse config: %w", err)
		}
	}
	cfg.Command = strings.TrimSpace(cfg.Command)
	if cfg.Command == "" {
		// nil-config Build (used by Describe) is OK — we just register
		// an unconfigured plugin. The constructor's downstream Tools()
		// call would no-op + log; the UI surfaces the missing-required
		// field via the descriptor.
	}
	spec := mcpServerSpec{
		Command: cfg.Command,
		Args:    splitLines(cfg.Args),
		Env:     splitLines(cfg.Env),
	}
	return &mcpPlugin{cfg: cfg, spec: spec}, nil
}

func init() {
	Register(MCPName, newMCP)
}

func (p *mcpPlugin) Name() string        { return MCPName }
func (p *mcpPlugin) DisplayName() string { return "MCP Server" }

func (p *mcpPlugin) Description() string {
	return "Bridges any Model Context Protocol (MCP) server's tools into Reeve's tool surface. " +
		"Spawns the configured command as a subprocess, exchanges JSON-RPC over stdio, and " +
		"exposes each server-declared tool to the model. One plugin instance per server."
}

// --- Configurable ---

func (p *mcpPlugin) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "command",
			Display:     "Command",
			Description: "Executable to spawn (resolved against PATH). e.g. npx, uvx, python3, /usr/local/bin/your-mcp-server.",
			Type:        ConfigFieldText,
			Required:    true,
		},
		{
			Name:        "args",
			Display:     "Arguments",
			Description: "One CLI arg per line. Whitespace preserved within an arg; empty lines skipped. e.g. -y\\n@modelcontextprotocol/server-filesystem\\n/Users/me/Documents.",
			Type:        ConfigFieldTextarea,
		},
		{
			Name:        "env",
			Display:     "Environment variables",
			Description: "KEY=VALUE per line. The subprocess inherits NOTHING from reeved's environment — declare what the server needs (PATH, HOME, API keys, etc.) explicitly here.",
			Type:        ConfigFieldTextarea,
		},
		{
			Name:        "tool_prefix",
			Display:     "Tool name prefix",
			Description: "Optional. Prepended to every tool name (joined with an underscore) so two MCP servers exposing the same tool don't collide.",
			Type:        ConfigFieldText,
		},
	}
}

// --- ToolProvider ---

func (p *mcpPlugin) Tools() []ToolDef {
	if p.cfg.Command == "" {
		return nil
	}
	srv, err := mcpPool.get(context.Background(), p.spec)
	if err != nil {
		return nil
	}
	tools := srv.toolsSnapshot()
	if p.cfg.ToolPrefix == "" {
		return tools
	}
	out := make([]ToolDef, len(tools))
	for i, t := range tools {
		out[i] = ToolDef{
			Name:        p.cfg.ToolPrefix + "_" + t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		}
	}
	return out
}

func (p *mcpPlugin) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error) {
	if p.cfg.Command == "" {
		return nil, errors.New("mcp: command not configured")
	}
	realName := name
	if p.cfg.ToolPrefix != "" {
		realName = strings.TrimPrefix(name, p.cfg.ToolPrefix+"_")
	}
	srv, err := mcpPool.get(ctx, p.spec)
	if err != nil {
		return nil, err
	}
	callCtx, cancel := context.WithTimeout(ctx, mcpCallTimeout)
	defer cancel()
	return srv.callTool(callCtx, realName, input)
}

// ---------------------------------------------------------------------------
// Server pool
// ---------------------------------------------------------------------------

// mcpServerSpec is the keying tuple for a server in the pool. Two
// plugin instances with identical Command/Args/Env share one
// subprocess.
type mcpServerSpec struct {
	Command string
	Args    []string
	Env     []string
}

func (s mcpServerSpec) hash() string {
	h := sha256.New()
	enc := json.NewEncoder(h)
	_ = enc.Encode(s)
	return hex.EncodeToString(h.Sum(nil))
}

// mcpServerPool caches live MCP subprocesses keyed by spec. Entries
// stay alive across SendMessage calls; the reaper goroutine kills
// idle entries after mcpIdleReap.
type mcpServerPool struct {
	mu      sync.Mutex
	servers map[string]*mcpServer
	once    sync.Once
}

var mcpPool = &mcpServerPool{servers: map[string]*mcpServer{}}

// get returns a live server for the spec, spawning if necessary.
// Multiple concurrent get() calls for the same spec coalesce on the
// first spawn; the per-server `start` mutex blocks the others until
// the handshake completes.
func (p *mcpServerPool) get(ctx context.Context, spec mcpServerSpec) (*mcpServer, error) {
	p.once.Do(p.startReaper)

	p.mu.Lock()
	srv, exists := p.servers[spec.hash()]
	if !exists {
		srv = &mcpServer{spec: spec, lastUsed: time.Now()}
		p.servers[spec.hash()] = srv
	}
	p.mu.Unlock()

	if err := srv.ensureStarted(ctx); err != nil {
		// Spawn failed — drop the cached entry so the next call
		// retries from scratch instead of being stuck on a dead one.
		p.mu.Lock()
		delete(p.servers, spec.hash())
		p.mu.Unlock()
		return nil, err
	}
	srv.touch()
	return srv, nil
}

func (p *mcpServerPool) startReaper() {
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			p.reapIdle()
		}
	}()
}

func (p *mcpServerPool) reapIdle() {
	now := time.Now()
	var toKill []*mcpServer
	p.mu.Lock()
	for k, s := range p.servers {
		if now.Sub(s.lastUsed) > mcpIdleReap {
			toKill = append(toKill, s)
			delete(p.servers, k)
		}
	}
	p.mu.Unlock()
	for _, s := range toKill {
		s.shutdown()
	}
}

// ---------------------------------------------------------------------------
// One MCP server (subprocess + JSON-RPC)
// ---------------------------------------------------------------------------

type mcpServer struct {
	spec mcpServerSpec

	startMu sync.Mutex // serializes spawn + handshake
	started bool

	// Per-call mutex: this v1 client is single-flight. tools/call
	// requests serialize on this mutex. Plenty for the typical "one
	// call per tool round" pattern; can grow to async dispatch when a
	// real workload demands it.
	callMu sync.Mutex
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader
	nextID atomic.Int64

	toolsMu sync.RWMutex
	tools   []ToolDef

	mu       sync.Mutex
	lastUsed time.Time
}

func (s *mcpServer) ensureStarted(ctx context.Context) error {
	s.startMu.Lock()
	defer s.startMu.Unlock()
	if s.started {
		return nil
	}
	if err := s.spawn(ctx); err != nil {
		return fmt.Errorf("mcp spawn %q: %w", s.spec.Command, err)
	}
	if err := s.handshake(ctx); err != nil {
		s.shutdown()
		return fmt.Errorf("mcp handshake: %w", err)
	}
	if err := s.loadTools(ctx); err != nil {
		s.shutdown()
		return fmt.Errorf("mcp tools/list: %w", err)
	}
	s.started = true
	return nil
}

func (s *mcpServer) spawn(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, s.spec.Command, s.spec.Args...)
	cmd.Env = s.spec.Env

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	// Stderr deliberately discarded — MCP servers vary wildly in how
	// chatty they are. A future enhancement could surface stderr in
	// the plugin's "diagnostics" UI; not in v1.
	cmd.Stderr = io.Discard

	if err := cmd.Start(); err != nil {
		return err
	}
	s.cmd = cmd
	s.stdin = stdin
	s.stdout = bufio.NewReader(stdout)
	return nil
}

func (s *mcpServer) handshake(ctx context.Context) error {
	var initResp struct {
		ProtocolVersion string `json:"protocolVersion"`
		ServerInfo      struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
	}
	if err := s.call(ctx, "initialize", map[string]any{
		"protocolVersion": mcpProtocolVersion,
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "reeve",
			"version": "0.1",
		},
	}, &initResp); err != nil {
		return err
	}
	// MCP spec wants a notifications/initialized after the response.
	// No reply expected; fire-and-forget.
	return s.notify("notifications/initialized", nil)
}

func (s *mcpServer) loadTools(ctx context.Context) error {
	var resp struct {
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := s.call(ctx, "tools/list", nil, &resp); err != nil {
		return err
	}
	tools := make([]ToolDef, 0, len(resp.Tools))
	for _, t := range resp.Tools {
		tools = append(tools, ToolDef{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		})
	}
	s.toolsMu.Lock()
	s.tools = tools
	s.toolsMu.Unlock()
	return nil
}

func (s *mcpServer) toolsSnapshot() []ToolDef {
	s.toolsMu.RLock()
	defer s.toolsMu.RUnlock()
	out := make([]ToolDef, len(s.tools))
	copy(out, s.tools)
	return out
}

func (s *mcpServer) callTool(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error) {
	args := input
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	var resp struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
			// Image / resource parts are accepted but discarded for v1.
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := s.call(ctx, "tools/call", map[string]any{
		"name":      name,
		"arguments": args,
	}, &resp); err != nil {
		return nil, err
	}
	// Concatenate text parts. Non-text parts are dropped; flag in the
	// response so the model sees something rather than silent truncation.
	var b strings.Builder
	dropped := 0
	for _, part := range resp.Content {
		if part.Type == "text" {
			b.WriteString(part.Text)
		} else {
			dropped++
		}
	}
	out := map[string]any{"text": b.String()}
	if dropped > 0 {
		out["dropped_non_text_parts"] = dropped
	}
	if resp.IsError {
		out["is_error"] = true
	}
	return json.Marshal(out)
}

func (s *mcpServer) touch() {
	s.mu.Lock()
	s.lastUsed = time.Now()
	s.mu.Unlock()
}

func (s *mcpServer) shutdown() {
	if s.stdin != nil {
		_ = s.stdin.Close()
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
		_, _ = s.cmd.Process.Wait()
	}
	s.started = false
}

// ---------------------------------------------------------------------------
// JSON-RPC over stdio
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int64  `json:"id,omitempty"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int64           `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error"`
	// Notifications have no `id`; we use Method to filter them out
	// during the read loop.
	Method string `json:"method"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func (e *rpcError) Error() string {
	if len(e.Data) > 0 {
		return fmt.Sprintf("rpc error %d: %s (data: %s)", e.Code, e.Message, string(e.Data))
	}
	return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message)
}

// call writes a JSON-RPC request and reads responses until it sees one
// matching the request id (skipping notifications). Single-flight via
// the per-server callMu.
func (s *mcpServer) call(ctx context.Context, method string, params any, into any) error {
	s.callMu.Lock()
	defer s.callMu.Unlock()

	id := s.nextID.Add(1)
	req := rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params}
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if _, err := s.stdin.Write(append(body, '\n')); err != nil {
		return fmt.Errorf("write rpc: %w", err)
	}

	// Read responses until we see one matching `id`. Notifications
	// (Method != "" + ID == 0) get logged-and-skipped; real responses
	// for OTHER ids would be a protocol bug since we're single-flight,
	// but we tolerate them defensively.
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line, err := s.stdout.ReadBytes('\n')
		if err != nil {
			return fmt.Errorf("read rpc: %w", err)
		}
		var resp rpcResponse
		if err := json.Unmarshal(line, &resp); err != nil {
			// Malformed line — skip rather than abort. MCP servers
			// occasionally emit progress messages that don't match
			// the JSON-RPC schema strictly.
			continue
		}
		if resp.Method != "" && resp.ID == 0 {
			// Server-initiated notification (logging, progress,
			// resource list updates, etc). Ignore in v1.
			continue
		}
		if resp.ID != id {
			// Stale response from a prior call. Shouldn't happen
			// given single-flight callMu, but skip defensively.
			continue
		}
		if resp.Error != nil {
			return resp.Error
		}
		if into != nil {
			return json.Unmarshal(resp.Result, into)
		}
		return nil
	}
}

// notify sends a notification (no id, no response expected).
func (s *mcpServer) notify(method string, params any) error {
	s.callMu.Lock()
	defer s.callMu.Unlock()
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{JSONRPC: "2.0", Method: method, Params: params})
	if err != nil {
		return err
	}
	if _, err := s.stdin.Write(append(body, '\n')); err != nil {
		return fmt.Errorf("write notify: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// splitLines splits a textarea value into a list of trimmed non-empty
// entries. Used for both args and env config fields.
func splitLines(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			out = append(out, t)
		}
	}
	return out
}
