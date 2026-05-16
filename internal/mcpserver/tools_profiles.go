package mcpserver

import (
	"context"
	"encoding/json"
	"fmt"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

func (s *Server) registerProfileTools() {
	s.register(
		"list_profiles",
		"List every profile owned by the current user. Returns id, name, description, favorite, and parent_only flags. Use this first when working with profiles to discover what exists.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListProfiles,
	)
	s.register(
		"get_profile",
		"Read full details for one profile by id, including system message, default user message, default model, compression settings, and the configured plugin pipeline. Pass `resolve: true` to also receive the parent-chain-resolved view (every inherited field filled in).",
		`{"type":"object","required":["id"],"properties":{"id":{"type":"string","description":"Profile UUID."},"resolve":{"type":"boolean","description":"If true, also return the parent-chain-resolved profile."}},"additionalProperties":false}`,
		s.toolGetProfile,
	)
	s.register(
		"create_profile",
		"Create a new profile owned by the current user. `name` is required; every other field is optional. To inherit from another profile, pass its id as `parent_profile_id` — every unset field on the new profile resolves through that parent. Returns the created profile.",
		`{"type":"object","required":["name"],"properties":{`+
			`"name":{"type":"string","description":"Display name. Must be non-empty."},`+
			`"description":{"type":"string","description":"Free-form description for the profile picker. Optional."},`+
			`"parent_profile_id":{"type":"string","description":"Optional UUID of an existing profile to inherit unset fields from."},`+
			`"system_message":{"type":"string","description":"Full system prompt sent at the top of every turn. If unset, falls back to the parent profile."},`+
			`"default_user_message":{"type":"string","description":"Pre-filled composer text for new conversations."},`+
			`"compression_guide":{"type":"string","description":"Free-form instructions appended to the system message during a Compact run."},`+
			`"favorite":{"type":"boolean","description":"When true, profile sorts to the top of pickers."},`+
			`"parent_only":{"type":"boolean","description":"When true, the profile is hidden from the new-conversation picker (usable only as a parent)."}`+
			`},"additionalProperties":false}`,
		s.toolCreateProfile,
	)
	s.register(
		"update_profile",
		"Update a profile by id. Pass only the fields you want to change. Pass `clear_fields: [\"system_message\"]` (etc.) to revert a field to its inherited value.",
		`{"type":"object","required":["id"],"properties":{`+
			`"id":{"type":"string","description":"Profile UUID."},`+
			`"name":{"type":"string"},`+
			`"description":{"type":"string"},`+
			`"system_message":{"type":"string"},`+
			`"default_user_message":{"type":"string"},`+
			`"compression_guide":{"type":"string"},`+
			`"favorite":{"type":"boolean"},`+
			`"parent_only":{"type":"boolean"},`+
			`"clear_fields":{"type":"array","items":{"type":"string"},"description":"Field names to revert to inherited value (e.g. \"system_message\", \"default_user_message\", \"compression_guide\")."}`+
			`},"additionalProperties":false}`,
		s.toolUpdateProfile,
	)
	s.register(
		"registered_plugins",
		"REQUIRED before any work on a profile's plugin pipeline. Returns every plugin compiled into this Reeve build with its machine name, display name, description, capabilities (which interfaces it implements), and config_fields (the typed schema for its per-instance config). Without calling this you don't know which plugins exist or what shape their config takes — set_profile_plugins will fail with bad_argument if you guess. Re-call after a Reeve restart in case the build changed.",
		`{"type":"object","properties":{},"additionalProperties":false}`,
		s.toolListPluginTypes,
	)
	s.register(
		"get_profile_plugins",
		"Read the plugin pipeline attached to one profile. Empty list means the profile inherits from its parent. Each entry returns the plugin name, ordinal, and config (decoded as a JSON object).",
		`{"type":"object","required":["profile_id"],"properties":{"profile_id":{"type":"string"}},"additionalProperties":false}`,
		s.toolGetProfilePlugins,
	)
	s.register(
		"set_profile_plugins",
		"Replace a profile's plugin pipeline atomically. The order of `plugins` is the execution order (index 0 runs first). Each plugin's `config_json` is a JSON-encoded string matching the shape advertised by registered_plugins (the `config_fields` list) — pass `\"{}\"` for plugins with no config, otherwise a JSON object literal like `\"{\\\"output_mode\\\":\\\"component\\\"}\"`. Replaces the entire pipeline; pass an empty list to clear it (which makes the profile inherit from its parent).",
		`{"type":"object","required":["profile_id","plugins"],"properties":{`+
			`"profile_id":{"type":"string"},`+
			`"plugins":{"type":"array","description":"Ordered list of plugins to attach.","items":{"type":"object","required":["plugin_name","config_json"],"properties":{`+
			`"plugin_name":{"type":"string","description":"Machine name from registered_plugins (e.g. \"lettered_choices\", \"basic_grounding\")."},`+
			`"config_json":{"type":"string","description":"Plugin config as a JSON-encoded string. Use \"{}\" for plugins with no config; otherwise a JSON object whose keys match the plugin's config_fields, e.g. \"{\\\"keep_last_n\\\":1}\"."}`+
			`},"additionalProperties":false}}`+
			`},"additionalProperties":false}`,
		s.toolSetProfilePlugins,
	)
}

// --- list_profiles -------------------------------------------------------

func (s *Server) toolListProfiles(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.profilesSvc.ListProfiles(ctx, connect.NewRequest(&reevev1.ListProfilesRequest{}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetProfiles()))
	for _, p := range resp.Msg.GetProfiles() {
		out = append(out, profileSummary(p))
	}
	return textResult(map[string]any{"profiles": out}), nil
}

// --- get_profile ---------------------------------------------------------

type getProfileArgs struct {
	ID      string `json:"id"`
	Resolve bool   `json:"resolve"`
}

func (s *Server) toolGetProfile(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in getProfileArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ID == "" {
		return errorResult("id is required"), nil
	}
	resp, err := s.profilesSvc.GetProfile(ctx, connect.NewRequest(&reevev1.GetProfileRequest{
		Id:      in.ID,
		Resolve: in.Resolve,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := map[string]any{"profile": profileDetail(resp.Msg.GetProfile())}
	if in.Resolve && resp.Msg.GetResolved() != nil {
		out["resolved"] = profileDetail(resp.Msg.GetResolved())
	}
	return textResult(out), nil
}

// --- create_profile ------------------------------------------------------

type createProfileArgs struct {
	Name               string  `json:"name"`
	Description        string  `json:"description"`
	ParentProfileID    *string `json:"parent_profile_id"`
	SystemMessage      *string `json:"system_message"`
	DefaultUserMessage *string `json:"default_user_message"`
	CompressionGuide   *string `json:"compression_guide"`
	Favorite           bool    `json:"favorite"`
	ParentOnly         bool    `json:"parent_only"`
}

func (s *Server) toolCreateProfile(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in createProfileArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.Name == "" {
		return errorResult("name is required"), nil
	}
	req := &reevev1.CreateProfileRequest{
		Name:               in.Name,
		Description:        in.Description,
		ParentProfileId:    in.ParentProfileID,
		SystemMessage:      in.SystemMessage,
		DefaultUserMessage: in.DefaultUserMessage,
		CompressionGuide:   in.CompressionGuide,
		Favorite:           in.Favorite,
		ParentOnly:         in.ParentOnly,
	}
	resp, err := s.profilesSvc.CreateProfile(ctx, connect.NewRequest(req))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	return textResult(map[string]any{"profile": profileDetail(resp.Msg.GetProfile())}), nil
}

// --- update_profile ------------------------------------------------------

type updateProfileArgs struct {
	ID                 string   `json:"id"`
	Name               *string  `json:"name"`
	Description        *string  `json:"description"`
	SystemMessage      *string  `json:"system_message"`
	DefaultUserMessage *string  `json:"default_user_message"`
	CompressionGuide   *string  `json:"compression_guide"`
	Favorite           *bool    `json:"favorite"`
	ParentOnly         *bool    `json:"parent_only"`
	ClearFields        []string `json:"clear_fields"`
}

func (s *Server) toolUpdateProfile(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in updateProfileArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ID == "" {
		return errorResult("id is required"), nil
	}
	req := &reevev1.UpdateProfileRequest{
		Id:                 in.ID,
		Name:               in.Name,
		SystemMessage:      in.SystemMessage,
		DefaultUserMessage: in.DefaultUserMessage,
		CompressionGuide:   in.CompressionGuide,
		Description:        in.Description,
		Favorite:           in.Favorite,
		ParentOnly:         in.ParentOnly,
		ClearFields:        in.ClearFields,
	}
	resp, err := s.profilesSvc.UpdateProfile(ctx, connect.NewRequest(req))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	return textResult(map[string]any{"profile": profileDetail(resp.Msg.GetProfile())}), nil
}

// --- list_plugin_types ---------------------------------------------------

func (s *Server) toolListPluginTypes(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	resp, err := s.profilesSvc.ListPluginTypes(ctx, connect.NewRequest(&reevev1.ListPluginTypesRequest{}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetPluginTypes()))
	for _, pt := range resp.Msg.GetPluginTypes() {
		out = append(out, pluginTypeDetail(pt))
	}
	return textResult(map[string]any{"plugin_types": out}), nil
}

// --- get_profile_plugins -------------------------------------------------

type getProfilePluginsArgs struct {
	ProfileID string `json:"profile_id"`
}

func (s *Server) toolGetProfilePlugins(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in getProfilePluginsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ProfileID == "" {
		return errorResult("profile_id is required"), nil
	}
	resp, err := s.profilesSvc.GetProfilePlugins(ctx, connect.NewRequest(&reevev1.GetProfilePluginsRequest{
		ProfileId: in.ProfileID,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetPlugins()))
	for _, p := range resp.Msg.GetPlugins() {
		out = append(out, profilePluginDetail(p))
	}
	return textResult(map[string]any{"plugins": out}), nil
}

// --- set_profile_plugins -------------------------------------------------

// setProfilePluginsArgs carries the typed args. `config_json` is a
// string (not a nested object) because Gemini's function-calling
// implementation requires concrete `properties` on every `object`-typed
// schema; an open-ended config object causes MALFORMED_FUNCTION_CALL.
// Stringifying lets the model emit whatever JSON the plugin actually
// accepts without us having to predeclare a schema for every plugin.
type setProfilePluginsArgs struct {
	ProfileID string `json:"profile_id"`
	Plugins   []struct {
		PluginName string `json:"plugin_name"`
		ConfigJSON string `json:"config_json"`
	} `json:"plugins"`
}

func (s *Server) toolSetProfilePlugins(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in setProfilePluginsArgs
	if err := json.Unmarshal(args, &in); err != nil {
		return errorResult("invalid arguments: " + err.Error()), nil
	}
	if in.ProfileID == "" {
		return errorResult("profile_id is required"), nil
	}
	plugins := make([]*reevev1.ProfilePlugin, 0, len(in.Plugins))
	for i, p := range in.Plugins {
		if p.PluginName == "" {
			return errorResult(fmt.Sprintf("plugins[%d].plugin_name is required", i)), nil
		}
		cfgStr := p.ConfigJSON
		if cfgStr == "" {
			cfgStr = "{}"
		}
		// Validate the config parses as JSON before sending it through —
		// `set_profile_plugins` would reject malformed bytes downstream
		// with a less-helpful error, and the model can correct its
		// JSON if we tell it which entry was bad.
		if !json.Valid([]byte(cfgStr)) {
			return errorResult(fmt.Sprintf("plugins[%d].config_json is not valid JSON: %q", i, cfgStr)), nil
		}
		plugins = append(plugins, &reevev1.ProfilePlugin{
			PluginName: p.PluginName,
			Config:     []byte(cfgStr),
		})
	}
	resp, err := s.profilesSvc.SetProfilePlugins(ctx, connect.NewRequest(&reevev1.SetProfilePluginsRequest{
		ProfileId: in.ProfileID,
		Plugins:   plugins,
	}))
	if err != nil {
		return errorResult(err.Error()), nil
	}
	out := make([]map[string]any, 0, len(resp.Msg.GetPlugins()))
	for _, p := range resp.Msg.GetPlugins() {
		out = append(out, profilePluginDetail(p))
	}
	return textResult(map[string]any{"plugins": out}), nil
}

// --- shape helpers -------------------------------------------------------

// profileSummary is the shape returned by list_profiles — kept lean so
// the assistant can scan it without burning context. Detail fields
// (system message, plugin pipeline, etc.) come from get_profile.
func profileSummary(p *reevev1.Profile) map[string]any {
	return map[string]any{
		"id":          p.GetId(),
		"name":        p.GetName(),
		"description": p.GetDescription(),
		"favorite":    p.GetFavorite(),
		"parent_only": p.GetParentOnly(),
	}
}

// profileDetail is the shape returned by get_profile / create_profile /
// update_profile — every user-editable field flattened to JSON-friendly
// types. Server-managed timestamps + owner_user_id are omitted (the
// caller already knows it's the current user).
func profileDetail(p *reevev1.Profile) map[string]any {
	out := map[string]any{
		"id":          p.GetId(),
		"name":        p.GetName(),
		"description": p.GetDescription(),
		"favorite":    p.GetFavorite(),
		"parent_only": p.GetParentOnly(),
	}
	if p.ParentProfileId != nil {
		out["parent_profile_id"] = p.GetParentProfileId()
	}
	if p.SystemMessage != nil {
		out["system_message"] = p.GetSystemMessage()
	}
	if p.DefaultUserMessage != nil {
		out["default_user_message"] = p.GetDefaultUserMessage()
	}
	if p.CompressionGuide != nil {
		out["compression_guide"] = p.GetCompressionGuide()
	}
	if defaults := p.GetDefaultSettings(); defaults != nil {
		ds := map[string]any{}
		if defaults.DefaultProviderId != nil {
			ds["default_provider_id"] = defaults.GetDefaultProviderId()
		}
		if defaults.DefaultModelId != nil {
			ds["default_model_id"] = defaults.GetDefaultModelId()
		}
		if defaults.IncludeThinkingInHistory != nil {
			ds["include_thinking_in_history"] = defaults.GetIncludeThinkingInHistory()
		}
		if len(ds) > 0 {
			out["default_settings"] = ds
		}
	}
	return out
}

// pluginTypeDetail is the shape returned by list_plugin_types — full
// fidelity so the assistant can construct config blobs that match the
// plugin's expectations on the first try.
func pluginTypeDetail(pt *reevev1.PluginType) map[string]any {
	out := map[string]any{
		"name":         pt.GetName(),
		"display_name": pt.GetDisplayName(),
		"description":  pt.GetDescription(),
	}
	if c := pt.GetCapabilities(); c != nil {
		out["capabilities"] = map[string]any{
			"configurable":                   c.GetConfigurable(),
			"system_prompter":                c.GetSystemPrompter(),
			"outgoing_user_transformer":      c.GetOutgoingUserTransformer(),
			"history_transformer":            c.GetHistoryTransformer(),
			"chunk_transformer":              c.GetChunkTransformer(),
			"display_transformer":            c.GetDisplayTransformer(),
			"tool_provider":                  c.GetToolProvider(),
			"assistant_content_transformer":  c.GetAssistantContentTransformer(),
			"message_lifecycle_hook":         c.GetMessageLifecycleHook(),
			"device_fact_requester":          c.GetDeviceFactRequester(),
			"content_renderer":               c.GetContentRenderer(),
		}
	}
	fields := make([]map[string]any, 0, len(pt.GetConfigFields()))
	for _, cf := range pt.GetConfigFields() {
		f := map[string]any{
			"name":        cf.GetName(),
			"display":     cf.GetDisplay(),
			"description": cf.GetDescription(),
			"type":        cf.GetType().String(),
			"required":    cf.GetRequired(),
			"global":      cf.GetGlobal(),
		}
		if cf.GetDefaultJson() != "" {
			f["default_json"] = cf.GetDefaultJson()
		}
		if opts := cf.GetOptions(); len(opts) > 0 {
			oo := make([]map[string]any, 0, len(opts))
			for _, o := range opts {
				oo = append(oo, map[string]any{"value": o.GetValue(), "label": o.GetLabel()})
			}
			f["options"] = oo
		}
		fields = append(fields, f)
	}
	out["config_fields"] = fields
	return out
}

// profilePluginDetail decodes the bytes config to a JSON object so the
// assistant sees structured config rather than an opaque blob. Falls
// back to a base64-encoded shape only if the bytes aren't valid JSON
// (which would indicate a plugin storing non-JSON config — unusual
// but allowed by the proto).
func profilePluginDetail(p *reevev1.ProfilePlugin) map[string]any {
	out := map[string]any{
		"plugin_name": p.GetPluginName(),
		"ordinal":     p.GetOrdinal(),
	}
	cfgBytes := p.GetConfig()
	if len(cfgBytes) == 0 {
		out["config"] = map[string]any{}
	} else {
		var cfg any
		if err := json.Unmarshal(cfgBytes, &cfg); err != nil {
			// Non-JSON config — surface as a string so the assistant
			// sees that something's there even if it can't parse it.
			out["config_raw"] = string(cfgBytes)
		} else {
			out["config"] = cfg
		}
	}
	return out
}
