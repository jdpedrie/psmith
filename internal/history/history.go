// Package history builds the wire-shaped message prefix to send to a provider
// driver, given a Conversation and the destination provider/model.
//
// The library is pure mechanics — no policy decisions about whether thinking
// should be included, no transform application, no compression. Callers
// resolve those concerns and pass the results in via Params. See
// docs/design/history-builder.md for the full mechanism and
// docs/design/data-model.md for the conversation/context/message model,
// message roles, and thinking handling.
package history

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/storage"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
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
	ListContextLeafIDs(ctx context.Context, contextID uuid.UUID) ([]uuid.UUID, error)
	ListMessageChainForHistory(ctx context.Context, id uuid.UUID) ([]store.ListMessageChainForHistoryRow, error)
	ListAttachmentsForMessages(ctx context.Context, messageIDs []uuid.UUID) ([]store.ListAttachmentsForMessagesRow, error)
}

// AttachmentReader is the minimal Storage interface used during
// history build to inline attachment bytes. Matches storage.Storage's
// Get method without dragging the whole interface in — keeps the
// dependency surface narrow for tests.
type AttachmentReader interface {
	Get(ctx context.Context, userID uuid.UUID, sha256 string) (io.ReadCloser, error)
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
	// the pipeline. See "Where each capability runs" in
	// docs/design/plugins.md.
	Plugins plugins.Pipeline

	// UserID owns the conversation. Used to scope attachment reads
	// (storage is partitioned per-user). Required when the chain
	// has any message_attachments rows; the lookup happens via the
	// caller's storage backend.
	UserID uuid.UUID

	// Attachments inlines blob bytes from the Storage backend onto
	// each WireMessage that carries an attachment. Nil disables
	// attachment inlining — the chain still walks but provider
	// drivers will see empty Attachment lists. Tests that don't
	// exercise attachments leave this nil.
	Attachments AttachmentReader

	// Logger, when non-nil, receives warnings for non-fatal
	// problems encountered during history assembly — most notably
	// attachment rows whose underlying bytes have vanished from
	// storage. Build still returns successfully in that case so a
	// missing image doesn't brick the whole conversation; the
	// affected message just goes to the provider without the
	// attachment. Nil means silent.
	Logger *slog.Logger
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

	// Resolve the leaf. Explicit via params (the hot path — SendMessage
	// and CountContextTokens both resolve one first); otherwise probe
	// the context's childless rows, capped at 2, preserving the
	// leafless contract (empty → empty prefix, ambiguous → error)
	// without listing the whole context.
	leafID := params.LeafMessageID
	if leafID == nil {
		leafIDs, err := q.ListContextLeafIDs(ctx, active.ID)
		if err != nil {
			return nil, fmt.Errorf("history: list context leaves: %w", err)
		}
		switch len(leafIDs) {
		case 0:
			// Empty context — valid (e.g. before any system/context rows
			// are seeded for a fresh Context). Return an empty slice
			// rather than nil so callers can iterate without a nil check.
			return []providers.WireMessage{}, nil
		case 1:
			leafID = &leafIDs[0]
		default:
			return nil, ErrAmbiguousLeaf
		}
	}

	// Fetch ONLY the ancestor chain — O(chain), not O(context); forked
	// contexts carry dead branches the chain never touches.
	rows, err := q.ListMessageChainForHistory(ctx, *leafID)
	if err != nil {
		return nil, fmt.Errorf("history: list message chain: %w", err)
	}
	if len(rows) == 0 {
		// Leaf id doesn't exist at all — same contract as a leaf
		// outside the active context.
		return nil, ErrLeafNotInActiveContext
	}
	// The recursive walk follows parent_id without regard for context
	// boundaries; enforce the original invariants here. Rows are
	// root-first, so the LEAF is the last row.
	if rows[len(rows)-1].Message.ContextID != active.ID {
		return nil, ErrLeafNotInActiveContext
	}
	chain := make([]store.Message, 0, len(rows))
	for _, r := range rows {
		if r.Message.ContextID != active.ID {
			return nil, ErrBrokenParentChain
		}
		chain = append(chain, r.Message)
	}

	// Load attachments for every message in the chain in one round
	// trip, then bucket by message_id for per-row lookup. Nil
	// Attachments reader → skip the load entirely; callers that
	// don't care about attachments (most tests) don't pay the cost.
	attachmentsByMessage := map[uuid.UUID][]providers.Attachment{}
	if params.Attachments != nil {
		ids := make([]uuid.UUID, 0, len(chain))
		for _, m := range chain {
			ids = append(ids, m.ID)
		}
		rows, lerr := q.ListAttachmentsForMessages(ctx, ids)
		if lerr != nil {
			return nil, fmt.Errorf("history: list attachments: %w", lerr)
		}
		for _, r := range rows {
			rc, gerr := params.Attachments.Get(ctx, params.UserID, r.Sha256)
			if gerr != nil {
				// A missing object in storage shouldn't brick the
				// conversation. The row exists but its bytes are
				// gone (FS wipe, backend swap, partial restore).
				// Log and drop the attachment from the wire; the
				// model sees the rest of the message intact.
				if errors.Is(gerr, storage.ErrNotFound) {
					if params.Logger != nil {
						params.Logger.Warn("history: attachment missing from storage; skipping",
							"file_id", r.FileID, "sha256", r.Sha256, "message_id", r.MessageID)
					}
					continue
				}
				return nil, fmt.Errorf("history: read attachment %s: %w", r.FileID, gerr)
			}
			data, rerr := io.ReadAll(rc)
			_ = rc.Close()
			if rerr != nil {
				return nil, fmt.Errorf("history: drain attachment %s: %w", r.FileID, rerr)
			}
			att := providers.Attachment{
				Kind:     providers.AttachmentKind(r.Kind),
				MimeType: r.MimeType,
				Data:     data,
				SHA256:   r.Sha256,
			}
			if r.OriginalFilename != nil {
				att.Filename = *r.OriginalFilename
			}
			attachmentsByMessage[r.MessageID] = append(attachmentsByMessage[r.MessageID], att)
		}
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
		// Attach pre-loaded inline bytes for this message, if any.
		// Attachments are kept on the WireMessage rather than spliced
		// into Content so each driver can decide whether to translate
		// them (image block, file_data, image_url) or drop them.
		if atts := attachmentsByMessage[m.ID]; len(atts) > 0 {
			wm.Attachments = atts
		}
		// If the assistant turn had tool calls, splice the model's tool_use
		// blocks back onto the assistant message and append a synthetic
		// user message carrying the matching tool_result blocks. This is
		// the wire shape every provider expects for tool-calling history.
		if m.Role == roleAssistant && len(m.ToolCalls) > 0 {
			uses, results, ok := splitStoredToolCalls(m.ToolCalls)
			if ok {
				wm.ToolUses = uses
				asm = append(asm, assembled{wm: wm, storedRole: m.Role})
				toolResultMsg := providers.WireMessage{
					Role:        wireUser,
					ToolResults: results,
				}
				asm = append(asm, assembled{wm: toolResultMsg, storedRole: roleUser})
				continue
			}
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
				DestProviderType: params.DestProviderType,
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

// toWireMessage maps one stored Message to its wire representation, applying
// role rewriting and the thinking-inclusion rules.
//
// Cross-provider thinking: per docs/design/providers.md the future behaviour is
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
		Content: composeEnvelope(m),
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

// splitStoredToolCalls decodes the messages.tool_calls JSONB column into
// the (assistant.ToolUses, user.ToolResults) pair the wire shape expects.
// Returns ok=false on empty / malformed payload so the caller can fall back
// to the no-tools path.
func splitStoredToolCalls(payload []byte) ([]providers.ToolUseBlock, []providers.ToolResultBlock, bool) {
	if len(payload) == 0 {
		return nil, nil, false
	}
	var raw []struct {
		ID             string          `json:"id"`
		Name           string          `json:"name"`
		Input          json.RawMessage `json:"input"`
		Output         json.RawMessage `json:"output"`
		Error          string          `json:"error"`
		ProviderOpaque string          `json:"provider_opaque"`
	}
	if err := json.Unmarshal(payload, &raw); err != nil || len(raw) == 0 {
		return nil, nil, false
	}
	uses := make([]providers.ToolUseBlock, 0, len(raw))
	results := make([]providers.ToolResultBlock, 0, len(raw))
	for _, r := range raw {
		input := r.Input
		if len(input) == 0 {
			input = json.RawMessage(`{}`)
		}
		uses = append(uses, providers.ToolUseBlock{
			ID:             r.ID,
			Name:           r.Name,
			Input:          input,
			ProviderOpaque: r.ProviderOpaque,
		})
		results = append(results, providers.ToolResultBlock{
			ToolUseID: r.ID,
			Output:    r.Output,
			Error:     r.Error,
		})
	}
	return uses, results, true
}

// composeEnvelope assembles the wire text for one stored message:
// message_headers + content + message_trailers, blank-line separated.
// The envelope columns carry plugin contributions (grounding facts,
// future siblings) persisted beside the user's own words — this is
// the ONLY place they join; display, edit, TTS, and embeddings all
// read bare content. Values were frozen at write time, so the
// composed text is byte-stable across prefix builds (prompt-cache
// friendly).
func composeEnvelope(m store.Message) string {
	header := ""
	if m.MessageHeaders != nil {
		header = *m.MessageHeaders
	}
	trailer := ""
	if m.MessageTrailers != nil {
		trailer = *m.MessageTrailers
	}
	if header == "" && trailer == "" {
		return m.Content
	}
	var parts []string
	if header != "" {
		parts = append(parts, header)
	}
	if m.Content != "" {
		parts = append(parts, m.Content)
	}
	if trailer != "" {
		parts = append(parts, trailer)
	}
	return joinParts(parts)
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
