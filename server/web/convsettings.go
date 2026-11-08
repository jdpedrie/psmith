package web

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/protoconv"
	"github.com/jdpedrie/psmith/server/providers"
)

// --- conversation settings (call settings + plugin overrides) ---

// callFieldVM is one numeric/text call-settings field: the conversation's own
// override value (empty when inheriting) plus the resolved value shown as the
// placeholder, so an empty box reads as "inherit (resolved)".
type callFieldVM struct {
	Name      string
	Value     string // conversation override, "" = inherit
	Inherited string // resolved value below the conversation (placeholder)
}

// enumFieldVM is a fixed-choice call-settings field with an Inherit option.
type enumFieldVM struct {
	Name      string
	Value     string // conversation override, "" = inherit
	Inherited string // resolved label below the conversation, shown in the Inherit option
	Options   []enumOption
}

type enumOption struct {
	Value string
	Label string
}

// triFieldVM is a tri-state (Inherit / On / Off) call-settings field.
type triFieldVM struct {
	Name      string
	State     string // "", "on", "off"
	Inherited string // "on"/"off"/"" — shown in the Inherit option label
}

type convPluginRowVM struct {
	Name     string
	Display  string
	Ordinal  int32
	Source   string // "Inherited" | "Override"
	Disabled bool
	Form     pluginConfigForm
}

// handleConvSettings is the old settings page's URL; settings live in the
// inspector's Settings and Plugins tabs now.
func (h *Handler) handleConvSettings(w http.ResponseWriter, r *http.Request) {
	tab := "settings"
	if r.URL.Query().Get("tab") == "plugins" {
		tab = "plugins"
	}
	http.Redirect(w, r, "/c/"+r.PathValue("id")+"?tab="+tab, http.StatusSeeOther)
}

// thinkingEffortOptions are the levels in ascending order, labelled for the
// select. Values are the driver-side spelling so the form round-trips
// through protoconv without a second table.
var thinkingEffortOptions = []enumOption{
	{Value: string(providers.ThinkingEffortOff), Label: "Off"},
	{Value: string(providers.ThinkingEffortLow), Label: "Low"},
	{Value: string(providers.ThinkingEffortMedium), Label: "Medium"},
	{Value: string(providers.ThinkingEffortHigh), Label: "High"},
	{Value: string(providers.ThinkingEffortXHigh), Label: "Extra high"},
}

func boolWord(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

// mergeCall overlays higher onto lower for the scalar fields the web form
// exposes (higher wins when set). nil inputs are treated as empty.
func mergeCall(higher, lower *psmithv1.CallSettings) *psmithv1.CallSettings {
	if higher == nil {
		higher = &psmithv1.CallSettings{}
	}
	if lower == nil {
		return higher
	}
	out := &psmithv1.CallSettings{
		Temperature:     pickF(higher.Temperature, lower.Temperature),
		TopP:            pickF(higher.TopP, lower.TopP),
		MaxOutputTokens: pickI(higher.MaxOutputTokens, lower.MaxOutputTokens),
		TopK:            pickI(higher.TopK, lower.TopK),
		StopSequences:   higher.StopSequences,
		ExplicitCache:   pickB(higher.ExplicitCache, lower.ExplicitCache),
	}
	if len(out.StopSequences) == 0 {
		out.StopSequences = lower.StopSequences
	}
	out.Thinking = mergeThinking(higher.Thinking, lower.Thinking)
	out.Anthropic = mergeAnth(higher.Anthropic, lower.Anthropic)
	out.Openai = mergeOAI(higher.Openai, lower.Openai)
	out.Google = mergeGoog(higher.Google, lower.Google)
	return out
}

func mergeThinking(h, l *psmithv1.ThinkingSettings) *psmithv1.ThinkingSettings {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &psmithv1.ThinkingSettings{}
	}
	if l == nil {
		l = &psmithv1.ThinkingSettings{}
	}
	out := &psmithv1.ThinkingSettings{Effort: l.Effort}
	if h.Effort != psmithv1.ThinkingEffort_THINKING_EFFORT_UNSPECIFIED {
		out.Effort = h.Effort
	}
	return out
}

