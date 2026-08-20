// Package codex implements the Psmith provider driver for the Codex CLI, run
// as a long-lived `app-server` subprocess. The second StatefulProvider after
// claudecode: the harness owns conversation state, and Psmith holds only
// opaque handles.
//
// Codex's fork is better suited to this than Claude Code's. `thread/fork`
// takes a lastTurnId, so a handle can name a specific TURN rather than just a
// thread, and editing a historical message forks exactly there with nothing
// replayed. Claude Code can only fork from the tip of whatever it resumed, so
// its handles carry a session id alone.
//
// That difference is why the handle here encodes three parts rather than two:
// model, thread, and the turn that handle represents. Sending to a historical
// handle forks the thread at that turn, which is the StatefulProvider
// contract's immutable-snapshot promise, honored natively.
//
// The driver runs Codex as a pure chat harness. Sandbox, approval policy and
// cwd are deliberately left unset so the user's own Codex config decides:
// Psmith is borrowing their CLI, not reconfiguring it. CallSettings sampling
// knobs have no equivalent and are dropped, per the driver rules.
//
// The driver self-registers in init(); importing this package is sufficient
// to make the type available to providers.Build("codex-app-server", ...).
package codex

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/jdpedrie/psmith/codexsdk"
	"github.com/jdpedrie/psmith/server/providers"
)

func init() {
	providers.Register("codex-app-server", New)
}

// Handle prefixes, versioned so a future encoding change can coexist with
// handles already persisted against conversations.
const (
	provisionalPrefix = "codex-prov-v1:"
	durablePrefix     = "codex-v1:"
)

// Config is the driver's provider config blob.
type Config struct {
	// CLIPath overrides the `codex` binary. Empty resolves from PATH.
	CLIPath string `json:"cli_path"`
	// DefaultModel is used when a turn names no model.
	DefaultModel string `json:"default_model"`
}

// Driver is one Codex provider instance.
//
// It owns at most one app-server subprocess, started lazily on first use and
// shared by every conversation. The app-server multiplexes threads, so a
// process per conversation would be waste; this is the main structural
// difference from claudecode, which spawns a CLI per turn.
type Driver struct {
	cfg  Config
	deps providers.Deps

	mu sync.Mutex
	// client is nil until the first turn needs it.
	client *codexsdk.Client
	// pending holds provisional sessions: a StartSession that has not yet had
	// its first turn, so no thread exists upstream to name.
	pending map[string]pendingSession
}

type pendingSession struct {
	model            string
	baseInstructions string
}

// New constructs a Driver from a config blob.
func New(deps providers.Deps, configBytes json.RawMessage) (providers.Provider, error) {
	var cfg Config
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("codex: parse config: %w", err)
		}
	}
	return &Driver{cfg: cfg, deps: deps, pending: map[string]pendingSession{}}, nil
}

func (d *Driver) Type() string { return "codex-app-server" }

// Stateful reports true: Codex keeps the transcript, Psmith sends one message.
func (d *Driver) Stateful() bool { return true }

// RenderThinkingToText returns empty. Codex streams reasoning summaries as
// deltas rather than as a stored blob, so there is nothing to re-render.
func (d *Driver) RenderThinkingToText(json.RawMessage) string { return "" }

// DiscoverModels returns nothing.
//
// The app-server has model/list, but a harness's model set is whatever the
// user's Codex account and config allow, and Psmith would be guessing at
// pricing and context windows for models it cannot price. Users add the models
// they want manually, the same as claudecode.
func (d *Driver) DiscoverModels(context.Context) ([]providers.Model, error) {
	return nil, nil
}

