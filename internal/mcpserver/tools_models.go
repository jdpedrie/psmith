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
	s.register(
		"list_provider_types",
		"List every model-provider driver compiled into this Reeve build (anthropic, openai, google, openrouter, openai-compatible, etc.). The user can configure one user_model_provider per `provider_type`. Use this to advise the user on what providers are available before they've added any.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListProviderTypes,
	)
	s.register(
		"list_provider_templates",
		"List the curated catalog of common providers Reeve knows about (Anthropic, OpenAI, Google, Groq, Together, Fireworks, etc.) with their driver type, default API base URL, and conventional API-key env var. Use this when suggesting a provider to add: the user still needs to create the row themselves through the Settings UI (assistants cannot enter API keys), but knowing the template helps the user recognize what they're picking.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListProviderTemplates,
	)
	s.register(
		"discover_models",
		"Ask one of the user's configured providers what models it exposes. Returns each model with its display name, capabilities, pricing, modalities, and an `already_enabled` flag. Pass the result IDs to `enable_models` to add the chosen subset to the user's enabled list. Read-only — discovery does not enable anything.",
		`{"type":"object","required":["user_model_provider_id"],"properties":{"user_model_provider_id":{"type":"string","description":"UUID of the user_model_provider to discover models from."}},"additionalProperties":false}`,
		s.toolDiscoverModels,
	)
	s.register(
		"enable_models",
		"Enable one or more models on a configured provider. Models stay enabled until the user explicitly disables them (or reinstalls). Idempotent: re-enabling an already-enabled model is a no-op. Returns the freshly-enabled UserModel rows.",
		`{"type":"object","required":["user_model_provider_id","model_ids"],"properties":{`+
			`"user_model_provider_id":{"type":"string"},`+
			`"model_ids":{"type":"array","items":{"type":"string"},"description":"Model IDs (machine names) from discover_models. Can include multiple — they enable in one batch."}`+
			`},"additionalProperties":false}`,
		s.toolEnableModels,
	)
	s.register(
		"toggle_user_model_favorite",
		"Mark a UserModel as a favorite (or un-favorite). Favorites sort to the top of model pickers in the UI. Cosmetic only — no behavior change.",
		`{"type":"object","required":["user_model_provider_id","model_id","favorite"],"properties":{`+
			`"user_model_provider_id":{"type":"string"},`+
			`"model_id":{"type":"string"},`+
			`"favorite":{"type":"boolean"}`+
			`},"additionalProperties":false}`,
		s.toolToggleFavorite,
	)
	s.register(
		"test_user_model_provider",
		"Ping a provider to verify it's reachable and the credentials work. Returns ok/false plus an error message and the count of models the provider currently exposes. Use this before suggesting a configuration change so you can ground the user in the actual current state.",
		`{"type":"object","required":["user_model_provider_id"],"properties":{"user_model_provider_id":{"type":"string"}},"additionalProperties":false}`,
		s.toolTestProvider,
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

// --- list_provider_types -------------------------------------------------

func (s *Server) toolListProviderTypes(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.modelProvidersSvc.ListProviderTypes(
		ctx,
		connect.NewRequest(&reevev1.ListProviderTypesRequest{}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetTypes()))
	for _, pt := range resp.Msg.GetTypes() {
		out = append(out, map[string]any{
			"name":         pt.GetName(),
			"display_name": pt.GetDisplayName(),
			"stateful":     pt.GetStateful(),
		})
	}
	return textResult(map[string]any{"provider_types": out}), nil
}

// --- list_provider_templates ---------------------------------------------

func (s *Server) toolListProviderTemplates(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.modelProvidersSvc.ListProviderTemplates(
		ctx,
		connect.NewRequest(&reevev1.ListProviderTemplatesRequest{}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetTemplates()))
	for _, t := range resp.Msg.GetTemplates() {
		entry := map[string]any{
			"catalog_provider_id": t.GetCatalogProviderId(),
			"name":                t.GetName(),
			"driver_type":         t.GetDriverType(),
		}
		if t.ApiBase != nil {
			entry["api_base"] = t.GetApiBase()
		}
		if t.EnvKey != nil {
			entry["env_key"] = t.GetEnvKey()
		}
		if t.DocUrl != nil {
			entry["doc_url"] = t.GetDocUrl()
		}
		if t.PresetId != nil {
			entry["preset_id"] = t.GetPresetId()
		}
		out = append(out, entry)
	}
	return textResult(map[string]any{"templates": out}), nil
}

// --- discover_models -----------------------------------------------------

type discoverModelsArgs struct {
	UserModelProviderID string `json:"user_model_provider_id"`
}

func (s *Server) toolDiscoverModels(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in discoverModelsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.UserModelProviderID == "" {
		return errorResult("user_model_provider_id is required"), nil
	}
	resp, err := s.modelProvidersSvc.DiscoverModels(
		ctx,
		connect.NewRequest(&reevev1.DiscoverModelsRequest{UserModelProviderId: in.UserModelProviderID}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetModels()))
	for _, m := range resp.Msg.GetModels() {
		entry := map[string]any{
			"model_id":        m.GetModelId(),
			"display_name":    m.GetDisplayName(),
			"already_enabled": m.GetAlreadyEnabled(),
		}
		if m.ContextWindow != nil {
			entry["context_window"] = m.GetContextWindow()
		}
		if m.MaxOutputTokens != nil {
			entry["max_output_tokens"] = m.GetMaxOutputTokens()
		}
		if c := m.GetCapabilities(); c != nil {
			entry["capabilities"] = map[string]any{
				"streaming":        c.GetStreaming(),
				"thinking":         c.GetThinking(),
				"tool_use":         c.GetToolUse(),
				"vision":           c.GetVision(),
				"prompt_caching":   c.GetPromptCaching(),
				"generates_images": c.GetGeneratesImages(),
			}
		}
		out = append(out, entry)
	}
	return textResult(map[string]any{"models": out}), nil
}

// --- enable_models -------------------------------------------------------

type enableModelsArgs struct {
	UserModelProviderID string   `json:"user_model_provider_id"`
	ModelIDs            []string `json:"model_ids"`
}

func (s *Server) toolEnableModels(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in enableModelsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.UserModelProviderID == "" {
		return errorResult("user_model_provider_id is required"), nil
	}
	if len(in.ModelIDs) == 0 {
		return errorResult("model_ids must include at least one entry"), nil
	}
	resp, err := s.modelProvidersSvc.EnableModels(
		ctx,
		connect.NewRequest(&reevev1.EnableModelsRequest{
			UserModelProviderId: in.UserModelProviderID,
			ModelIds:            in.ModelIDs,
		}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetEnabled()))
	for _, m := range resp.Msg.GetEnabled() {
		out = append(out, userModelSummary(m))
	}
	return textResult(map[string]any{"enabled": out}), nil
}

// --- toggle_user_model_favorite ------------------------------------------

type toggleFavoriteArgs struct {
	UserModelProviderID string `json:"user_model_provider_id"`
	ModelID             string `json:"model_id"`
	Favorite            bool   `json:"favorite"`
}

func (s *Server) toolToggleFavorite(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in toggleFavoriteArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.UserModelProviderID == "" || in.ModelID == "" {
		return errorResult("user_model_provider_id and model_id are required"), nil
	}
	resp, err := s.modelProvidersSvc.ToggleUserModelFavorite(
		ctx,
		connect.NewRequest(&reevev1.ToggleUserModelFavoriteRequest{
			UserModelProviderId: in.UserModelProviderID,
			ModelId:             in.ModelID,
			Favorite:            in.Favorite,
		}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	return textResult(map[string]any{"model": userModelSummary(resp.Msg.GetModel())}), nil
}

// --- test_user_model_provider --------------------------------------------

type testProviderArgs struct {
	UserModelProviderID string `json:"user_model_provider_id"`
}

func (s *Server) toolTestProvider(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in testProviderArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.UserModelProviderID == "" {
		return errorResult("user_model_provider_id is required"), nil
	}
	resp, err := s.modelProvidersSvc.TestUserModelProvider(
		ctx,
		connect.NewRequest(&reevev1.TestUserModelProviderRequest{UserModelProviderId: in.UserModelProviderID}),
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := map[string]any{
		"ok":          resp.Msg.GetOk(),
		"latency_ms":  resp.Msg.GetLatencyMs(),
		"model_count": resp.Msg.GetModelCount(),
	}
	if msg := resp.Msg.GetErrorMessage(); msg != "" {
		out["error_message"] = msg
	}
	return textResult(out), nil
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