func mergeAnth(h, l *psmithv1.AnthropicExtras) *psmithv1.AnthropicExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &psmithv1.AnthropicExtras{}
	}
	if l == nil {
		l = &psmithv1.AnthropicExtras{}
	}
	out := &psmithv1.AnthropicExtras{CacheEnabled: pickB(h.CacheEnabled, l.CacheEnabled)}
	if h.CacheTtl != nil {
		out.CacheTtl = h.CacheTtl
	} else {
		out.CacheTtl = l.CacheTtl
	}
	return out
}

func mergeOAI(h, l *psmithv1.OpenAIExtras) *psmithv1.OpenAIExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &psmithv1.OpenAIExtras{}
	}
	if l == nil {
		l = &psmithv1.OpenAIExtras{}
	}
	return &psmithv1.OpenAIExtras{
		Seed:              pickI(h.Seed, l.Seed),
		FrequencyPenalty:  pickF(h.FrequencyPenalty, l.FrequencyPenalty),
		PresencePenalty:   pickF(h.PresencePenalty, l.PresencePenalty),
		ParallelToolCalls: pickB(h.ParallelToolCalls, l.ParallelToolCalls),
	}
}

func mergeGoog(h, l *psmithv1.GoogleExtras) *psmithv1.GoogleExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &psmithv1.GoogleExtras{}
	}
	if l == nil {
		l = &psmithv1.GoogleExtras{}
	}
	return &psmithv1.GoogleExtras{CandidateCount: pickI(h.CandidateCount, l.CandidateCount)}
}

func pickF(h, l *float64) *float64 {
	if h != nil {
		return h
	}
	return l
}
func pickI(h, l *int32) *int32 {
	if h != nil {
		return h
	}
	return l
}
func pickB(h, l *bool) *bool {
	if h != nil {
		return h
	}
	return l
}

// handleConvSettingsSave writes the conversation's call-settings overrides
// (blank fields clear to inherit), preserving the default model.
func (h *Handler) handleConvSettingsSave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()

	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &psmithv1.ConversationSettings{}
	}

	cs := &psmithv1.CallSettings{
		Temperature:     formFloat(r, "temperature"),
		TopP:            formFloat(r, "top_p"),
		MaxOutputTokens: formInt(r, "max_output_tokens"),
		TopK:            formInt(r, "top_k"),
		StopSequences:   splitStops(r.FormValue("stop_sequences")),
		ExplicitCache:   formTri(r, "explicit_cache"),
	}
	if e := protoconv.ThinkingEffortProto(providers.ThinkingEffort(r.FormValue("thinking_effort"))); e != psmithv1.ThinkingEffort_THINKING_EFFORT_UNSPECIFIED {
		cs.Thinking = &psmithv1.ThinkingSettings{Effort: e}
	}
	ce, ttl := formTri(r, "anth_cache_enabled"), formCacheTTL(r, "anth_cache_ttl")
	if ce != nil || ttl != nil {
		cs.Anthropic = &psmithv1.AnthropicExtras{CacheEnabled: ce, CacheTtl: ttl}
	}
	if seed, fp, pp, par := formInt(r, "oai_seed"), formFloat(r, "oai_frequency_penalty"), formFloat(r, "oai_presence_penalty"), formTri(r, "oai_parallel_tool_calls"); seed != nil || fp != nil || pp != nil || par != nil {
		cs.Openai = &psmithv1.OpenAIExtras{Seed: seed, FrequencyPenalty: fp, PresencePenalty: pp, ParallelToolCalls: par}
	}
	if cc := formInt(r, "goog_candidate_count"); cc != nil {
		cs.Google = &psmithv1.GoogleExtras{CandidateCount: cc}
	}
	settings.CallSettings = cs
	settings.IncludeThinkingInHistory = formTri(r, "include_thinking_in_history")

	if _, err := h.convos.UpdateConversation(r.Context(), connect.NewRequest(&psmithv1.UpdateConversationRequest{Id: convID, Settings: settings})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=settings", http.StatusSeeOther)
}