// clientFor returns the shared app-server, starting it on first use.
//
// Lazy because constructing a Driver happens on any provider read (listing
// models, testing a provider) and spawning a subprocess for those would be
// rude. Started under the lock so two concurrent first turns cannot each spawn
// one.
func (d *Driver) clientFor(ctx context.Context) (*codexsdk.Client, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.client != nil {
		return d.client, nil
	}
	c, err := codexsdk.New(ctx, codexsdk.Options{
		CLIPath: d.cfg.CLIPath,
		OnStderr: func(line string) {
			if d.deps.Logger != nil {
				d.deps.Logger.Debug("codex app-server", "line", line)
			}
		},
	})
	if err != nil {
		return nil, err
	}
	d.client = c
	return c, nil
}

// Close stops the shared subprocess. Not part of the Provider interface;
// called by tests and available for a future driver-lifecycle hook.
func (d *Driver) Close() error {
	d.mu.Lock()
	c := d.client
	d.client = nil
	d.mu.Unlock()
	if c != nil {
		return c.Close()
	}
	return nil
}

// StartSession registers the session's immutable setup and returns a
// provisional handle.
//
// No thread is created upstream yet. Codex would happily mint one here, but a
// conversation the user abandons before their first message would leave an
// empty thread behind in their Codex history, which is their data and not
// ours to litter.
func (d *Driver) StartSession(ctx context.Context, modelID string, cfg providers.SessionConfig) (string, error) {
	if modelID == "" {
		modelID = d.cfg.DefaultModel
	}
	if modelID == "" {
		return "", fmt.Errorf("codex: modelID is required")
	}
	if strings.Contains(modelID, ":") {
		// The durable handle encoding splits on ':'.
		return "", fmt.Errorf("codex: modelID %q must not contain ':'", modelID)
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("codex: generate handle: %w", err)
	}
	handle := provisionalPrefix + hex.EncodeToString(buf)
	d.mu.Lock()
	d.pending[handle] = pendingSession{model: modelID, baseInstructions: cfg.SystemPrompt}
	d.mu.Unlock()
	return handle, nil
}

// TerminateSession forgets provisional setup. Durable handles have no
// driver-side state and Codex's threads stay on disk, so historical handles
// remain forkable afterward.
func (d *Driver) TerminateSession(_ context.Context, sessionID string) error {
	d.mu.Lock()
	delete(d.pending, sessionID)
	d.mu.Unlock()
	return nil
}

// turnSetup is a resolved handle: everything one send needs.
type turnSetup struct {
	model            string
	baseInstructions string // creation turns only
	threadID         string // empty on creation turns
	turnID           string // the turn this handle represents; fork point
	fromHandle       string // provisional handle to clear once the turn lands
}

// resolveHandle decodes a handle.
func (d *Driver) resolveHandle(handle string) (turnSetup, error) {
	switch {
	case strings.HasPrefix(handle, provisionalPrefix):
		d.mu.Lock()
		p, ok := d.pending[handle]
		d.mu.Unlock()
		if !ok {
			return turnSetup{}, fmt.Errorf("codex: unknown provisional session %q (provisional handles do not survive restarts; call StartSession again)", handle)
		}
		return turnSetup{model: p.model, baseInstructions: p.baseInstructions, fromHandle: handle}, nil

	case strings.HasPrefix(handle, durablePrefix):
		rest := strings.TrimPrefix(handle, durablePrefix)
		parts := strings.Split(rest, ":")
		if len(parts) != 3 || parts[0] == "" || parts[1] == "" {
			return turnSetup{}, fmt.Errorf("codex: malformed session handle %q", handle)
		}
		// parts[2] (turn id) may be empty: a thread whose first turn produced
		// no turn id still forks, just from the tip.
		return turnSetup{model: parts[0], threadID: parts[1], turnID: parts[2]}, nil

	default:
		return turnSetup{}, fmt.Errorf("codex: unrecognized session handle %q", handle)
	}
}

// encodeHandle builds the durable handle for a thread at a turn.
//
// The turn id is what makes editing a historical message cheap: forking with
// it branches exactly there rather than from the thread's tip.
func encodeHandle(model, threadID, turnID string) string {
	return durablePrefix + model + ":" + threadID + ":" + turnID
}
