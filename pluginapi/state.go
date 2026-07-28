// Package plugins implements Psmith's chat-plugin system. A chat plugin is a
// compiled-in unit that can contribute to the system prompt, transform
// outgoing user messages, mutate stored history at prefix-build time, process
// inbound chunk streams, transform stored content for display, and provide
// tools the model can call.
//
// The required Plugin interface is intentionally tiny — name + display name + description.
// Every behavior is a separate opt-in interface, detected by type assertion
// at the call sites that care. A plugin implements as many sub-interfaces
// as it needs.
//
// See docs/design/plugins.md for the full design.
package pluginapi

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/google/uuid"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// MessageLifecycleHook fires after a message row is persisted —
// independently of the role. Runs in a detached goroutine; the
// supervisor / SendMessage handler does NOT await its completion or
// observe its return value, so a slow or panicking hook can't stall a
// user-facing operation.
//
// Fires on: user-message inserts (in SendMessage after the TX commits);
// assistant materialization (in materializeAssistant); compression
// summaries (in materializeCompression). Edits and deletes are
// deliberately NOT fired in v1 — those events warrant their own hook
// shape if a use case needs them.
//
// Common uses: embedding generation, webhook notifications, auto-
// tagging via a small classifier, external audit logs. Pairs naturally
// with a future PreSendContextInjector hook to form the building
// blocks for a memory plugin.
type MessageLifecycleHook interface {
	OnMessagePersisted(ctx context.Context, m PersistedMessage)
}

// PersistedMessage is the snapshot a MessageLifecycleHook receives.
// Intentionally minimal — hooks needing more (usage, thinking, tool
// calls) can fetch the full row by ID. Keeping the snapshot small
// makes the hook contract stable as the messages schema evolves.
type PersistedMessage struct {
	ID         string
	ContextID  string
	Role       string // "system" | "context" | "user" | "assistant" | "compression_summary"
	Content    string
	ProviderID string // empty for non-assistant rows
	ModelID    string // empty for non-assistant rows
}

// TransformAssistantContent walks the pipeline, applying every
// AssistantContentTransformer in order to content. Plugins that don't
// implement the interface are skipped. Called from
// stream.materializeAssistant before the message row is inserted, so
// the persisted bytes match the returned string.
// TurnContextInjector contributes an EPHEMERAL block to the wire prefix
// for the turn about to be generated. Unlike every other prompt-shaping
// interface it receives conversation identity, so a plugin can inject
// state scoped to the specific branch being continued.
//
// Two properties are load-bearing.
//
// It is not persisted. MessageEnvelope output is stored beside the user's
// content and recomposed into every future prefix (internal/history
// composeEnvelope), so a per-turn state block written that way would
// accumulate one copy per turn for the life of the campaign. This block
// is built fresh each send and never written down.
//
// It lands at the HEAD, not in the system slot. Anthropic's cache
// breakpoint sits at the end of the last assistant turn
// (internal/providers/anthropic applyAutoCacheControl), so anything
// before it must stay byte-identical between turns to stay cached.
// Putting changing state in the system slot would invalidate the entire
// cached prefix on every single turn — on turn forty of a long
// conversation that means re-reading the whole transcript at full price,
// every turn. Injected after the breakpoint, only the block itself is
// uncached.
type TurnContextInjector interface {
	BuildTurnContext(ctx context.Context, turn TurnInfo) (string, error)
}

// TurnInfo identifies the branch a turn is continuing.
type TurnInfo struct {
	UserID         uuid.UUID
	ConversationID uuid.UUID
	ContextID      uuid.UUID
	// LeafMessageID is the message the new turn hangs off — the branch
	// head. This is what makes injection fork-aware.
	LeafMessageID uuid.UUID
}

// BuildTurnContexts collects every injector's block, in pipeline order.
// Errors are the caller's to log; a plugin that cannot build its block
// contributes nothing rather than failing the send, because a missing
// status panel is a worse outcome than a degraded one.
// decorate, when non-nil, attaches per-plugin runtime dependencies to the
// context before the injector runs — the same shims tool dispatch
// provides. Without it a stateful injector has no way to read anything.
func (p Pipeline) BuildTurnContexts(ctx context.Context, turn TurnInfo, decorate func(context.Context, string) context.Context) []string {
	var out []string
	for _, pl := range p {
		inj, ok := pl.(TurnContextInjector)
		if !ok {
			continue
		}
		pctx := ctx
		if decorate != nil {
			pctx = decorate(ctx, pl.Name())
		}
		block, err := inj.BuildTurnContext(pctx, turn)
		if err != nil || strings.TrimSpace(block) == "" {
			continue
		}
		out = append(out, block)
	}
	return out
}

// PendingStateProvider is implemented by plugins that compute
// authoritative state during a turn which must be bound to the assistant
// message once it exists.
//
// The split is forced by when things happen: a tool runs mid-generation,
// before there is any assistant row to key state to, so the plugin holds
// its result on the (per-send) instance and the runtime collects it at
// materialization. Returning ok=false means "this turn changed nothing",
// which is the common case for a plugin whose tool wasn't called.
type PendingStateProvider interface {
	PendingPluginState() (state json.RawMessage, version int64, ok bool)
}

// PendingState is one plugin's computed state awaiting a message to
// bind to.
type PendingState struct {
	PluginName string
	State      json.RawMessage
	Version    int64
}

// PendingPluginStates collects every plugin's pending state after a
// turn. Called by the runtime at assistant materialization.
func (p Pipeline) PendingPluginStates() []PendingState {
	var out []PendingState
	for _, pl := range p {
		sp, ok := pl.(PendingStateProvider)
		if !ok {
			continue
		}
		state, version, has := sp.PendingPluginState()
		if !has || len(state) == 0 {
			continue
		}
		out = append(out, PendingState{PluginName: pl.Name(), State: state, Version: version})
	}
	return out
}

// FireMessagePersisted dispatches each MessageLifecycleHook in the
// pipeline in a detached goroutine. Returns immediately. A panic in
// any single hook is recovered + logged via the optional logger; one
// misbehaving plugin can't bring down the others or the caller.
//
// The hook contract is fire-and-forget: callers don't await
// completion, don't observe errors, and don't ordering-guarantee
// against subsequent operations. Hooks needing back-pressure semantics
// belong on a different interface.
func (p Pipeline) FireMessagePersisted(ctx context.Context, m PersistedMessage, logger *slog.Logger) {
	for _, pl := range p {
		h, ok := pl.(MessageLifecycleHook)
		if !ok {
			continue
		}
		hook := h
		pluginName := pl.Name()
		go func() {
			defer func() {
				if r := recover(); r != nil && logger != nil {
					logger.Error("plugin OnMessagePersisted panicked",
						"plugin", pluginName,
						"message_id", m.ID,
						"panic", fmt.Sprintf("%v", r))
				}
			}()
			hook.OnMessagePersisted(ctx, m)
		}()
	}
}
