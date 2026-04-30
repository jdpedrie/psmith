package conversations

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/plugins"
)

// Message-role wire/storage constants. The DB CHECK constraint enforces these
// literal strings; the proto enum carries them on the wire.
const (
	roleSystem             = "system"
	roleContext            = "context"
	roleUser               = "user"
	roleAssistant          = "assistant"
	roleCompressionSummary = "compression_summary"
)

// Persisted conversations.settings is the full proto round-tripped via
// protojson. Earlier code marshalled a hand-rolled struct that silently
// dropped the `call_settings` sub-block, breaking the conversation layer
// of the CallSettings resolution chain. encoding/json on the proto is
// also wrong — it doesn't honour optional-field presence the way
// protojson does. Both write and read use protojson with the same options
// pinned in `profiles.callSettingsMarshaller` (snake-case names, omit
// unset, tolerate unknown fields).
var (
	conversationSettingsMarshaller = protojson.MarshalOptions{
		UseProtoNames:   true,
		EmitUnpopulated: false,
	}
	conversationSettingsUnmarshaller = protojson.UnmarshalOptions{
		DiscardUnknown: true,
	}
)

func settingsToJSON(s *clarkv1.ConversationSettings) ([]byte, error) {
	if s == nil {
		return nil, nil
	}
	return conversationSettingsMarshaller.Marshal(s)
}

func settingsFromJSON(b []byte) (*clarkv1.ConversationSettings, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var s clarkv1.ConversationSettings
	if err := conversationSettingsUnmarshaller.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("decode conversation settings: %w", err)
	}
	return &s, nil
}

// conversationToProto builds the wire shape from a store row plus the active
// context id resolved by the caller. activeContextID may be the empty string
// when an active context isn't known (e.g., immediately after creation, before
// the seed messages are written). last_activity_at falls back to UpdatedAt
// (the only proxy available without a join) — list paths that compute the
// real value should call conversationToProtoWithActivity instead.
func conversationToProto(c store.Conversation, activeContextID string) (*clarkv1.Conversation, error) {
	return conversationToProtoWithActivity(c, activeContextID, c.UpdatedAt)
}

// conversationToProtoWithActivity is the list-path variant — it accepts the
// joined max(messages.created_at) so the sidebar can render "Recently Used"
// without an N+1 round trip.
func conversationToProtoWithActivity(c store.Conversation, activeContextID string, lastActivityAt time.Time) (*clarkv1.Conversation, error) {
	settings, err := settingsFromJSON(c.Settings)
	if err != nil {
		return nil, err
	}
	return &clarkv1.Conversation{
		Id:              c.ID.String(),
		ProfileId:       c.ProfileID.String(),
		Title:           c.Title,
		Settings:        settings,
		ActiveContextId: activeContextID,
		OwnerUserId:     c.UserID.String(),
		CreatedAt:       timestamppb.New(c.CreatedAt),
		UpdatedAt:       timestamppb.New(c.UpdatedAt),
		LastActivityAt:  timestamppb.New(lastActivityAt),
	}, nil
}

func contextToProto(c store.Context) *clarkv1.Context {
	out := &clarkv1.Context{
		Id:             c.ID.String(),
		ConversationId: c.ConversationID.String(),
		ActivationTime: timestamppb.New(c.ContextActivationTime),
		CreatedAt:      timestamppb.New(c.CreatedAt),
	}
	if c.ParentContextID != nil {
		s := c.ParentContextID.String()
		out.ParentContextId = &s
	}
	if c.CurrentLeafMessageID != nil {
		s := c.CurrentLeafMessageID.String()
		out.CurrentLeafMessageId = &s
	}
	if c.Title != nil {
		out.Title = c.Title
	}
	return out
}

