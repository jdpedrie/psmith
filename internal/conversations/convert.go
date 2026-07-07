package conversations

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// attachmentRowToProto projects a single message_attachments JOIN
// files row into its wire shape. The bytes themselves are not
// included — clients fetch via FilesService.GetFileURL.
func attachmentRowToProto(r store.ListAttachmentsForMessagesRow) *psmithv1.MessageAttachment {
	out := &psmithv1.MessageAttachment{
		FileId:    r.FileID.String(),
		Kind:      r.Kind,
		MimeType:  r.MimeType,
		Sha256:    r.Sha256,
		RoleHint:  r.RoleHint,
		SizeBytes: r.SizeBytes,
	}
	if r.OriginalFilename != nil && *r.OriginalFilename != "" {
		s := *r.OriginalFilename
		out.OriginalFilename = &s
	}
	return out
}

// attachmentsLoader bulk-loads attachment rows for a list of messages
// and returns a map keyed by message_id. Used by handlers that emit
// message lists (ListMessages chain + full-tree, SendMessage user
// echo) so each path makes ONE query rather than N.
type attachmentsLoader interface {
	ListAttachmentsForMessages(ctx context.Context, messageIDs []uuid.UUID) ([]store.ListAttachmentsForMessagesRow, error)
}

func loadAttachmentsByMessage(ctx context.Context, q attachmentsLoader, ids []uuid.UUID) (map[string][]*psmithv1.MessageAttachment, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := q.ListAttachmentsForMessages(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string][]*psmithv1.MessageAttachment, len(rows))
	for _, r := range rows {
		key := r.MessageID.String()
		out[key] = append(out[key], attachmentRowToProto(r))
	}
	return out, nil
}

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

func settingsToJSON(s *psmithv1.ConversationSettings) ([]byte, error) {
	if s == nil {
		return nil, nil
	}
	return conversationSettingsMarshaller.Marshal(s)
}

