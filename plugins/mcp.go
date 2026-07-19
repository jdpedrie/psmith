package plugins

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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
// its own command/args/env (stdio) or url/headers (http). Tool calls
// the model emits get dispatched to the right server via the
// conversations-side tool loop's owner-by-name map (so two MCP plugins
// can coexist as long as their tool names don't collide — see
// ToolPrefix config below).
const MCPName = "mcp"

// MCP transport selector values.
const (
	mcpTransportStdio  = "stdio"
	mcpTransportHTTP   = "http"
	mcpTransportInproc = "inproc"
)

// MCP protocol version this client speaks. Servers negotiate down via
// the initialize handshake; we accept whatever they reply with as long
// as the connection succeeds.
const mcpProtocolVersion = "2024-11-05"

// Idle window after which an unused MCP connection is reaped from the
// pool. For stdio that means killing the subprocess; for http that
// means dropping the cached session id (server-side resources free up
// on their own). Generous enough that a few minutes between turns
// don't cost a cold start; tight enough that long-idle servers don't
// hold subprocess + memory.
const mcpIdleReap = 5 * time.Minute

// Per-call deadline for tools/call. MCP servers vary wildly — a
// filesystem read is sub-millisecond, a remote-API wrapper might take
// seconds. 60s gives slow tools room while still preventing infinite
// hangs.
const mcpCallTimeout = 60 * time.Second

// HTTP-transport per-request timeout. Cheaper than mcpCallTimeout
// because most tools/list and tools/call HTTP exchanges should be
// fast — initialise can be slower (server warming up) but is itself
// timeout-bounded by ensureStarted's call timeout.
const mcpHTTPTimeout = 30 * time.Second

// ---------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------

type mcpPlugin struct {
	cfg  mcpConfig
	spec mcpServerSpec
}

type mcpConfig struct {
	// Transport picks how psmithd talks to the MCP server. One of
	// "stdio" (subprocess + JSON-RPC over stdin/stdout) or "http"
	// (Streamable HTTP — POST JSON-RPC to a URL, response is either
	// a single JSON body or an SSE stream we read the first event
	// from). Empty defaults to "stdio" so existing configs keep
	// working without migration.
	Transport string `json:"transport"`

	// --- stdio transport ---
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

	// --- http transport ---
	// URL is the full HTTP(S) endpoint that accepts JSON-RPC POSTs.
	// Required when Transport=="http".
	URL string `json:"url"`
	// Headers is "KEY: VALUE" per line of HTTP headers attached to
	// every request — most often `Authorization: Bearer …`. Empty
	// value lines are skipped.
	Headers string `json:"headers"`

	// --- shared ---
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
	cfg.Transport = strings.TrimSpace(cfg.Transport)
	if cfg.Transport == "" {
		cfg.Transport = mcpTransportStdio
	}
	cfg.Command = strings.TrimSpace(cfg.Command)
	cfg.URL = strings.TrimSpace(cfg.URL)
	switch cfg.Transport {
	case mcpTransportStdio, mcpTransportHTTP, mcpTransportInproc:
		// nil-config Build (used by Describe) is OK — we register
		// an unconfigured plugin. The descriptor's Required hint
		// surfaces the missing transport-specific field; downstream
		// Tools() / ExecuteTool calls no-op + log when fields are
		// missing.
	default:
		return nil, fmt.Errorf("mcp: unknown transport %q (want %q, %q, or %q)",
			cfg.Transport, mcpTransportStdio, mcpTransportHTTP, mcpTransportInproc)
	}
	spec := mcpServerSpec{
		Transport: cfg.Transport,
		Command:   cfg.Command,
		Args:      splitLines(cfg.Args),
		Env:       splitLines(cfg.Env),
		URL:       cfg.URL,
		Headers:   splitLines(cfg.Headers),
	}
	return &mcpPlugin{cfg: cfg, spec: spec}, nil
}

func init() {
	Register(MCPName, newMCP)
}

func (p *mcpPlugin) Name() string        { return MCPName }
func (p *mcpPlugin) DisplayName() string { return "MCP Server" }

func (p *mcpPlugin) Description() string {
	return "Bridges any Model Context Protocol (MCP) server's tools into Psmith's tool surface. " +
		"Two transports: stdio (spawn a local subprocess and exchange JSON-RPC over stdin/stdout) " +
		"and http (POST JSON-RPC to a remote URL — Streamable HTTP transport). Each server-declared " +
		"tool is exposed to the model; tool calls dispatch back to the right server. " +
		"One plugin instance per server."
}