// listContextRowToProto adapts the aggregated ListContextsByConversation row
// (which carries message_count, last_message_total_tokens, and
// cumulative_cost_usd) to the Context proto. Single-context queries continue
// to use contextToProto, which leaves the aggregate fields at zero.
func listContextRowToProto(r store.ListContextsByConversationRow) *clarkv1.Context {
	out := &clarkv1.Context{
		Id:                     r.ID.String(),
		ConversationId:         r.ConversationID.String(),
		ActivationTime:         timestamppb.New(r.ContextActivationTime),
		CreatedAt:              timestamppb.New(r.CreatedAt),
		MessageCount:           int32(r.MessageCount),
		LastMessageTotalTokens: r.LastMessageTotalTokens,
		CumulativeCostUsd:      r.CumulativeCostUsd,
	}
	if r.ParentContextID != nil {
		s := r.ParentContextID.String()
		out.ParentContextId = &s
	}
	if r.CurrentLeafMessageID != nil {
		s := r.CurrentLeafMessageID.String()
		out.CurrentLeafMessageId = &s
	}
	if r.Title != nil {
		out.Title = r.Title
	}
	return out
}

func messageToProto(m store.Message) *clarkv1.Message {
	out := &clarkv1.Message{
		Id:                   m.ID.String(),
		ContextId:            m.ContextID.String(),
		Role:                 roleStringToEnum(m.Role),
		Content:              m.Content,
		RawContent:           m.RawContent,
		Thinking:             m.Thinking,
		ThinkingProviderType: m.ThinkingProviderType,
		ThinkingRenderedText: m.ThinkingRenderedText,
		ThinkingDurationMs:   m.ThinkingDurationMs,
		ModelId:              m.ModelID,
		CreatedAt:            timestamppb.New(m.CreatedAt),
	}
	if m.ParentID != nil {
		s := m.ParentID.String()
		out.ParentId = &s
	}
	if m.ProviderID != nil {
		s := m.ProviderID.String()
		out.ProviderId = &s
	}
	if usage := messageUsageToProto(m); usage != nil {
		out.Usage = usage
	}
	if m.EditedAt != nil {
		out.EditedAt = timestamppb.New(*m.EditedAt)
	}
	if errText := errorTextFromPayload(m.ErrorPayload); errText != "" {
		out.ErrorText = &errText
	}
	return out
}

