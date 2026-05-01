// Package history builds the wire-shaped message prefix to send to a provider
// driver, given a Conversation and the destination provider/model.
//
// The library is pure mechanics — no policy decisions about whether thinking
// should be included, no transform application, no compression. Callers
// resolve those concerns and pass the results in via Params. See
// docs/architecture.md → "Data model: Conversation/Context/Message",
// "Message roles", and "Thinking handling".
package history

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// Message roles as stored in the messages table.
const (
	roleSystem             = "system"
	roleContext            = "context"
	roleUser               = "user"
	roleAssistant          = "assistant"
	roleCompressionSummary = "compression_summary"
)

// Wire-side roles produced by Build.
const (
	wireSystem    = "system"
	wireUser      = "user"
	wireAssistant = "assistant"
)

// Sentinel errors returned by Build.
var (
	// ErrNoActiveContext indicates the conversation has no contexts. A valid
	// conversation always has at least one context, so this represents a
	// data-integrity problem at the caller's layer.
	ErrNoActiveContext = errors.New("history: conversation has no active context")

	// ErrLeafNotInActiveContext is returned when params.LeafMessageID points
	// at a message that does not belong to the active context.
	ErrLeafNotInActiveContext = errors.New("history: leaf message does not belong to the active context")

	// ErrAmbiguousLeaf is returned when no LeafMessageID is supplied and the
	// active context contains more than one leaf (usually the result of a
	// fork). Callers must specify which branch to build.
	ErrAmbiguousLeaf = errors.New("history: active context has multiple leaves; LeafMessageID required")

	// ErrUnknownRole is returned if a stored message has a role outside the
	// known set. The DB schema check constraint should make this impossible
	// in practice; we surface it explicitly rather than silently dropping
	// rows.
	ErrUnknownRole = errors.New("history: message has unknown role")

	// ErrBrokenParentChain is returned if walking parent_id from the leaf
	// reaches a parent that isn't present in the active context. In a
	// well-formed conversation this cannot happen — parent_id is scoped to
	// the same context.
	ErrBrokenParentChain = errors.New("history: parent_id refers to a message outside the active context")
)

// store is the subset of *store.Queries we depend on. Defining it here lets
// the unit tests pass an interface-compatible fake without standing up
// pgtestdb when convenient — and documents the dependency surface.
type queries interface {
	GetActiveContextByConversation(ctx context.Context, conversationID uuid.UUID) (store.Context, error)
	ListMessagesByContext(ctx context.Context, contextID uuid.UUID) ([]store.Message, error)
}

// Params carries the inputs to Build. See package doc for the contract.
type Params struct {
	// Conversation whose history is being assembled.
	Conversation store.Conversation

	// LeafMessageID, when non-nil, pins the prefix to end at this specific
	// message (must live in the active context). When nil, Build looks up
	// the unique leaf of the active context — and errors if there isn't one.
	LeafMessageID *uuid.UUID

	// DestProviderType is the provider driver type (e.g. "anthropic",
	// "openai-compatible") for the upcoming send. Determines whether stored
	// thinking blobs may travel as native thinking on the wire.
	DestProviderType string

	// IncludeThinking is the resolved per-conversation
	// include_thinking_in_history setting. When false, no thinking is ever
	// included regardless of the destination type.
	IncludeThinking bool

	// Plugins is the resolved chat-plugin pipeline for this turn. May be nil
	// or empty. SystemPrompter contributions augment the system slot;
	// HistoryTransformer mutates user/assistant messages with position
	// relative to the head. Other plugin capabilities (chunk, display,
	// outgoing-user, tools) are not consumed here — they run elsewhere in
	// the pipeline. See "Chat plugins → Where each capability runs" in
	// docs/architecture.md.
	Plugins plugins.Pipeline
}

