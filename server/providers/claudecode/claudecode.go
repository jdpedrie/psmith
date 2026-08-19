// Package claudecode implements the Psmith provider driver for the Claude
// Code CLI, run as a subprocess per turn. It is the first StatefulProvider:
// the harness owns conversation state on disk, and Psmith holds only opaque
// session handles.
//
// Every turn resumes its parent handle with --fork-session, so each handle
// is an immutable snapshot of the conversation including that turn. Sending
// to a historical handle branches the conversation without disturbing any
// other handle, which is what the StatefulProvider contract promises.
// Handles encode the model, so they resume across process restarts with no
// driver-side state. The one exception is the provisional handle returned
// by StartSession: the CLI mints the real session on the first message, so
// until then the session's config lives only in this process.
//
// The driver runs the CLI as a pure chat harness: tools disabled, one turn
// per send. CallSettings sampling knobs have no CLI equivalent and are
// silently dropped, per the driver rules.
//
// The driver self-registers in init(); importing this package is sufficient
// to make the type available to providers.Build("claude-code-subprocess", ...).
package claudecode

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/jdpedrie/psmith/claudesdk"
	"github.com/jdpedrie/psmith/server/providers"
)

func init() {
	providers.Register("claude-code-subprocess", New)
}

// Handle prefixes. Versioned so a future encoding change can coexist with
// handles already persisted by callers.
const (
	durablePrefix     = "ccs1:" // ccs1:<model>:<cli session uuid>
	provisionalPrefix = "ccp1:" // ccp1:<random>; valid only in-process until first send
)

// Config is the driver-specific JSON blob stored in
// user_model_providers.config. All fields are optional: the zero config
// finds the CLI on PATH and authenticates from the process environment
// (CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY), which the subprocess
// inherits.
type Config struct {
	// CLIPath overrides discovery of the `claude` binary. Tests point it
	// at a fake.
	CLIPath string `json:"cli_path,omitempty"`
	// MaxTurns caps the harness's internal agentic loop per send. With
	// tools disabled a send is a single turn, so the default of 1 is
	// only a guard.
	MaxTurns int `json:"max_turns,omitempty"`
}

// Driver is the live driver instance.
type Driver struct {
	cfg  Config
	deps providers.Deps

	mu      sync.Mutex
	pending map[string]pendingSession
}

// pendingSession is the setup registered by StartSession, consumed by the
// first SendInSession on that handle.
type pendingSession struct {
	model        string
	systemPrompt string
}

// New constructs a Driver from a Config blob and injected deps. An empty
// blob is valid — see Config.
func New(deps providers.Deps, configBytes json.RawMessage) (providers.Provider, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("claudecode: parse config: %w", err)
		}
	}
	if cfg.MaxTurns <= 0 {
		cfg.MaxTurns = 1
	}
	return &Driver{
		cfg:     cfg,
		deps:    deps,
		pending: map[string]pendingSession{},
	}, nil
}

// Type returns the registered provider-type identifier.
func (d *Driver) Type() string { return "claude-code-subprocess" }

// Stateful returns true — the harness owns conversation state.
func (d *Driver) Stateful() bool { return true }

// DiscoverModels returns the CLI's model aliases. The CLI accepts full
// model IDs too, but the aliases are the stable, version-agnostic surface;
// there is no listing endpoint to discover more.
func (d *Driver) DiscoverModels(ctx context.Context) ([]providers.Model, error) {
	aliases := []struct{ id, name string }{
		{"sonnet", "Claude Sonnet (via Claude Code)"},
		{"opus", "Claude Opus (via Claude Code)"},
		{"haiku", "Claude Haiku (via Claude Code)"},
	}
	out := make([]providers.Model, 0, len(aliases))
	for _, a := range aliases {
		out = append(out, providers.Model{
			ID:          a.id,
			DisplayName: a.name,
			Capabilities: providers.ModelCapabilities{
				// The harness caches prompts internally; nothing else on
				// this table is exposed through the chat-only surface.
				PromptCaching: true,
			},
		})
	}
	return out, nil
}