// errorTextFromPayload extracts a human-readable error message from the
// stored error_payload. Tries multiple shapes in priority order so the UI
// gets something readable regardless of which provider failed and how:
//
//  1. Our normalised wrapper (`internal/stream.chunkErrorPayload`):
//     `{"message": "...", "raw": ...}` — most assistant errors land here.
//  2. Provider envelope: `{"error": {"message": "...", ...}}` — every
//     OpenAI-compatible upstream uses this when our wrapper somehow loses
//     the .message extraction; same shape as Anthropic and Google.
//  3. A bare top-level JSON string: `"upstream blew up"`.
//  4. Fallback: the raw payload bytes verbatim. Better to show the user
//     "{some unparseable blob}" than to silently drop the error and let
//     them think the turn succeeded.
//
// Returns "" only when the payload was empty to begin with — every
// other path produces something the UI can render.
func errorTextFromPayload(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}
	// Shape 1: normalised wrapper.
	var wrap struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(payload, &wrap); err == nil && wrap.Message != "" {
		return wrap.Message
	}
	// Shape 2: provider envelope — works for OpenAI, Anthropic, Google.
	var envelope struct {
		Error struct {
			Message string `json:"message"`
			Type    string `json:"type"`
			Code    any    `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(payload, &envelope); err == nil && envelope.Error.Message != "" {
		return envelope.Error.Message
	}
	// Shape 3: a bare JSON string.
	var s string
	if err := json.Unmarshal(payload, &s); err == nil && s != "" {
		return s
	}
	// Fallback: raw bytes. Trim outer whitespace; collapse internal
	// whitespace runs to single spaces so a multi-line payload reads as
	// a single banner line.
	raw := strings.TrimSpace(string(payload))
	if raw == "" {
		return ""
	}
	raw = strings.Join(strings.Fields(raw), " ")
	const cap = 512
	if len(raw) > cap {
		raw = raw[:cap] + "…"
	}
	return raw
}

// messageUsageToProto returns a MessageUsage proto if any usage/cost column
// is populated. Returns nil otherwise so the wire-message stays compact for
// non-assistant rows.
func messageUsageToProto(m store.Message) *clarkv1.MessageUsage {
	if m.InputTokens == nil && m.OutputTokens == nil &&
		m.CacheReadTokens == nil && m.CacheWriteTokens == nil &&
		m.ReasoningTokens == nil &&
		!m.InputCostUsd.Valid && !m.OutputCostUsd.Valid &&
		!m.CacheReadCostUsd.Valid && !m.CacheWriteCostUsd.Valid &&
		!m.TotalCostUsd.Valid {
		return nil
	}
	return &clarkv1.MessageUsage{
		InputTokens:       m.InputTokens,
		OutputTokens:      m.OutputTokens,
		CacheReadTokens:   m.CacheReadTokens,
		CacheWriteTokens:  m.CacheWriteTokens,
		ReasoningTokens:   m.ReasoningTokens,
		InputCostUsd:      numericToFloat64Ptr(m.InputCostUsd),
		OutputCostUsd:     numericToFloat64Ptr(m.OutputCostUsd),
		CacheReadCostUsd:  numericToFloat64Ptr(m.CacheReadCostUsd),
		CacheWriteCostUsd: numericToFloat64Ptr(m.CacheWriteCostUsd),
		TotalCostUsd:      numericToFloat64Ptr(m.TotalCostUsd),
	}
}

func numericToFloat64Ptr(n pgtype.Numeric) *float64 {
	if !n.Valid {
		return nil
	}
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return nil
	}
	v := f.Float64
	return &v
}

// chainRowToProto adapts a recursive-CTE row (a value-copy of the message
// columns plus sibling_count) into the proto Message shape.
func chainRowToProto(r store.ListMessageAncestorChainRow) *clarkv1.Message {
	out := messageToProto(store.Message{
		ID:                   r.ID,
		ContextID:            r.ContextID,
		ParentID:             r.ParentID,
		Role:                 r.Role,
		Content:              r.Content,
		RawContent:           r.RawContent,
		Thinking:             r.Thinking,
		ThinkingProviderType: r.ThinkingProviderType,
		ThinkingRenderedText: r.ThinkingRenderedText,
		ThinkingDurationMs:   r.ThinkingDurationMs,
		ProviderID:           r.ProviderID,
		ModelID:              r.ModelID,
		CreatedAt:            r.CreatedAt,
		EditedAt:             r.EditedAt,
		InputTokens:          r.InputTokens,
		OutputTokens:         r.OutputTokens,
		CacheReadTokens:      r.CacheReadTokens,
		CacheWriteTokens:     r.CacheWriteTokens,
		ReasoningTokens:      r.ReasoningTokens,
		ProviderUsageRaw:     r.ProviderUsageRaw,
		InputCostUsd:         r.InputCostUsd,
		OutputCostUsd:        r.OutputCostUsd,
		CacheReadCostUsd:     r.CacheReadCostUsd,
		CacheWriteCostUsd:    r.CacheWriteCostUsd,
		TotalCostUsd:         r.TotalCostUsd,
		ErrorPayload:         r.ErrorPayload,
	})
	out.SiblingCount = r.SiblingCount
	return out
}

// applyDisplay populates m.DisplayContent. When the pipeline is empty (or
// has no DisplayTransformer plugins), display_content equals content so
// clients can always read display_content without checking for absence.
func applyDisplay(m *clarkv1.Message, pipeline plugins.Pipeline) {
	if m == nil {
		return
	}
	if pipeline.Empty() {
		m.DisplayContent = m.Content
		return
	}
	m.DisplayContent = pipeline.TransformForDisplay(m.Content)
}

func roleStringToEnum(s string) clarkv1.MessageRole {
	switch s {
	case roleSystem:
		return clarkv1.MessageRole_MESSAGE_ROLE_SYSTEM
	case roleContext:
		return clarkv1.MessageRole_MESSAGE_ROLE_CONTEXT
	case roleUser:
		return clarkv1.MessageRole_MESSAGE_ROLE_USER
	case roleAssistant:
		return clarkv1.MessageRole_MESSAGE_ROLE_ASSISTANT
	case roleCompressionSummary:
		return clarkv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY
	default:
		return clarkv1.MessageRole_MESSAGE_ROLE_UNSPECIFIED
	}
}