// --- Configurable ---

func (p *mcpPlugin) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "transport",
			Display:     "Transport",
			Description: "stdio spawns a local subprocess; http POSTs JSON-RPC to a remote URL (Streamable HTTP); inproc dispatches to this Psmith instance's own MCP surface (no port, no token). Each transport uses a different subset of the fields below.",
			Type:        ConfigFieldSelect,
			Default:     mcpTransportStdio,
			Options: []ConfigOption{
				{Value: mcpTransportStdio, Label: "Stdio (subprocess)"},
				{Value: mcpTransportHTTP, Label: "HTTP (remote URL)"},
				{Value: mcpTransportInproc, Label: "In-process (this Psmith instance)"},
			},
		},
		{
			Name:        "command",
			Display:     "Command (stdio)",
			Description: "Executable to spawn for stdio transport. Resolved against PATH. e.g. npx, uvx, python3, /usr/local/bin/your-mcp-server. Ignored for http transport.",
			Type:        ConfigFieldText,
		},
		{
			Name:        "args",
			Display:     "Arguments (stdio)",
			Description: "One CLI arg per line for stdio transport. Whitespace preserved within an arg; empty lines skipped. e.g. -y\\n@modelcontextprotocol/server-filesystem\\n/Users/me/Documents.",
			Type:        ConfigFieldTextarea,
		},
		{
			Name:        "env",
			Display:     "Environment variables (stdio)",
			Description: "KEY=VALUE per line for stdio transport. The subprocess inherits NOTHING from psmithd's environment — declare what the server needs (PATH, HOME, API keys, etc.) explicitly here.",
			Type:        ConfigFieldTextarea,
		},
		{
			Name:        "url",
			Display:     "URL (http)",
			Description: "Full HTTP(S) endpoint that accepts JSON-RPC POSTs (Streamable HTTP transport). Ignored for stdio transport.",
			Type:        ConfigFieldText,
		},
		{
			Name:        "headers",
			Display:     "HTTP headers (http)",
			Description: "KEY: VALUE per line, attached to every HTTP request. Most often Authorization: Bearer YOUR_TOKEN. Ignored for stdio transport.",
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

// configValid returns true when the active transport's required
// fields are populated. Used by Tools() / ExecuteTool to no-op
// gracefully on a half-configured plugin (the UI surfaces the missing
// field separately via the descriptor + form validation).
func (p *mcpPlugin) configValid() bool {
	switch p.cfg.Transport {
	case mcpTransportStdio:
		return p.cfg.Command != ""
	case mcpTransportHTTP:
		return p.cfg.URL != ""
	case mcpTransportInproc:
		// Inproc takes no config — validity is "is a dispatcher
		// registered?" which we can only really check at call time.
		// Treat as always valid here so Tools() actually attempts
		// the lookup; the resulting error surfaces if the dispatcher
		// is missing (typically only in tests or partially-wired
		// environments).
		return true
	}
	return false
}

// --- ToolProvider ---

func (p *mcpPlugin) Tools() []ToolDef {
	if !p.configValid() {
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

func (p *mcpPlugin) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	if !p.configValid() {
		return ToolResult{}, errors.New("mcp: plugin not fully configured")
	}
	realName := name
	if p.cfg.ToolPrefix != "" {
		realName = strings.TrimPrefix(name, p.cfg.ToolPrefix+"_")
	}
	srv, err := mcpPool.get(ctx, p.spec)
	if err != nil {
		return ToolResult{}, err
	}
	callCtx, cancel := context.WithTimeout(ctx, mcpCallTimeout)
	defer cancel()
	return srv.callTool(callCtx, realName, input)
}

// TestMCPConnection dials the MCP server described by configBytes
// (the mcp plugin's config-blob shape), runs the initialize handshake
// plus tools/list through the shared pool, and returns the advertised
// tool names (unprefixed). Unlike Plugin.Tools() — which swallows
// connection errors so a dead server degrades to "no tools" mid-send
// — this surfaces the failure, which is the whole point of a Test
// button. A previously-pooled live connection answers from its cached
// tools snapshot; a previously-failed spec retries from scratch (the
// pool drops failed entries).
func TestMCPConnection(ctx context.Context, configBytes json.RawMessage) ([]string, error) {
	pl, err := Build(MCPName, configBytes)
	if err != nil {
		return nil, err
	}
	mp, ok := pl.(*mcpPlugin)
	if !ok {
		return nil, errors.New("mcp: unexpected plugin type")
	}
	if !mp.configValid() {
		return nil, errors.New("mcp: transport configuration incomplete")
	}
	srv, err := mcpPool.get(ctx, mp.spec)
	if err != nil {
		return nil, err
	}
	tools := srv.toolsSnapshot()
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		names = append(names, t.Name)
	}
	return names, nil
}

// ---------------------------------------------------------------------------
// Server pool
// ---------------------------------------------------------------------------

// mcpServerSpec is the keying tuple for a server in the pool. Two
// plugin instances with identical Transport + transport-specific
// fields share one connection. Transport is part of the hash so a
// stdio + http variant of the "same" spec are correctly distinct.
type mcpServerSpec struct {
	Transport string

	// stdio
	Command string
	Args    []string
	Env     []string

	// http
	URL     string
	Headers []string
}

func (s mcpServerSpec) hash() string {
	h := sha256.New()
	enc := json.NewEncoder(h)
	_ = enc.Encode(s)
	return hex.EncodeToString(h.Sum(nil))
}

// mcpServerPool caches live MCP connections keyed by spec. Entries
// stay alive across SendMessage calls; the reaper goroutine kills
// idle entries after mcpIdleReap.
type mcpServerPool struct {
	mu      sync.Mutex
	servers map[string]*mcpServer
	once    sync.Once
}

var mcpPool = &mcpServerPool{servers: map[string]*mcpServer{}}

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
		// Spawn / handshake failed — drop the cached entry so the
		// next call retries from scratch instead of being stuck on
		// a dead one.
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
// One MCP server (transport + handshake + tools cache)
// ---------------------------------------------------------------------------

type mcpServer struct {
	spec mcpServerSpec

	startMu   sync.Mutex // serializes spawn + handshake
	started   bool
	transport mcpTransport

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
	t, err := newTransport(ctx, s.spec)
	if err != nil {
		return err
	}
	s.transport = t
	if err := s.handshake(ctx); err != nil {
		s.transport.close()
		s.transport = nil
		return fmt.Errorf("mcp handshake: %w", err)
	}
	if err := s.loadTools(ctx); err != nil {
		s.transport.close()
		s.transport = nil
		return fmt.Errorf("mcp tools/list: %w", err)
	}
	s.started = true
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
	if err := s.transport.call(ctx, "initialize", map[string]any{
		"protocolVersion": mcpProtocolVersion,
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "psmith",
			"version": "0.1",
		},
	}, &initResp); err != nil {
		return err
	}
	// MCP spec wants a notifications/initialized after the response.
	// Fire-and-forget; failure shouldn't gate the server going live.
	_ = s.transport.notify("notifications/initialized", nil)
	return nil
}