func formCacheTTL(r *http.Request, name string) *psmithv1.CacheTTL {
	var v psmithv1.CacheTTL
	switch r.FormValue(name) {
	case "5m":
		v = psmithv1.CacheTTL_CACHE_TTL_5M
	case "1h":
		v = psmithv1.CacheTTL_CACHE_TTL_1H
	default:
		return nil
	}
	return &v
}

func formFloat(r *http.Request, name string) *float64 {
	s := strings.TrimSpace(r.FormValue(name))
	if s == "" {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	return &v
}

func formInt(r *http.Request, name string) *int32 {
	s := strings.TrimSpace(r.FormValue(name))
	if s == "" {
		return nil
	}
	v, err := strconv.ParseInt(s, 10, 32)
	if err != nil {
		return nil
	}
	v32 := int32(v)
	return &v32
}

func formTri(r *http.Request, name string) *bool {
	switch r.FormValue(name) {
	case "on":
		t := true
		return &t
	case "off":
		f := false
		return &f
	default:
		return nil
	}
}

func splitStops(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// --- conversation plugin overrides ---

// handleConvPluginOverride upserts a conversation plugin override (config edit,
// add, disable inherited) or removes one (restore / remove override), then
// returns to the plugins tab. The action is carried in the form.
func (h *Handler) handleConvPluginOverride(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	action := r.FormValue("action")
	name := r.FormValue("plugin_name")
	if name == "" {
		http.Error(w, "plugin_name required", http.StatusBadRequest)
		return
	}

	cur, err := h.convos.GetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	plugins := cur.Msg.GetPlugins()

	switch action {
	case "remove", "restore":
		plugins = dropPlugin(plugins, name)
	case "disable":
		plugins = upsertPlugin(plugins, name, nil, true)
	case "config", "add":
		t := h.pluginTypesByName(r.Context())[name]
		var cfg []byte
		if pluginHasForm(t) {
			// Build the config JSON from the declared fields (cfg_<field>),
			// starting from the override's current config so unknown keys survive.
			cfg, _ = assemblePluginConfig(t, currentConfigFor(plugins, name), func(field string) string {
				return r.FormValue("cfg_" + field)
			})
		} else if raw := strings.TrimSpace(r.FormValue("config")); raw != "" {
			if !json.Valid([]byte(raw)) {
				http.Error(w, "config is not valid JSON", http.StatusBadRequest)
				return
			}
			cfg = []byte(raw)
		}
		plugins = upsertPlugin(plugins, name, cfg, false)
	default:
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}

	if _, err := h.convos.SetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.SetConversationPluginsRequest{
		ConversationId: convID, Plugins: plugins,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=plugins", http.StatusSeeOther)
}

// currentConfigFor returns the existing override config for a plugin, or nil.
func currentConfigFor(plugins []*psmithv1.ConversationPlugin, name string) []byte {
	for _, p := range plugins {
		if p.GetPluginName() == name {
			return p.GetConfig()
		}
	}
	return nil
}

func dropPlugin(plugins []*psmithv1.ConversationPlugin, name string) []*psmithv1.ConversationPlugin {
	out := plugins[:0]
	for _, p := range plugins {
		if p.GetPluginName() != name {
			out = append(out, p)
		}
	}
	return out
}

func upsertPlugin(plugins []*psmithv1.ConversationPlugin, name string, config []byte, disabled bool) []*psmithv1.ConversationPlugin {
	for _, p := range plugins {
		if p.GetPluginName() == name {
			p.Config = config
			p.Disabled = disabled
			return plugins
		}
	}
	var ord int32
	for _, p := range plugins {
		if p.GetOrdinal() >= ord {
			ord = p.GetOrdinal() + 1
		}
	}
	return append(plugins, &psmithv1.ConversationPlugin{PluginName: name, Ordinal: ord, Config: config, Disabled: disabled})
}

func prettyJSON(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	var out bytes.Buffer
	if err := json.Indent(&out, b, "", "  "); err != nil {
		return string(b)
	}
	return out.String()
}

func orName(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
