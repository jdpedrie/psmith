package mcpserver

import (
	"context"
	"encoding/json"
	"fmt"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
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
		"get_conversation_plugins",
		"Read the LITERAL stored plugin overrides for one conversation. Empty list means \"no overrides — falls back to the profile-chain pipeline.\" For the merged view (what's actually running), use resolve_conversation_pipeline.",
		`{"type":"object","required":["conversation_id"],"properties":{"conversation_id":{"type":"string"}},"additionalProperties":false}`,
		s.toolGetConversationPlugins,
	)
	s.register(
		"set_conversation_plugins",
		"Atomically replace this conversation's plugin OVERRIDES (not the full pipeline). Merged on top of the profile chain at resolve time: same-name entries override the inherited plugin's config; `disabled: true` rows subtract an inherited plugin for this conversation only. Pass an empty list to clear all overrides (the conversation falls back to the profile-chain pipeline).",
		`{"type":"object","required":["conversation_id","plugins"],"properties":{`+
			`"conversation_id":{"type":"string"},`+
			`"plugins":{"type":"array","description":"Ordered list of overrides. Order is preserved on the stored ordinal but the resolver re-sorts by ordinal across all sources at runtime.","items":{"type":"object","required":["plugin_name","config_json"],"properties":{`+
			`"plugin_name":{"type":"string","description":"Machine name from registered_plugins."},`+
			`"config_json":{"type":"string","description":"Plugin config as a JSON-encoded string. Pass \"{}\" when disabling (config is ignored)."},`+
			`"disabled":{"type":"boolean","description":"If true, the inherited plugin of this name is removed from the conversation's resolved pipeline."}`+
			`},"additionalProperties":false}}`+
			`},"additionalProperties":false}`,
		s.toolSetConversationPlugins,
	)
	s.register(
		"resolve_conversation_pipeline",
		"Returns the merged view of plugins running for one conversation — profile chain + conversation overrides + disabled subtracts already applied. Each entry is tagged with where it came from (profile-chain vs conversation-override).",
		`{"type":"object","required":["conversation_id"],"properties":{"conversation_id":{"type":"string"}},"additionalProperties":false}`,
		s.toolResolveConversationPipeline,
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
	req := &psmithv1.ListConversationsRequest{
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
	resp, err := s.conversationsSvc.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: in.ID}))
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
	resp, err := s.conversationsSvc.ListMessages(ctx, connect.NewRequest(&psmithv1.ListMessagesRequest{
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

// --- get_conversation_plugins -------------------------------------------

type getConversationPluginsArgs struct {
	ConversationID string `json:"conversation_id"`
}

func (s *Server) toolGetConversationPlugins(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in getConversationPluginsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ConversationID == "" {
		return errorResult("conversation_id is required"), nil
	}
	resp, err := s.conversationsSvc.GetConversationPlugins(ctx, connect.NewRequest(&psmithv1.GetConversationPluginsRequest{
		ConversationId: in.ConversationID,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetPlugins()))
	for _, p := range resp.Msg.GetPlugins() {
		out = append(out, conversationPluginDetail(p))
	}
	return textResult(map[string]any{"plugins": out}), nil
}

// --- set_conversation_plugins -------------------------------------------

type setConversationPluginsArgs struct {
	ConversationID string `json:"conversation_id"`
	Plugins        []struct {
		PluginName string `json:"plugin_name"`
		ConfigJSON string `json:"config_json"`
		Disabled   bool   `json:"disabled"`
	} `json:"plugins"`
}

func (s *Server) toolSetConversationPlugins(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in setConversationPluginsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ConversationID == "" {
		return errorResult("conversation_id is required"), nil
	}
	overrides := make([]*psmithv1.ConversationPlugin, 0, len(in.Plugins))
	for i, p := range in.Plugins {
		if p.PluginName == "" {
			return errorResult(fmt.Sprintf("plugins[%d].plugin_name is required", i)), nil
		}
		cfg := p.ConfigJSON
		if cfg == "" {
			cfg = "{}"
		}
		if !p.Disabled && !json.Valid([]byte(cfg)) {
			return errorResult(fmt.Sprintf("plugins[%d].config_json is not valid JSON: %q", i, cfg)), nil
		}
		overrides = append(overrides, &psmithv1.ConversationPlugin{
			PluginName: p.PluginName,
			Config:     []byte(cfg),
			Disabled:   p.Disabled,
		})
	}
	resp, err := s.conversationsSvc.SetConversationPlugins(ctx, connect.NewRequest(&psmithv1.SetConversationPluginsRequest{
		ConversationId: in.ConversationID,
		Plugins:        overrides,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetPlugins()))
	for _, p := range resp.Msg.GetPlugins() {
		out = append(out, conversationPluginDetail(p))
	}
	return textResult(map[string]any{"plugins": out}), nil
}

// --- resolve_conversation_pipeline --------------------------------------

type resolveConversationPipelineArgs struct {
	ConversationID string `json:"conversation_id"`
}

func (s *Server) toolResolveConversationPipeline(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in resolveConversationPipelineArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ConversationID == "" {
		return errorResult("conversation_id is required"), nil
	}
	resp, err := s.conversationsSvc.ResolveConversationPipeline(ctx, connect.NewRequest(&psmithv1.ResolveConversationPipelineRequest{
		ConversationId: in.ConversationID,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetEntries()))
	for _, e := range resp.Msg.GetEntries() {
		out = append(out, resolvedPipelineEntryDetail(e))
	}
	return textResult(map[string]any{"entries": out}), nil
}

// --- shape helpers -------------------------------------------------------

func conversationSummary(c *psmithv1.Conversation) map[string]any {
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

func conversationDetail(c *psmithv1.Conversation) map[string]any {
	out := conversationSummary(c)
	out["active_context_id"] = c.GetActiveContextId()
	if t := c.GetCreatedAt(); t != nil {
		out["created_at"] = t.AsTime().Format("2006-01-02T15:04:05Z07:00")
	}
	return out
}

func contextSummary(c *psmithv1.Context) map[string]any {
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

func messageSummary(m *psmithv1.Message) map[string]any {
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

func conversationPluginDetail(p *psmithv1.ConversationPlugin) map[string]any {
	out := map[string]any{
		"plugin_name": p.GetPluginName(),
		"ordinal":     p.GetOrdinal(),
		"disabled":    p.GetDisabled(),
	}
	cfgBytes := p.GetConfig()
	if len(cfgBytes) == 0 {
		out["config"] = map[string]any{}
	} else {
		var cfg any
		if err := json.Unmarshal(cfgBytes, &cfg); err != nil {
			out["config_raw"] = string(cfgBytes)
		} else {
			out["config"] = cfg
		}
	}
	return out
}

func resolvedPipelineEntryDetail(e *psmithv1.ResolvedPipelineEntry) map[string]any {
	out := map[string]any{
		"plugin_name": e.GetPluginName(),
		"ordinal":     e.GetOrdinal(),
		"source":      pipelineSourceString(e.GetSource()),
	}
	cfgBytes := e.GetConfig()
	if len(cfgBytes) == 0 {
		out["config"] = map[string]any{}
	} else {
		var cfg any
		if err := json.Unmarshal(cfgBytes, &cfg); err != nil {
			out["config_raw"] = string(cfgBytes)
		} else {
			out["config"] = cfg
		}
	}
	return out
}

func pipelineSourceString(s psmithv1.ResolvedPipelineSource) string {
	switch s {
	case psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_PROFILE:
		return "profile"
	case psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_CONVERSATION:
		return "conversation"
	default:
		return "unspecified"
	}
}

func roleString(r psmithv1.MessageRole) string {
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
