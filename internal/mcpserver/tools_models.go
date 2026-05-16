package mcpserver

import (
	"context"
	"encoding/json"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

func (s *Server) registerModelTools() {
	s.register(
		"list_providers",
		"List every model provider configured for the current user (Anthropic, OpenAI, Google, OpenRouter, etc.). Returns id, type (driver), and label. Use this when picking a default_provider_id for a profile.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListProviders,
	)
	s.register(
		"list_models",
		"List every enabled model across every provider for the current user. Returns provider id + driver + label, plus model id, display name, and capabilities (streaming, thinking, tool_use, vision). Use this when picking a default_model_id for a profile or when recommending a model to the user.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListModels,
	)
}

func (s *Server) toolListProviders(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.modelProvidersSvc.ListUserModelProviders(
		ctx,
		connect.NewRequest(&reevev1.ListUserModelProvidersRequest{}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetProviders()))
	for _, p := range resp.Msg.GetProviders() {
		out = append(out, providerSummary(p))
	}
	return textResult(map[string]any{"providers": out}), nil
}

func (s *Server) toolListModels(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.modelProvidersSvc.ListAllUserModels(
		ctx,
		connect.NewRequest(&reevev1.ListAllUserModelsRequest{}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetEntries()))
	for _, e := range resp.Msg.GetEntries() {
		entry := map[string]any{
			"provider": providerSummary(e.GetProvider()),
			"model":    userModelSummary(e.GetModel()),
		}
		out = append(out, entry)
	}
	return textResult(map[string]any{"models": out}), nil
}

// providerSummary keeps the secret-bearing config bytes off the wire.
// The assistant only needs the id, driver type, and label to reference
// a provider in subsequent tool calls.
func providerSummary(p *reevev1.UserModelProvider) map[string]any {
	return map[string]any{
		"id":    p.GetId(),
		"type":  p.GetType(),
		"label": p.GetLabel(),
	}
}

// userModelSummary projects a UserModel down to the fields the
// assistant uses when picking a model. Excludes snapshotted pricing
// and the per-model CallSettings — both noisy and not load-bearing
// for the typical "which model should I use" decision.
func userModelSummary(m *reevev1.UserModel) map[string]any {
	out := map[string]any{
		"user_model_provider_id": m.GetUserModelProviderId(),
		"model_id":               m.GetModelId(),
		"display_name":           m.GetDisplayName(),
		"favorite":               m.GetFavorite(),
	}
	if m.ContextWindow != nil {
		out["context_window"] = m.GetContextWindow()
	}
	if m.MaxOutputTokens != nil {
		out["max_output_tokens"] = m.GetMaxOutputTokens()
	}
	if c := m.GetCapabilities(); c != nil {
		out["capabilities"] = map[string]any{
			"streaming":        c.GetStreaming(),
			"thinking":         c.GetThinking(),
			"tool_use":         c.GetToolUse(),
			"vision":           c.GetVision(),
			"prompt_caching":   c.GetPromptCaching(),
			"generates_images": c.GetGeneratesImages(),
		}
	}
	return out
}