// Build returns the wire-shaped message list for the prefix that ends at the
// active context's leaf (or at params.LeafMessageID if provided).
//
// Steps:
//  1. Find the active Context for the conversation.
//  2. Determine the leaf — explicit via params, else the sole childless
//     message in that context.
//  3. Walk parent_id from the leaf back to the root, accumulating messages.
//  4. Reverse to produce a root-first list.
//  5. Apply role mapping (context → user) and thinking inclusion/omission.
//
// An empty active context yields a non-nil empty slice and no error.
func Build(ctx context.Context, q queries, params Params) ([]providers.WireMessage, error) {
	active, err := q.GetActiveContextByConversation(ctx, params.Conversation.ID)
	if err != nil {
		// pgx surfaces "no rows" through the queries interface; we don't
		// want to depend on its error type here, so treat any error from
		// the active-context lookup as the "no active context" case while
		// preserving the underlying error for diagnosis.
		return nil, fmt.Errorf("%w: %w", ErrNoActiveContext, err)
	}

	msgs, err := q.ListMessagesByContext(ctx, active.ID)
	if err != nil {
		return nil, fmt.Errorf("history: list messages in active context: %w", err)
	}
	if len(msgs) == 0 {
		// Empty context — valid (e.g. before any system/context rows are
		// seeded for a fresh Context). Return an empty slice rather than
		// nil so callers can iterate without a nil check.
		return []providers.WireMessage{}, nil
	}

	byID := make(map[uuid.UUID]store.Message, len(msgs))
	for _, m := range msgs {
		byID[m.ID] = m
	}

	leafID, err := selectLeaf(msgs, byID, params.LeafMessageID)
	if err != nil {
		return nil, err
	}

	chain, err := walkParentChain(byID, leafID)
	if err != nil {
		return nil, err
	}

	// Assemble messages alongside their stored role so plugin transforms can
	// distinguish original user/assistant turns from system/context-derived
	// rows (which the architecture says transforms must skip).
	type assembled struct {
		wm         providers.WireMessage
		storedRole string
	}
	asm := make([]assembled, 0, len(chain))
	for _, m := range chain {
		// compression_summary rows are storage-only audit/cost records; the
		// summary that participates in future turns lives as a role=context
		// message in the NEW context that compression created. Skip them
		// from the wire prefix unconditionally.
		if m.Role == roleCompressionSummary {
			continue
		}
		// Errored / cancelled assistant turns: the supervisor materialises a
		// row even when the upstream produced nothing, so the failure shows
		// up in the UI as first-class history. Sending those rows back to a
		// provider on the next turn is wrong on every axis: the content is
		// usually empty (Gemini rejects outright with "parts[].data: oneof
		// must have one initialised field"; OpenAI silently accepts but the
		// model gets a blank assistant turn that confuses follow-ups), and
		// even when partial content streamed before the failure we don't
		// want the model to treat a half-finished + crashed answer as the
		// authoritative reply. Filter every message with a non-null
		// error_payload — across all providers, including the matched user
		// turn that prompted the failed attempt is fine, the failed
		// assistant row is the only thing we drop.
		if len(m.ErrorPayload) > 0 {
			continue
		}
		wm, err := toWireMessage(m, params.DestProviderType, params.IncludeThinking)
		if err != nil {
			return nil, err
		}
		asm = append(asm, assembled{wm: wm, storedRole: m.Role})
	}

	// Apply HistoryTransformer plugins to original user/assistant messages.
	// FromHead counts ALL messages back from the head (the last assembled
	// row); FromHeadSameRole counts only messages with the same WIRE role.
	// We index by wire role rather than stored role so context-derived rows
	// (mapped to wire user) are counted alongside actual user rows — that
	// matches what plugins see at iteration time.
	//
	// Walk back-to-front incrementing per-role counters so each row gets the
	// 0-indexed rank from the head.
	if !params.Plugins.Empty() {
		n := len(asm)
		samePos := make([]int, n)
		seenByWire := map[string]int{}
		for i := n - 1; i >= 0; i-- {
			r := asm[i].wm.Role
			samePos[i] = seenByWire[r]
			seenByWire[r]++
		}
		for i := range asm {
			role := asm[i].storedRole
			if role != roleUser && role != roleAssistant {
				continue
			}
			pos := plugins.HistoryPos{
				FromHead:         (n - 1) - i,
				FromHeadSameRole: samePos[i],
			}
			asm[i].wm = params.Plugins.TransformHistoryMessage(asm[i].wm, pos)
		}
	}

	out := make([]providers.WireMessage, len(asm))
	for i, a := range asm {
		out[i] = a.wm
	}

	// Apply SystemPrompter contributions. If a system message is already at
	// the head of the prefix, wrap its content with the prepend/append
	// strings; otherwise insert a new system message.
	if !params.Plugins.Empty() {
		prepend, appendStr := params.Plugins.SystemPrompts()
		if prepend != "" || appendStr != "" {
			out = applySystemContributions(out, prepend, appendStr)
		}
	}

	return out, nil
}

