package mcpserver

import (
	"context"
	"encoding/json"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/elicit"
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
	s.register(
		"create_user_model_provider",
		"Create a new model provider for the user. The API key is collected directly from the user via an in-protocol elicitation prompt — you never see the value, it never enters chat history, and the LLM provider never receives it. Use this whenever the user wants to add a new provider (Anthropic, OpenAI, Google, OpenRouter, an openai-compatible endpoint, etc.). Args: `type` (the driver name from list_provider_types), `label` (display name), and `base_url` (required only for openai-compatible providers). The user must accept the elicitation for the call to succeed; if they decline or cancel, returns isError with a clear message.",
		`{"type":"object","required":["type","label"],"properties":{`+
			`"type":{"type":"string","description":"Driver type name (e.g. \"anthropic\", \"openai\", \"google\", \"openai-compatible\"). See list_provider_types."},`+
			`"label":{"type":"string","description":"Display name shown in pickers. Required."},`+
			`"base_url":{"type":"string","description":"API base URL — required for openai-compatible providers, ignored for native drivers."},`+
			`"preset_id":{"type":"string","description":"Optional preset id for openai-compatible providers (see list_provider_templates)."}`+
			`},"additionalProperties":false}`,
		s.toolCreateProviderWithElicit,
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

// --- create_user_model_provider (with elicitation for secrets) -----------

type createProviderArgs struct {
	Type     string `json:"type"`
	Label    string `json:"label"`
	BaseURL  string `json:"base_url"`
	PresetID string `json:"preset_id"`
}

func (s *Server) toolCreateProviderWithElicit(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in createProviderArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.Type == "" {
		return errorResult("type is required"), nil
	}
	if in.Label == "" {
		return errorResult("label is required"), nil
	}
	if in.Type == "openai-compatible" && in.BaseURL == "" {
		return errorResult("base_url is required for openai-compatible providers"), nil
	}

	// Elicitation is the protocol primitive that keeps the secret out
	// of LLM context: the value flows user→server through the client's
	// direct response endpoint, never via the assistant's content or
	// tool args. Tools that need this capability fail loudly when it's
	// missing (only the inproc transport carries it today).
	ec, ok := elicit.FromContext(ctx)
	if !ok {
		return errorResult("this tool requires elicitation support (in-process MCP transport only)"), nil
	}

	// Schema: one password-format string field. Clients render
	// `format: password` as a secure text input.
	schema := []byte(`{"type":"object","required":["api_key"],"properties":{"api_key":{"type":"string","format":"password","description":"API key for ` + in.Type + `"}},"additionalProperties":false}`)

	resp, err := ec.Elicit(ctx, elicit.Request{
		Message:         "Paste your API key for " + in.Label + ". It's stored encrypted on this Reeve instance and never sent to the LLM provider.",
		RequestedSchema: schema,
	})
	if err != nil {
		return errorResult("elicitation failed: " + err.Error()), nil
	}
	if resp.Action != elicit.ActionAccept {
		return errorResult("user " + string(resp.Action) + "ed the secret prompt — provider not created"), nil
	}

	var content struct {
		APIKey string `json:"api_key"`
	}
	if err := json.Unmarshal(resp.Content, &content); err != nil {
		return errorResult("decode elicit response: " + err.Error()), nil
	}
	if content.APIKey == "" {
		return errorResult("api_key is empty"), nil
	}

	// Assemble the config blob the driver expects. Shape mirrors the
	// AddProviderSheet form: api_key plus the optional pieces for
	// openai-compatible providers.
	configMap := map[string]string{"api_key": content.APIKey}
	if in.BaseURL != "" {
		configMap["base_url"] = in.BaseURL
	}
	if in.PresetID != "" {
		configMap["preset_id"] = in.PresetID
	}
	configBytes, err := json.Marshal(configMap)
	if err != nil {
		return errorResult("marshal config: " + err.Error()), nil
	}

	created, err := s.modelProvidersSvc.CreateUserModelProvider(ctx, connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   in.Type,
		Label:  in.Label,
		Config: configBytes,
	}))
	if err != nil {
		return errorResult("create provider: " + err.Error()), nil
	}

	return textResult(map[string]any{
		"provider": providerSummary(created.Msg.GetProvider()),
		"hint":     "Provider created. Next, call discover_models to see what's available, then enable_models to pick at least one.",
	}), nil
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