func (s *mcpServer) loadTools(ctx context.Context) error {
	var resp struct {
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := s.transport.call(ctx, "tools/list", nil, &resp); err != nil {
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

func (s *mcpServer) callTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	args := input
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	// MCP content parts: text, image (base64 + mimeType), resource
	// (uri / blob / mimeType). Image parts become ToolAttachments;
	// resource parts of inline-blob shape do too. Anything else
	// still gets the dropped-count flag for the model.
	var resp struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			Data     string `json:"data"`
			MimeType string `json:"mimeType"`
			Resource *struct {
				URI      string `json:"uri"`
				MimeType string `json:"mimeType"`
				Blob     string `json:"blob"`
				Text     string `json:"text"`
			} `json:"resource"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := s.transport.call(ctx, "tools/call", map[string]any{
		"name":      name,
		"arguments": args,
	}, &resp); err != nil {
		return ToolResult{}, err
	}

	var b strings.Builder
	var attachments []ToolAttachment
	dropped := 0
	for _, part := range resp.Content {
		switch part.Type {
		case "text":
			b.WriteString(part.Text)
		case "image":
			data, err := base64.StdEncoding.DecodeString(part.Data)
			if err != nil || len(data) == 0 {
				dropped++
				continue
			}
			mime := part.MimeType
			if mime == "" {
				mime = "image/png"
			}
			attachments = append(attachments, ToolAttachment{
				Kind:     "image",
				MimeType: mime,
				Data:     data,
			})
		case "resource":
			r := part.Resource
			if r == nil {
				dropped++
				continue
			}
			// Inline blob: surface as an attachment, kind picked
			// from mime type. Bare URI references (no blob) get
			// dropped — we'd need a resources/read round-trip to
			// fetch them, which v1 skips.
			if r.Blob != "" {
				data, err := base64.StdEncoding.DecodeString(r.Blob)
				if err != nil || len(data) == 0 {
					dropped++
					continue
				}
				attachments = append(attachments, ToolAttachment{
					Kind:     kindForMime(r.MimeType),
					MimeType: r.MimeType,
					Data:     data,
					Filename: filenameFromURI(r.URI),
				})
			} else if r.Text != "" {
				b.WriteString(r.Text)
			} else {
				dropped++
			}
		default:
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
	if len(attachments) > 0 {
		// Hint to the model that the tool produced N attachments
		// the user can see — even if the upstream provider
		// doesn't carry them inline on the next round, the
		// model knows they exist and was the result of its call.
		out["attachment_count"] = len(attachments)
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Output: encoded, Attachments: attachments}, nil
}

// kindForMime maps a mime type to the providers.AttachmentKind
// string used by message_attachments rows. Same buckets the iOS
// composer uses on the upload side.
func kindForMime(mime string) string {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return "image"
	case strings.HasPrefix(mime, "audio/"):
		return "audio"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	default:
		return "document"
	}
}

// filenameFromURI extracts the last path component of a URI for
// use as a download-hint filename. Falls back to empty when the
// URI is malformed; the persistence layer is fine with no name.
func filenameFromURI(uri string) string {
	if uri == "" {
		return ""
	}
	if idx := strings.LastIndex(uri, "/"); idx >= 0 {
		return uri[idx+1:]
	}
	return uri
}

func (s *mcpServer) touch() {
	s.mu.Lock()
	s.lastUsed = time.Now()
	s.mu.Unlock()
}

func (s *mcpServer) shutdown() {
	if s.transport != nil {
		s.transport.close()
		s.transport = nil
	}
	s.started = false
}

// ---------------------------------------------------------------------------
// Transport interface + implementations
// ---------------------------------------------------------------------------

// mcpTransport is the small interface every MCP transport exposes to
// the server type. Each transport handles JSON-RPC framing, request
// IDs, response correlation, and notification skipping internally.
type mcpTransport interface {
	call(ctx context.Context, method string, params any, into any) error
	notify(method string, params any) error
	close()
}

func newTransport(ctx context.Context, spec mcpServerSpec) (mcpTransport, error) {
	switch spec.Transport {
	case mcpTransportStdio:
		return newStdioTransport(ctx, spec)
	case mcpTransportHTTP:
		return newHTTPTransport(ctx, spec)
	case mcpTransportInproc:
		return newInprocTransport(), nil
	default:
		return nil, fmt.Errorf("mcp: unknown transport %q", spec.Transport)
	}
}

// --- inproc transport (this-process MCP server) -----------------------------

// InprocDispatcher is the call-into-server hook the inproc transport
// dispatches against. Set by RegisterInprocMCPDispatcher (typically
// from cmd/psmithd/main.go pointing at the local mcpserver.Server's
// HandleRPC method). Takes a JSON-RPC request body and returns the
// JSON-RPC response body — same shape as the HTTP transport's wire
// format. Returning (nil, nil) means "this was a notification, no
// response."
type InprocDispatcher func(ctx context.Context, body []byte) ([]byte, error)

var (
	inprocMu       sync.RWMutex
	inprocDispatch InprocDispatcher
)

// RegisterInprocMCPDispatcher installs the in-process dispatcher used
// by mcp plugin instances configured with transport="inproc". Pass nil
// to clear. Safe to call from main.go before any plugin instances are
// constructed; tests can install a fake dispatcher per-test.
func RegisterInprocMCPDispatcher(d InprocDispatcher) {
	inprocMu.Lock()
	defer inprocMu.Unlock()
	inprocDispatch = d
}

func currentInprocDispatcher() InprocDispatcher {
	inprocMu.RLock()
	defer inprocMu.RUnlock()
	return inprocDispatch
}

// inprocTransport routes JSON-RPC calls through a registered
// in-process dispatcher. No subprocess, no network, no auth handshake
// — the authenticated user already on ctx flows through unchanged.
type inprocTransport struct {
	nextID atomic.Int64
}

func newInprocTransport() *inprocTransport {
	return &inprocTransport{}
}

func (t *inprocTransport) call(ctx context.Context, method string, params any, into any) error {
	d := currentInprocDispatcher()
	if d == nil {
		return errors.New("mcp inproc: no dispatcher registered (cmd/psmithd should call plugins.RegisterInprocMCPDispatcher at startup)")
	}
	id := t.nextID.Add(1)
	body, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		return err
	}
	respBody, err := d(ctx, body)
	if err != nil {
		return err
	}
	if len(respBody) == 0 {
		// Notification ack or empty success — nothing to decode.
		return nil
	}
	var rr rpcResponse
	if err := json.Unmarshal(respBody, &rr); err != nil {
		return fmt.Errorf("mcp inproc decode: %w", err)
	}
	if rr.Error != nil {
		return rr.Error
	}
	if into != nil && len(rr.Result) > 0 {
		return json.Unmarshal(rr.Result, into)
	}
	return nil
}

func (t *inprocTransport) notify(method string, params any) error {
	d := currentInprocDispatcher()
	if d == nil {
		// Notifications are best-effort even on the wire transports;
		// silently no-op when there's no dispatcher rather than
		// surfacing a non-actionable error.
		return nil
	}
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{JSONRPC: "2.0", Method: method, Params: params})
	if err != nil {
		return err
	}
	_, _ = d(context.Background(), body)
	return nil
}

func (t *inprocTransport) close() {
	// No resources held — nothing to tear down.
}

// --- stdio transport -------------------------------------------------------

type stdioTransport struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader

	callMu sync.Mutex // single-flight; tools/call requests serialize
	nextID atomic.Int64
}

func newStdioTransport(ctx context.Context, spec mcpServerSpec) (*stdioTransport, error) {
	cmd := exec.CommandContext(ctx, spec.Command, spec.Args...)
	cmd.Env = spec.Env

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	// Stderr deliberately discarded — MCP servers vary wildly in how
	// chatty they are. A future enhancement could surface stderr in
	// the plugin's "diagnostics" UI; not in v1.
	cmd.Stderr = io.Discard

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("mcp stdio spawn %q: %w", spec.Command, err)
	}
	return &stdioTransport{
		cmd:    cmd,
		stdin:  stdin,
		stdout: bufio.NewReader(stdout),
	}, nil
}

func (t *stdioTransport) call(ctx context.Context, method string, params any, into any) error {
	t.callMu.Lock()
	defer t.callMu.Unlock()

	id := t.nextID.Add(1)
	body, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		return err
	}
	if _, err := t.stdin.Write(append(body, '\n')); err != nil {
		return fmt.Errorf("write rpc: %w", err)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line, err := t.stdout.ReadBytes('\n')
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
			// Server-initiated notification — ignore in v1.
			continue
		}
		if resp.ID != id {
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

func (t *stdioTransport) notify(method string, params any) error {
	t.callMu.Lock()
	defer t.callMu.Unlock()
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{JSONRPC: "2.0", Method: method, Params: params})
	if err != nil {
		return err
	}
	_, err = t.stdin.Write(append(body, '\n'))
	return err
}

func (t *stdioTransport) close() {
	if t.stdin != nil {
		_ = t.stdin.Close()
	}
	if t.cmd != nil && t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
		_, _ = t.cmd.Process.Wait()
	}
}

// --- http transport (Streamable HTTP) --------------------------------------

// httpTransport speaks JSON-RPC over a single HTTP endpoint per the
// Streamable HTTP transport spec. Per-request: POST the JSON-RPC body;
// the response is either application/json (single message) or
// text/event-stream (SSE — for streaming responses + interleaved
// notifications). v1 expects only request/reply for tools/list and
// tools/call so we read the first SSE event when the server replies
// in stream mode and ignore the rest.
//
// Session handling: the server may return a Mcp-Session-Id header on
// initialize; we capture and echo it on every subsequent request so
// stateful servers (the common case for remote MCP) keep the session
// alive.
type httpTransport struct {
	url    string
	hdrs   http.Header
	client *http.Client

	callMu    sync.Mutex // single-flight, same as stdio
	nextID    atomic.Int64
	sessionID string
}

func newHTTPTransport(_ context.Context, spec mcpServerSpec) (*httpTransport, error) {
	if spec.URL == "" {
		return nil, errors.New("mcp http: url is required")
	}
	hdrs := http.Header{}
	for _, line := range spec.Headers {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		hdrs.Set(strings.TrimSpace(k), strings.TrimSpace(v))
	}
	return &httpTransport{
		url:    spec.URL,
		hdrs:   hdrs,
		client: &http.Client{Timeout: mcpHTTPTimeout},
	}, nil
}

func (t *httpTransport) call(ctx context.Context, method string, params any, into any) error {
	t.callMu.Lock()
	defer t.callMu.Unlock()

	id := t.nextID.Add(1)
	body, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		return err
	}

	resp, err := t.do(ctx, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Capture session id on whichever response surfaces it (typically
	// the initialize response). Per the spec the header is
	// Mcp-Session-Id; case-insensitive via http.Header.
	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" && t.sessionID == "" {
		t.sessionID = sid
	}

	rpcResp, err := readRPCResponse(resp, id)
	if err != nil {
		return err
	}
	if rpcResp.Error != nil {
		return rpcResp.Error
	}
	if into != nil {
		return json.Unmarshal(rpcResp.Result, into)
	}
	return nil
}

func (t *httpTransport) notify(method string, params any) error {
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  any    `json:"params,omitempty"`
	}{JSONRPC: "2.0", Method: method, Params: params})
	if err != nil {
		return err
	}
	// Notifications have no id and (per spec) the server replies with
	// 202 Accepted and no body. Failures are non-fatal — best-effort.
	resp, err := t.do(context.Background(), body)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func (t *httpTransport) close() {
	// HTTP transport keeps no persistent connection of its own; the
	// underlying http.Client's Transport pool drains naturally on
	// idle. Nothing to tear down explicitly.
}

func (t *httpTransport) do(ctx context.Context, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	for k, vs := range t.hdrs {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	if t.sessionID != "" {
		req.Header.Set("Mcp-Session-Id", t.sessionID)
	}
	resp, err := t.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("mcp http POST: %w", err)
	}
	if resp.StatusCode >= 400 {
		buf, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("mcp http %d: %s", resp.StatusCode, string(buf))
	}
	return resp, nil
}

// readRPCResponse decodes a server response, handling both
// application/json (single body) and text/event-stream (SSE — read
// the first JSON-RPC frame matching `wantID` and ignore the rest).
func readRPCResponse(resp *http.Response, wantID int64) (*rpcResponse, error) {
	ct := resp.Header.Get("Content-Type")
	if strings.Contains(ct, "text/event-stream") {
		return readSSEResponse(resp.Body, wantID)
	}
	// Plain JSON response. Notifications-only acknowledgements (202
	// Accepted, empty body) are handled by the caller via 0-length
	// reads; we treat an empty body as "no result" without erroring.
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("mcp http read: %w", err)
	}
	if len(body) == 0 {
		return &rpcResponse{ID: wantID}, nil
	}
	var rr rpcResponse
	if err := json.Unmarshal(body, &rr); err != nil {
		return nil, fmt.Errorf("mcp http decode: %w (body: %s)", err, string(body))
	}
	return &rr, nil
}

// readSSEResponse parses a `text/event-stream` body until it finds a
// JSON-RPC response matching `wantID`. Notifications and unrelated
// events get skipped. Returns an error when the stream closes
// without producing a matching response.
func readSSEResponse(body io.Reader, wantID int64) (*rpcResponse, error) {
	scanner := bufio.NewScanner(body)
	// Allow long single events — MCP responses can be large.
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	var dataAccum bytes.Buffer
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			// Event boundary — try to parse what we've accumulated.
			payload := dataAccum.Bytes()
			dataAccum.Reset()
			if len(payload) == 0 {
				continue
			}
			var rr rpcResponse
			if err := json.Unmarshal(payload, &rr); err != nil {
				continue
			}
			if rr.Method != "" && rr.ID == 0 {
				continue // server notification
			}
			if rr.ID != wantID {
				continue
			}
			return &rr, nil
		}
		if strings.HasPrefix(line, "data:") {
			payload := strings.TrimPrefix(line, "data:")
			payload = strings.TrimPrefix(payload, " ")
			if dataAccum.Len() > 0 {
				dataAccum.WriteByte('\n')
			}
			dataAccum.WriteString(payload)
		}
		// Other SSE fields (event:, id:, retry:) are ignored.
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("mcp sse read: %w", err)
	}
	return nil, fmt.Errorf("mcp sse: stream ended without response for id %d", wantID)
}

// ---------------------------------------------------------------------------
// JSON-RPC types (shared across transports)
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// splitLines splits a textarea value into a list of trimmed non-empty
// entries. Used for args, env, and headers config fields.
func splitLines(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			out = append(out, t)
		}
	}
	return out
}
