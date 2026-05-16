package mcpserver

import (
	"context"
	"encoding/json"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

// Per-call cap on messages returned. Chat history can grow unbounded;
// this keeps a single tool result under a reasonable token budget for
// the model. The assistant can paginate via context_id + leaf_message_id
// follow-up calls if it really needs older turns.
const messagesPerCallCap = 50

func (s *Server) registerConversationTools() {
	s.register(
		"list_conversations",
		"List recent conversations for the current user. Optional filters: `title_query` (case-insensitive substring), `profile_id` (one profile only). Pagination via `page_size` (default 50) and `page_token`. Use this to discover what the user has been working on.",
		`{"type":"object","properties":{`+
			`"page_size":{"type":"integer","minimum":1,"maximum":200},`+
			`"page_token":{"type":"string"},`+
			`"title_query":{"type":"string"},`+
			`"profile_id":{"type":"string"}`+
			`},"additionalProperties":false}`,
		s.toolListConversations,
	)
	s.register(
		"get_conversation",
		"Read one conversation's metadata + active context (id, title, profile_id, last_activity_at, message_count, cumulative_cost_usd).",
		`{"type":"object","required":["id"],"properties":{"id":{"type":"string"}},"additionalProperties":false}`,
		s.toolGetConversation,
	)
	s.register(
		"list_messages",
		"List messages in one context. Default returns the linear leaf chain (the chat history the user sees). Pass `full_tree: true` to receive every branch. Returns role, content, model, timestamp, error_text. Capped at "+itoa(messagesPerCallCap)+" messages per call — call again with a different context if needed.",
		`{"type":"object","required":["context_id"],"properties":{`+
			`"context_id":{"type":"string"},`+
			`"leaf_message_id":{"type":"string","description":"Optional: pin the chain to this leaf instead of the active context cursor."},`+
			`"full_tree":{"type":"boolean","description":"If true, returns every branch (default false: leaf chain only)."}`+
			`},"additionalProperties":false}`,
		s.toolListMessages,
	)
}

// --- list_conversations --------------------------------------------------

type listConversationsArgs struct {
	PageSize   int32   `json:"page_size"`
	PageToken  string  `json:"page_token"`
	TitleQuery *string `json:"title_query"`
	ProfileID  *string `json:"profile_id"`
}

func (s *Server) toolListConversations(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in listConversationsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	req := &reevev1.ListConversationsRequest{
		PageSize:   in.PageSize,
		PageToken:  in.PageToken,
		TitleQuery: in.TitleQuery,
		ProfileId:  in.ProfileID,
	}
	resp, err := s.conversationsSvc.ListConversations(ctx, connect.NewRequest(req))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetConversations()))
	for _, c := range resp.Msg.GetConversations() {
		out = append(out, conversationSummary(c))
	}
	body := map[string]any{"conversations": out}
	if t := resp.Msg.GetNextPageToken(); t != "" {
		body["next_page_token"] = t
	}
	return textResult(body), nil
}

// --- get_conversation ----------------------------------------------------

type getConversationArgs struct {
	ID string `json:"id"`
}

func (s *Server) toolGetConversation(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in getConversationArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ID == "" {
		return errorResult("id is required"), nil
	}
	resp, err := s.conversationsSvc.GetConversation(ctx, connect.NewRequest(&reevev1.GetConversationRequest{Id: in.ID}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := map[string]any{
		"conversation": conversationDetail(resp.Msg.GetConversation()),
	}
	if ac := resp.Msg.GetActiveContext(); ac != nil {
		out["active_context"] = contextSummary(ac)
	}
	return textResult(out), nil
}

// --- list_messages -------------------------------------------------------

type listMessagesArgs struct {
	ContextID     string  `json:"context_id"`
	LeafMessageID *string `json:"leaf_message_id"`
	FullTree      bool    `json:"full_tree"`
}

func (s *Server) toolListMessages(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in listMessagesArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ContextID == "" {
		return errorResult("context_id is required"), nil
	}
	resp, err := s.conversationsSvc.ListMessages(ctx, connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId:     in.ContextID,
		LeafMessageId: in.LeafMessageID,
		FullTree:      in.FullTree,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	msgs := resp.Msg.GetMessages()
	truncated := false
	if len(msgs) > messagesPerCallCap {
		msgs = msgs[len(msgs)-messagesPerCallCap:]
		truncated = true
	}
	out := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, messageSummary(m))
	}
	body := map[string]any{"messages": out}
	if truncated {
		body["truncated"] = true
		body["truncation_note"] = "Older messages omitted; only the most recent " + itoa(messagesPerCallCap) + " are returned."
	}
	return textResult(body), nil
}

// --- shape helpers -------------------------------------------------------

func conversationSummary(c *reevev1.Conversation) map[string]any {
	out := map[string]any{
		"id":         c.GetId(),
		"profile_id": c.GetProfileId(),
	}
	if c.Title != nil {
		out["title"] = c.GetTitle()
	}
	if t := c.GetLastActivityAt(); t != nil {
		out["last_activity_at"] = t.AsTime().Format("2006-01-02T15:04:05Z07:00")
	}
	return out
}

func conversationDetail(c *reevev1.Conversation) map[string]any {
	out := conversationSummary(c)
	out["active_context_id"] = c.GetActiveContextId()
	if t := c.GetCreatedAt(); t != nil {
		out["created_at"] = t.AsTime().Format("2006-01-02T15:04:05Z07:00")
	}
	return out
}

func contextSummary(c *reevev1.Context) map[string]any {
	out := map[string]any{
		"id":              c.GetId(),
		"conversation_id": c.GetConversationId(),
		"message_count":   c.GetMessageCount(),
	}
	if c.Title != nil {
		out["title"] = c.GetTitle()
	}
	if c.ParentContextId != nil {
		out["parent_context_id"] = c.GetParentContextId()
	}
	if c.CurrentLeafMessageId != nil {
		out["current_leaf_message_id"] = c.GetCurrentLeafMessageId()
	}
	return out
}

func messageSummary(m *reevev1.Message) map[string]any {
	out := map[string]any{
		"id":      m.GetId(),
		"role":    roleString(m.GetRole()),
		"content": m.GetContent(),
	}
	if m.ParentId != nil {
		out["parent_id"] = m.GetParentId()
	}
	if m.ProviderId != nil {
		out["provider_id"] = m.GetProviderId()
	}
	if m.ModelId != nil {
		out["model_id"] = m.GetModelId()
	}
	if t := m.GetCreatedAt(); t != nil {
		out["created_at"] = t.AsTime().Format("2006-01-02T15:04:05Z07:00")
	}
	if m.ErrorText != nil {
		out["error_text"] = m.GetErrorText()
	}
	if m.GetSiblingCount() > 0 {
		out["sibling_count"] = m.GetSiblingCount()
	}
	if m.FinishReason != nil {
		out["finish_reason"] = m.GetFinishReason()
	}
	return out
}

func roleString(r reevev1.MessageRole) string {
	switch r {
	case reevev1.MessageRole_MESSAGE_ROLE_SYSTEM:
		return "system"
	case reevev1.MessageRole_MESSAGE_ROLE_CONTEXT:
		return "context"
	case reevev1.MessageRole_MESSAGE_ROLE_USER:
		return "user"
	case reevev1.MessageRole_MESSAGE_ROLE_ASSISTANT:
		return "assistant"
	case reevev1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY:
		return "compression_summary"
	default:
		return "unspecified"
	}
}

// itoa is a tiny strconv.Itoa shim; using it inline keeps the
// imports minimal in this file (we already import nothing from
// strconv elsewhere here, so this saves a single-use import).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