// applySystemContributions injects plugin SystemPrompter contributions into
// the system slot. When an existing system message is at the head, its
// content is wrapped: prepend → existing → append, joined by blank lines.
// Otherwise a new system message is inserted at the head.
func applySystemContributions(msgs []providers.WireMessage, prepend, appendStr string) []providers.WireMessage {
	if len(msgs) == 0 || msgs[0].Role != wireSystem {
		var parts []string
		if prepend != "" {
			parts = append(parts, prepend)
		}
		if appendStr != "" {
			parts = append(parts, appendStr)
		}
		sys := providers.WireMessage{Role: wireSystem, Content: joinParts(parts)}
		return append([]providers.WireMessage{sys}, msgs...)
	}
	var parts []string
	if prepend != "" {
		parts = append(parts, prepend)
	}
	if msgs[0].Content != "" {
		parts = append(parts, msgs[0].Content)
	}
	if appendStr != "" {
		parts = append(parts, appendStr)
	}
	msgs[0].Content = joinParts(parts)
	return msgs
}

// joinParts joins non-empty pieces with a blank-line separator.
func joinParts(parts []string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	}
	out := parts[0]
	for _, p := range parts[1:] {
		out += "\n\n" + p
	}
	return out
}

// selectLeaf resolves the leaf message ID for the prefix. If explicit, it
// validates the message belongs to the active context. Otherwise it looks
// for the single childless message; multiple candidates are an error.
func selectLeaf(msgs []store.Message, byID map[uuid.UUID]store.Message, explicit *uuid.UUID) (uuid.UUID, error) {
	if explicit != nil {
		if _, ok := byID[*explicit]; !ok {
			return uuid.Nil, ErrLeafNotInActiveContext
		}
		return *explicit, nil
	}

	// A leaf is a message with no children in the active context.
	hasChild := make(map[uuid.UUID]bool, len(msgs))
	for _, m := range msgs {
		if m.ParentID != nil {
			hasChild[*m.ParentID] = true
		}
	}

	var leaves []uuid.UUID
	for _, m := range msgs {
		if !hasChild[m.ID] {
			leaves = append(leaves, m.ID)
		}
	}
	switch len(leaves) {
	case 0:
		// Should be impossible for a non-empty context (at least one row
		// must be a leaf if the tree is acyclic), but guard anyway.
		return uuid.Nil, ErrAmbiguousLeaf
	case 1:
		return leaves[0], nil
	default:
		return uuid.Nil, ErrAmbiguousLeaf
	}
}

// walkParentChain follows parent_id from leafID back to the root and returns
// the chain in root-first order. Errors if the chain points outside the
// supplied (single-context) message set.
func walkParentChain(byID map[uuid.UUID]store.Message, leafID uuid.UUID) ([]store.Message, error) {
	// Walk leaf → root.
	var reverse []store.Message
	current := leafID
	for {
		m, ok := byID[current]
		if !ok {
			return nil, ErrBrokenParentChain
		}
		reverse = append(reverse, m)
		if m.ParentID == nil {
			break
		}
		current = *m.ParentID
	}

	// Reverse to root-first order.
	chain := make([]store.Message, len(reverse))
	for i, m := range reverse {
		chain[len(reverse)-1-i] = m
	}
	return chain, nil
}

// toWireMessage maps one stored Message to its wire representation, applying
// role rewriting and the thinking-inclusion rules.
//
// Cross-provider thinking: per docs/architecture.md the future behaviour is
// to inject thinking_rendered_text into the assistant turn's content. That is
// deferred until Round 3+; for now cross-provider thinking is omitted, the
// same outcome as IncludeThinking=false.
func toWireMessage(m store.Message, destProviderType string, includeThinking bool) (providers.WireMessage, error) {
	wireRole, err := wireRoleFor(m.Role)
	if err != nil {
		return providers.WireMessage{}, err
	}

	wm := providers.WireMessage{
		Role:    wireRole,
		Content: m.Content,
	}

	if m.Role != roleAssistant {
		// Thinking only attaches to assistant messages.
		return wm, nil
	}
	if !includeThinking || len(m.Thinking) == 0 {
		return wm, nil
	}

	// Same-provider: ship native thinking. Cross-provider: omit (deferred).
	if m.ThinkingProviderType != nil && *m.ThinkingProviderType == destProviderType {
		// Defensive copy so callers can't mutate the underlying store row.
		thinking := make([]byte, len(m.Thinking))
		copy(thinking, m.Thinking)
		wm.Thinking = thinking
	}
	return wm, nil
}

// wireRoleFor maps a stored role to its wire-side role. role=context is
// rewritten to user; the other roles are passed through.
func wireRoleFor(stored string) (string, error) {
	switch stored {
	case roleSystem:
		return wireSystem, nil
	case roleContext, roleUser:
		return wireUser, nil
	case roleAssistant:
		return wireAssistant, nil
	default:
		return "", fmt.Errorf("%w: %q", ErrUnknownRole, stored)
	}
}