// RenderThinkingToText returns "" — the harness never exposes thinking
// content through its result stream.
func (d *Driver) RenderThinkingToText(thinking json.RawMessage) string { return "" }

// StartSession registers the session's setup and returns a provisional
// handle. The CLI mints the real session on the first SendInSession, which
// emits the durable handle via ChunkSessionHandle.
func (d *Driver) StartSession(ctx context.Context, modelID string, cfg providers.SessionConfig) (string, error) {
	if modelID == "" {
		return "", fmt.Errorf("claudecode: modelID is required")
	}
	if strings.Contains(modelID, ":") {
		// The durable handle encoding splits on ':'.
		return "", fmt.Errorf("claudecode: modelID %q must not contain ':'", modelID)
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("claudecode: generate handle: %w", err)
	}
	handle := provisionalPrefix + hex.EncodeToString(buf)
	d.mu.Lock()
	d.pending[handle] = pendingSession{model: modelID, systemPrompt: cfg.SystemPrompt}
	d.mu.Unlock()
	return handle, nil
}

// TerminateSession forgets any provisional setup for the handle. Durable
// handles have no driver-side state, and the CLI's on-disk transcripts are
// left alone: historical handles stay resumable.
func (d *Driver) TerminateSession(ctx context.Context, sessionID string) error {
	d.mu.Lock()
	delete(d.pending, sessionID)
	d.mu.Unlock()
	return nil
}

// turnSetup is a resolved handle: everything one send needs to build the
// CLI invocation.
type turnSetup struct {
	model        string
	systemPrompt string // creation turns only
	resumeID     string // empty on creation turns
	fromHandle   string // the provisional handle to clear once the turn lands
}

// resolveHandle decodes a handle into a turnSetup.
func (d *Driver) resolveHandle(handle string) (turnSetup, error) {
	switch {
	case strings.HasPrefix(handle, provisionalPrefix):
		d.mu.Lock()
		p, ok := d.pending[handle]
		d.mu.Unlock()
		if !ok {
			return turnSetup{}, fmt.Errorf("claudecode: unknown provisional session %q (provisional handles do not survive restarts; call StartSession again)", handle)
		}
		return turnSetup{model: p.model, systemPrompt: p.systemPrompt, fromHandle: handle}, nil
	case strings.HasPrefix(handle, durablePrefix):
		rest := strings.TrimPrefix(handle, durablePrefix)
		i := strings.IndexByte(rest, ':')
		if i <= 0 || i == len(rest)-1 {
			return turnSetup{}, fmt.Errorf("claudecode: malformed session handle %q", handle)
		}
		return turnSetup{model: rest[:i], resumeID: rest[i+1:]}, nil
	default:
		return turnSetup{}, fmt.Errorf("claudecode: unrecognized session handle %q", handle)
	}
}

// encodeHandle builds the durable handle for a CLI session.
func encodeHandle(model, cliSessionID string) string {
	return durablePrefix + model + ":" + cliSessionID
}

// queryOptions builds the claudesdk options for one turn.
func (d *Driver) queryOptions(t turnSetup) []claudesdk.Option {
	opts := []claudesdk.Option{
		claudesdk.WithModel(t.model),
		claudesdk.WithMaxTurns(d.cfg.MaxTurns),
		claudesdk.WithTools(), // chat harness: no tools
	}
	if t.resumeID != "" {
		opts = append(opts,
			claudesdk.WithResume(t.resumeID),
			// Forking on every turn is what makes handles immutable
			// snapshots. Plain --resume appends to a shared linear
			// transcript, so two sends against one handle would
			// interleave (verified empirically against the CLI).
			claudesdk.WithForkSession(true),
		)
	} else if t.systemPrompt != "" {
		opts = append(opts, claudesdk.WithSystemPrompt(t.systemPrompt))
	}
	if d.cfg.CLIPath != "" {
		opts = append(opts, claudesdk.WithCLIPath(d.cfg.CLIPath))
	}
	if d.deps.Logger != nil {
		log := d.deps.Logger
		opts = append(opts, claudesdk.WithStderrCallback(func(line string) {
			log.Debug("claudecode: cli stderr", "line", line)
		}))
	}
	return opts
}