func settingsFromJSON(b []byte) (*psmithv1.ConversationSettings, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var s psmithv1.ConversationSettings
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
func conversationToProto(c store.Conversation, activeContextID string) (*psmithv1.Conversation, error) {
	return conversationToProtoWithActivity(c, activeContextID, c.UpdatedAt)
}

// conversationToProtoWithActivity is the list-path variant — it accepts the
// joined max(messages.created_at) so the sidebar can render "Recently Used"
// without an N+1 round trip.
func conversationToProtoWithActivity(c store.Conversation, activeContextID string, lastActivityAt time.Time) (*psmithv1.Conversation, error) {
	settings, err := settingsFromJSON(c.Settings)
	if err != nil {
		return nil, err
	}
	return &psmithv1.Conversation{
		Id:              c.ID.String(),
		ProfileId:       c.ProfileID.String(),
		Title:           c.Title,
		Settings:        settings,
		ActiveContextId: activeContextID,
		OwnerUserId:     c.UserID.String(),
		CreatedAt:       timestamppb.New(c.CreatedAt),
		ArchivedAt:      tsOrNil(c.ArchivedAt),
		PinnedAt:        tsOrNil(c.PinnedAt),
		UpdatedAt:       timestamppb.New(c.UpdatedAt),
		LastActivityAt:  timestamppb.New(lastActivityAt),
	}, nil
}

// attachStreamingComponents resolves the conversation's plugin pipeline
// and copies any StreamingTagProvider contributions onto the proto.
// Best-effort: a failed pipeline build is logged but doesn't fail the
// caller — the client just loses inline streaming-render for this
// conversation (terminal render still works fine).
func (s *Service) attachStreamingComponents(ctx context.Context, conv store.Conversation, out *psmithv1.Conversation) {
	if out == nil {
		return
	}
	pipeline, err := s.resolvePluginPipeline(ctx, conv.ProfileID)
	if err != nil {
		s.logger.Warn("streaming components: resolve pipeline failed",
			"err", err,
			"conversation_id", conv.ID)
		return
	}
	tags := pipeline.StreamingTags()
	if len(tags) == 0 {
		return
	}
	out.StreamingComponents = make([]*psmithv1.StreamingComponentTag, 0, len(tags))
	for _, t := range tags {
		out.StreamingComponents = append(out.StreamingComponents, &psmithv1.StreamingComponentTag{
			Tag:       t.Tag,
			Component: t.Component,
		})
	}
}

func contextToProto(c store.Context) *psmithv1.Context {
	out := &psmithv1.Context{
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
func listContextRowToProto(r store.ListContextsByConversationRow) *psmithv1.Context {
	out := &psmithv1.Context{
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

func messageToProto(m store.Message) *psmithv1.Message {
	out := &psmithv1.Message{
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
	if calls := toolCallsFromJSON(m.ToolCalls); len(calls) > 0 {
		out.ToolCalls = calls
	}
	if m.FinishReason != nil && *m.FinishReason != "" {
		out.FinishReason = m.FinishReason
	}
	out.IsWelcome = m.IsWelcome
	return out
}

// toolCallsFromJSON decodes the messages.tool_calls JSONB column into the
// proto ToolCall slice. Returns nil on empty / invalid payload — the proto
// shape is repeated, so a missing field is just an empty list.
func toolCallsFromJSON(payload []byte) []*psmithv1.ToolCall {
	if len(payload) == 0 {
		return nil
	}
	var raw []struct {
		ID             string          `json:"id"`
		Name           string          `json:"name"`
		Input          json.RawMessage `json:"input"`
		Output         json.RawMessage `json:"output"`
		Error          string          `json:"error"`
		ElapsedMs      int64           `json:"elapsed_ms"`
		ProviderOpaque string          `json:"provider_opaque"`
	}
	if err := json.Unmarshal(payload, &raw); err != nil {
		return nil
	}
	out := make([]*psmithv1.ToolCall, 0, len(raw))
	for _, r := range raw {
		tc := &psmithv1.ToolCall{
			Id:        r.ID,
			Name:      r.Name,
			Input:     []byte(r.Input),
			Output:    []byte(r.Output),
			ElapsedMs: r.ElapsedMs,
		}
		if r.Error != "" {
			tc.Error = &r.Error
		}
		if r.ProviderOpaque != "" {
			tc.ProviderOpaque = &r.ProviderOpaque
		}
		out = append(out, tc)
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
//  3. Bare-string error: `{"error": "..."}` — providers that send the
//     message as a string instead of an object.
//  4. GitHub / GraphQL-style: `{"errors": [{"message": "..."}, ...]}`.
//  5. FastAPI / DRF: `{"detail": "..."}` (or `[{"msg":"..."}]`).
//  6. OAuth-style: `{"error_description": "..."}`.
//  7. A bare top-level JSON string: `"upstream blew up"`.
//  8. Plaintext (not JSON): the payload verbatim, whitespace-normalised.
//  9. JSON we can't parse for a message: a generic placeholder. We
//     deliberately do NOT dump raw braces — the UI should never show
//     `{"status": 500, "code": "x"}` style blobs.
//
// Returns "" only when the payload was empty to begin with.
func errorTextFromPayload(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}
	raw := strings.TrimSpace(string(payload))
	if raw == "" {
		return ""
	}

	// Try JSON-shape extraction first. The helper handles every known
	// envelope and returns "" if it can't find a usable string.
	if msg := extractMessageFromJSON(payload); msg != "" {
		return msg
	}

	// If the payload LOOKS like JSON (starts with { or [ or "), and we
	// got nothing usable above, return a generic placeholder rather
	// than dumping the raw structure to the user.
	if len(raw) > 0 && (raw[0] == '{' || raw[0] == '[' || raw[0] == '"') {
		return "Upstream returned an error."
	}

	// Plaintext — keep as-is but normalise whitespace + cap length so
	// stack traces / HTML responses don't blow out a banner.
	out := strings.Join(strings.Fields(raw), " ")
	const cap = 512
	if len(out) > cap {
		out = out[:cap] + "…"
	}
	return out
}

// extractMessageFromJSON tries every known JSON shape against a payload
// and returns the first usable message. Returns "" on no match — the
// caller decides what to do with that.
func extractMessageFromJSON(payload []byte) string {
	// Shape 1: normalised wrapper `{"message":"..."}` (also matches
	// our internal chunkErrorPayload, which carries `.raw` too).
	var wrap struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(payload, &wrap); err == nil && wrap.Message != "" {
		return wrap.Message
	}
	// Shape 2: provider envelope `{"error": {"message": "..."}}` —
	// OpenAI, Anthropic, Google.
	var envelope struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(payload, &envelope); err == nil && envelope.Error.Message != "" {
		return envelope.Error.Message
	}
	// Shape 3: `{"error": "string"}`. Decode again as raw map to handle
	// the case where error is a string rather than an object.
	var rawObj map[string]json.RawMessage
	if err := json.Unmarshal(payload, &rawObj); err == nil {
		if v, ok := rawObj["error"]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil && s != "" {
				return s
			}
		}
		// Shape 4: GitHub / GraphQL `{"errors": [{"message": "..."}]}`.
		if v, ok := rawObj["errors"]; ok {
			var arr []struct {
				Message string `json:"message"`
			}
			if json.Unmarshal(v, &arr) == nil && len(arr) > 0 && arr[0].Message != "" {
				return arr[0].Message
			}
		}
		// Shape 5a: `{"detail": "..."}`.
		if v, ok := rawObj["detail"]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil && s != "" {
				return s
			}
			// Shape 5b: `{"detail": [{"msg": "..."}, ...]}` — FastAPI
			// validation errors.
			var arr []struct {
				Msg     string `json:"msg"`
				Message string `json:"message"`
			}
			if json.Unmarshal(v, &arr) == nil && len(arr) > 0 {
				if arr[0].Msg != "" {
					return arr[0].Msg
				}
				if arr[0].Message != "" {
					return arr[0].Message
				}
			}
		}
		// Shape 6: OAuth `{"error_description": "..."}`.
		if v, ok := rawObj["error_description"]; ok {
			var s string
			if json.Unmarshal(v, &s) == nil && s != "" {
				return s
			}
		}
	}
	// Shape 7: a bare top-level JSON string.
	var bare string
	if err := json.Unmarshal(payload, &bare); err == nil && bare != "" {
		return bare
	}
	return ""
}

// messageUsageToProto returns a MessageUsage proto if any usage/cost column
// is populated. Returns nil otherwise so the wire-message stays compact for
// non-assistant rows.
func messageUsageToProto(m store.Message) *psmithv1.MessageUsage {
	if m.InputTokens == nil && m.OutputTokens == nil &&
		m.CacheReadTokens == nil && m.CacheWriteTokens == nil &&
		m.ReasoningTokens == nil &&
		!m.InputCostUsd.Valid && !m.OutputCostUsd.Valid &&
		!m.CacheReadCostUsd.Valid && !m.CacheWriteCostUsd.Valid &&
		!m.ToolCostUsd.Valid &&
		!m.TotalCostUsd.Valid &&
		m.ExplicitCacheAttached == nil {
		return nil
	}
	return &psmithv1.MessageUsage{
		InputTokens:           m.InputTokens,
		OutputTokens:          m.OutputTokens,
		CacheReadTokens:       m.CacheReadTokens,
		CacheWriteTokens:      m.CacheWriteTokens,
		ReasoningTokens:       m.ReasoningTokens,
		InputCostUsd:          numericToFloat64Ptr(m.InputCostUsd),
		OutputCostUsd:         numericToFloat64Ptr(m.OutputCostUsd),
		CacheReadCostUsd:      numericToFloat64Ptr(m.CacheReadCostUsd),
		CacheWriteCostUsd:     numericToFloat64Ptr(m.CacheWriteCostUsd),
		ToolCostUsd:           numericToFloat64Ptr(m.ToolCostUsd),
		TotalCostUsd:          numericToFloat64Ptr(m.TotalCostUsd),
		ExplicitCacheAttached: m.ExplicitCacheAttached,
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
func chainRowToProto(r store.ListMessageAncestorChainRow) *psmithv1.Message {
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
		ToolCostUsd:          r.ToolCostUsd,
		TotalCostUsd:         r.TotalCostUsd,
		ErrorPayload:         r.ErrorPayload,
		ToolCalls:            r.ToolCalls,
		FinishReason:         r.FinishReason,
	})
	out.SiblingCount = r.SiblingCount
	return out
}

// applyDisplay populates m.DisplayContent + m.UiFragments by running
// the active pipeline's DisplayTransformer chain followed by its
// ContentRenderer chain. When the pipeline is empty (or has no
// transformers / renderers), display_content equals content and
// ui_fragments stays empty so clients can always read either field
// without checking for absence.
func applyDisplay(m *psmithv1.Message, pipeline plugins.Pipeline) {
	if m == nil {
		return
	}
	if pipeline.Empty() {
		m.DisplayContent = m.Content
		return
	}
	m.DisplayContent = pipeline.TransformForDisplay(m.Content)
	if parts := pipeline.RenderContent(m.DisplayContent, roleProtoToString(m.Role)); parts != nil {
		m.UiFragments = contentPartsToProto(parts)
	}
}

// contentPartsToProto flattens a renderer pipeline's []ContentPart
// into the wire shape the client renders. Text parts emit a
// fragment with component="text" + props {"text": "..."} so the
// client can render the parts list uniformly without having to
// special-case the absence of a Fragment. Returns nil when the
// list is empty so the proto field stays unset on the wire.
func contentPartsToProto(parts []plugins.ContentPart) []*psmithv1.UIFragment {
	if len(parts) == 0 {
		return nil
	}
	out := make([]*psmithv1.UIFragment, 0, len(parts))
	for _, part := range parts {
		if part.IsText() {
			// Skip empty text segments — they'd render as a
			// no-op anyway and the wire shape stays leaner.
			if part.Text == "" {
				continue
			}
			textProps, _ := json.Marshal(map[string]string{"text": part.Text})
			out = append(out, &psmithv1.UIFragment{
				Component: "text",
				Props:     textProps,
			})
			continue
		}
		out = append(out, &psmithv1.UIFragment{
			Component: part.Fragment.Component,
			Props:     append([]byte(nil), part.Fragment.Props...),
			Key:       part.Fragment.Key,
		})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// roleProtoToString maps the proto enum back to the canonical
// string the plugin Pipeline.RenderContent expects. Mirrors the
// values used elsewhere in the package.
func roleProtoToString(r psmithv1.MessageRole) string {
	switch r {
	case psmithv1.MessageRole_MESSAGE_ROLE_SYSTEM:
		return "system"
	case psmithv1.MessageRole_MESSAGE_ROLE_CONTEXT:
		return "context"
	case psmithv1.MessageRole_MESSAGE_ROLE_USER:
		return "user"
	case psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT:
		return "assistant"
	case psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY:
		return "compression_summary"
	}
	return ""
}

// deviceFactsFromProto translates the wire `[]*psmithv1.DeviceFact`
// into the plugin-side `map[string]string` that
// `OutgoingUserTransformer` consumes. Unknown / unspecified enum
// values are dropped — keeps a misbehaving client from sneaking
// arbitrary fact keys into the pipeline. Empty slice → nil map
// (every plugin tolerates a nil facts map).
func deviceFactsFromProto(in []*psmithv1.DeviceFact) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for _, df := range in {
		if df == nil {
			continue
		}
		key := deviceFactKeyToString(df.Key)
		if key == "" {
			continue
		}
		out[key] = df.Value
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// deviceFactKeyToString maps the proto enum to the plugin-side
// string constants in the plugins package. Single source of truth
// for the wire ↔ runtime correspondence — adding a new
// DeviceFactKey requires updating the enum, the plugins.DeviceFactKey*
// constant, AND this switch (compiler enforces nothing here, so
// the test in plugins/device_facts_test.go pins the round-trip).
func deviceFactKeyToString(k psmithv1.DeviceFactKey) string {
	switch k {
	case psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCALE:
		return plugins.DeviceFactKeyLocale
	case psmithv1.DeviceFactKey_DEVICE_FACT_KEY_TIMEZONE:
		return plugins.DeviceFactKeyTimezone
	case psmithv1.DeviceFactKey_DEVICE_FACT_KEY_PLATFORM:
		return plugins.DeviceFactKeyPlatform
	case psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_CITY:
		return plugins.DeviceFactKeyLocationCity
	case psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_COORDS:
		return plugins.DeviceFactKeyLocationCoords
	default:
		return ""
	}
}

// deviceFactKeyFromString is the inverse of `deviceFactKeyToString`.
// Used by the plugin descriptor RPC to convert each plugin's
// requested-facts list back into proto enums for the wire.
func deviceFactKeyFromString(k string) psmithv1.DeviceFactKey {
	switch k {
	case plugins.DeviceFactKeyLocale:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCALE
	case plugins.DeviceFactKeyTimezone:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_TIMEZONE
	case plugins.DeviceFactKeyPlatform:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_PLATFORM
	case plugins.DeviceFactKeyLocationCity:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_CITY
	case plugins.DeviceFactKeyLocationCoords:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_LOCATION_COORDS
	default:
		return psmithv1.DeviceFactKey_DEVICE_FACT_KEY_UNSPECIFIED
	}
}

func roleStringToEnum(s string) psmithv1.MessageRole {
	switch s {
	case roleSystem:
		return psmithv1.MessageRole_MESSAGE_ROLE_SYSTEM
	case roleContext:
		return psmithv1.MessageRole_MESSAGE_ROLE_CONTEXT
	case roleUser:
		return psmithv1.MessageRole_MESSAGE_ROLE_USER
	case roleAssistant:
		return psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT
	case roleCompressionSummary:
		return psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY
	default:
		return psmithv1.MessageRole_MESSAGE_ROLE_UNSPECIFIED
	}
}

// tsOrNil converts an optional time to an optional proto timestamp.
func tsOrNil(t *time.Time) *timestamppb.Timestamp {
	if t == nil {
		return nil
	}
	return timestamppb.New(*t)
}
