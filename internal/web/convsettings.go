package web

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
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

// triFieldVM is a tri-state (Inherit / On / Off) call-settings field.
type triFieldVM struct {
	Name      string
	State     string // "", "on", "off"
	Inherited string // "on"/"off"/"" — shown in the Inherit option label
}

type convSettingsVM struct {
	ConvID     string
	Title      string
	Tab        string // "call" | "plugins"
	DriverType string // active provider type, gates the provider-extras section

	// Call settings
	Temperature     callFieldVM
	TopP            callFieldVM
	MaxOutputTokens callFieldVM
	TopK            callFieldVM
	StopSequences   callFieldVM // comma-joined
	ThinkingEnabled triFieldVM
	ThinkingBudget  callFieldVM
	ExplicitCache   triFieldVM
	IncludeThinking triFieldVM

	// Provider extras (active provider only)
	AnthCacheEnabled triFieldVM
	OAISeed          callFieldVM
	OAIFreqPenalty   callFieldVM
	OAIPresPenalty   callFieldVM
	OAIParallelTools triFieldVM
	GoogCandidates   callFieldVM

	// Plugins
	Plugins []convPluginRowVM
	Addable []pluginOptVM
}

type convPluginRowVM struct {
	Name     string
	Display  string
	Ordinal  int32
	Source   string // "Inherited" | "Override"
	Disabled bool
	Form     pluginConfigForm
}

// handleConvSettings renders the conversation settings page (call settings or
// plugins tab).
func (h *Handler) handleConvSettings(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	conv := getResp.Msg.GetConversation()

	tab := r.URL.Query().Get("tab")
	if tab != "plugins" {
		tab = "call"
	}
	vm := convSettingsVM{ConvID: convID, Title: convoTitle(conv), Tab: tab}

	own := conv.GetSettings().GetCallSettings()
	inherited := h.inheritedCallSettings(r.Context(), conv)
	vm.DriverType = h.activeDriverType(r.Context(), conv)
	fillCallFields(&vm, own, inherited, conv.GetSettings(), h.inheritedConvSettings(r.Context(), conv))

	if tab == "plugins" {
		vm.Plugins, vm.Addable = h.convPlugins(r.Context(), convID)
	}
	h.render(w, r, http.StatusOK, convSettingsPage(vm))
}

func fillCallFields(vm *convSettingsVM, own, inh *spaltv1.CallSettings, ownConv, inhConv *spaltv1.ConversationSettings) {
	vm.Temperature = floatField("temperature", own.GetTemperature(), own != nil && own.Temperature != nil, inh.GetTemperature(), inh != nil && inh.Temperature != nil)
	vm.TopP = floatField("top_p", own.GetTopP(), own != nil && own.TopP != nil, inh.GetTopP(), inh != nil && inh.TopP != nil)
	vm.MaxOutputTokens = intField("max_output_tokens", own.GetMaxOutputTokens(), own != nil && own.MaxOutputTokens != nil, inh.GetMaxOutputTokens(), inh != nil && inh.MaxOutputTokens != nil)
	vm.TopK = intField("top_k", own.GetTopK(), own != nil && own.TopK != nil, inh.GetTopK(), inh != nil && inh.TopK != nil)
	vm.StopSequences = callFieldVM{Name: "stop_sequences", Value: strings.Join(own.GetStopSequences(), ", "), Inherited: strings.Join(inh.GetStopSequences(), ", ")}

	ownT, inhT := own.GetThinking(), inh.GetThinking()
	vm.ThinkingEnabled = makeTri("thinking_enabled", thinkEnabled(ownT), thinkEnabled(inhT))
	vm.ThinkingBudget = intField("thinking_budget", ownT.GetBudgetTokens(), ownT != nil && ownT.BudgetTokens != nil, inhT.GetBudgetTokens(), inhT != nil && inhT.BudgetTokens != nil)
	vm.ExplicitCache = makeTri("explicit_cache", explicitCache(own), explicitCache(inh))
	vm.IncludeThinking = makeTri("include_thinking_in_history", includeThinking(ownConv), includeThinking(inhConv))

	ownA, inhA := own.GetAnthropic(), inh.GetAnthropic()
	vm.AnthCacheEnabled = makeTri("anth_cache_enabled", anthCache(ownA), anthCache(inhA))
	ownO, inhO := own.GetOpenai(), inh.GetOpenai()
	vm.OAISeed = intField("oai_seed", ownO.GetSeed(), ownO != nil && ownO.Seed != nil, inhO.GetSeed(), inhO != nil && inhO.Seed != nil)
	vm.OAIFreqPenalty = floatField("oai_frequency_penalty", ownO.GetFrequencyPenalty(), ownO != nil && ownO.FrequencyPenalty != nil, inhO.GetFrequencyPenalty(), inhO != nil && inhO.FrequencyPenalty != nil)
	vm.OAIPresPenalty = floatField("oai_presence_penalty", ownO.GetPresencePenalty(), ownO != nil && ownO.PresencePenalty != nil, inhO.GetPresencePenalty(), inhO != nil && inhO.PresencePenalty != nil)
	vm.OAIParallelTools = makeTri("oai_parallel_tool_calls", oaiParallel(ownO), oaiParallel(inhO))
	ownG, inhG := own.GetGoogle(), inh.GetGoogle()
	vm.GoogCandidates = intField("goog_candidate_count", ownG.GetCandidateCount(), ownG != nil && ownG.CandidateCount != nil, inhG.GetCandidateCount(), inhG != nil && inhG.CandidateCount != nil)
}

// nil-safe pointer accessors for nested optional bools (proto getters return
// the message pointer, which can be nil; reaching the field would panic).
func thinkEnabled(t *spaltv1.ThinkingSettings) *bool {
	if t == nil {
		return nil
	}
	return t.Enabled
}
func explicitCache(cs *spaltv1.CallSettings) *bool {
	if cs == nil {
		return nil
	}
	return cs.ExplicitCache
}
func includeThinking(s *spaltv1.ConversationSettings) *bool {
	if s == nil {
		return nil
	}
	return s.IncludeThinkingInHistory
}
func anthCache(a *spaltv1.AnthropicExtras) *bool {
	if a == nil {
		return nil
	}
	return a.CacheEnabled
}
func oaiParallel(o *spaltv1.OpenAIExtras) *bool {
	if o == nil {
		return nil
	}
	return o.ParallelToolCalls
}

func floatField(name string, v float64, set bool, inh float64, inhSet bool) callFieldVM {
	f := callFieldVM{Name: name}
	if set {
		f.Value = strconv.FormatFloat(v, 'f', -1, 64)
	}
	if inhSet {
		f.Inherited = strconv.FormatFloat(inh, 'f', -1, 64)
	}
	return f
}

func intField(name string, v int32, set bool, inh int32, inhSet bool) callFieldVM {
	f := callFieldVM{Name: name}
	if set {
		f.Value = strconv.Itoa(int(v))
	}
	if inhSet {
		f.Inherited = strconv.Itoa(int(inh))
	}
	return f
}

func makeTri(name string, own, inh *bool) triFieldVM {
	f := triFieldVM{Name: name}
	if own != nil {
		f.State = boolWord(*own)
	}
	if inh != nil {
		f.Inherited = boolWord(*inh)
	}
	return f
}

func boolWord(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

// inheritedCallSettings resolves the call settings below the conversation:
// provider defaults < model defaults < resolved profile defaults. Higher layers
// win per scalar field; this is what an unset conversation field falls back to.
func (h *Handler) inheritedCallSettings(ctx context.Context, conv *spaltv1.Conversation) *spaltv1.CallSettings {
	out := &spaltv1.CallSettings{}
	providerID, modelID := resolvedModel(conv)

	if providerID != "" && h.models != nil {
		if resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&spaltv1.ListAllUserModelsRequest{})); err == nil {
			for _, e := range resp.Msg.GetEntries() {
				if e.GetProvider().GetId() != providerID {
					continue
				}
				out = mergeCall(out, e.GetProvider().GetDefaultSettings()) // provider layer
				if e.GetModel().GetModelId() == modelID {
					out = mergeCall(out, e.GetModel().GetDefaultSettings()) // model layer
				}
			}
		}
	}
	if h.profiles != nil {
		if prof, err := h.profiles.GetProfile(ctx, connect.NewRequest(&spaltv1.GetProfileRequest{Id: conv.GetProfileId(), Resolve: true})); err == nil {
			out = mergeCall(out, prof.Msg.GetProfile().GetDefaultSettings().GetCallSettings()) // profile layer (top of inherited)
		}
	}
	return out
}

func (h *Handler) inheritedConvSettings(ctx context.Context, conv *spaltv1.Conversation) *spaltv1.ConversationSettings {
	out := &spaltv1.ConversationSettings{}
	if h.profiles != nil {
		if prof, err := h.profiles.GetProfile(ctx, connect.NewRequest(&spaltv1.GetProfileRequest{Id: conv.GetProfileId(), Resolve: true})); err == nil {
			if d := prof.Msg.GetProfile().GetDefaultSettings(); d != nil {
				out.IncludeThinkingInHistory = d.IncludeThinkingInHistory
			}
		}
	}
	return out
}

// resolvedModel returns the conversation's effective provider/model: its own
// override if set, else the profile default (caller resolves further if blank).
func resolvedModel(conv *spaltv1.Conversation) (providerID, modelID string) {
	if s := conv.GetSettings(); s != nil {
		return s.GetDefaultProviderId(), s.GetDefaultModelId()
	}
	return "", ""
}

func (h *Handler) activeDriverType(ctx context.Context, conv *spaltv1.Conversation) string {
	pid, _ := resolvedModel(conv)
	if pid == "" || h.models == nil {
		return ""
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&spaltv1.ListAllUserModelsRequest{}))
	if err != nil {
		return ""
	}
	for _, e := range resp.Msg.GetEntries() {
		if e.GetProvider().GetId() == pid {
			return e.GetProvider().GetType()
		}
	}
	return ""
}

// mergeCall overlays higher onto lower for the scalar fields the web form
// exposes (higher wins when set). nil inputs are treated as empty.
func mergeCall(higher, lower *spaltv1.CallSettings) *spaltv1.CallSettings {
	if higher == nil {
		higher = &spaltv1.CallSettings{}
	}
	if lower == nil {
		return higher
	}
	out := &spaltv1.CallSettings{
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

func mergeThinking(h, l *spaltv1.ThinkingSettings) *spaltv1.ThinkingSettings {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &spaltv1.ThinkingSettings{}
	}
	if l == nil {
		l = &spaltv1.ThinkingSettings{}
	}
	return &spaltv1.ThinkingSettings{Enabled: pickB(h.Enabled, l.Enabled), BudgetTokens: pickI(h.BudgetTokens, l.BudgetTokens)}
}

func mergeAnth(h, l *spaltv1.AnthropicExtras) *spaltv1.AnthropicExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &spaltv1.AnthropicExtras{}
	}
	if l == nil {
		l = &spaltv1.AnthropicExtras{}
	}
	out := &spaltv1.AnthropicExtras{CacheEnabled: pickB(h.CacheEnabled, l.CacheEnabled)}
	if h.CacheTtl != nil {
		out.CacheTtl = h.CacheTtl
	} else {
		out.CacheTtl = l.CacheTtl
	}
	return out
}

func mergeOAI(h, l *spaltv1.OpenAIExtras) *spaltv1.OpenAIExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &spaltv1.OpenAIExtras{}
	}
	if l == nil {
		l = &spaltv1.OpenAIExtras{}
	}
	return &spaltv1.OpenAIExtras{
		Seed:              pickI(h.Seed, l.Seed),
		FrequencyPenalty:  pickF(h.FrequencyPenalty, l.FrequencyPenalty),
		PresencePenalty:   pickF(h.PresencePenalty, l.PresencePenalty),
		ParallelToolCalls: pickB(h.ParallelToolCalls, l.ParallelToolCalls),
	}
}

func mergeGoog(h, l *spaltv1.GoogleExtras) *spaltv1.GoogleExtras {
	if h == nil && l == nil {
		return nil
	}
	if h == nil {
		h = &spaltv1.GoogleExtras{}
	}
	if l == nil {
		l = &spaltv1.GoogleExtras{}
	}
	return &spaltv1.GoogleExtras{CandidateCount: pickI(h.CandidateCount, l.CandidateCount)}
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

	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &spaltv1.ConversationSettings{}
	}

	cs := &spaltv1.CallSettings{
		Temperature:     formFloat(r, "temperature"),
		TopP:            formFloat(r, "top_p"),
		MaxOutputTokens: formInt(r, "max_output_tokens"),
		TopK:            formInt(r, "top_k"),
		StopSequences:   splitStops(r.FormValue("stop_sequences")),
		ExplicitCache:   formTri(r, "explicit_cache"),
	}
	if en, bud := formTri(r, "thinking_enabled"), formInt(r, "thinking_budget"); en != nil || bud != nil {
		cs.Thinking = &spaltv1.ThinkingSettings{Enabled: en, BudgetTokens: bud}
	}
	if ce := formTri(r, "anth_cache_enabled"); ce != nil {
		cs.Anthropic = &spaltv1.AnthropicExtras{CacheEnabled: ce}
	}
	if seed, fp, pp, par := formInt(r, "oai_seed"), formFloat(r, "oai_frequency_penalty"), formFloat(r, "oai_presence_penalty"), formTri(r, "oai_parallel_tool_calls"); seed != nil || fp != nil || pp != nil || par != nil {
		cs.Openai = &spaltv1.OpenAIExtras{Seed: seed, FrequencyPenalty: fp, PresencePenalty: pp, ParallelToolCalls: par}
	}
	if cc := formInt(r, "goog_candidate_count"); cc != nil {
		cs.Google = &spaltv1.GoogleExtras{CandidateCount: cc}
	}
	settings.CallSettings = cs
	settings.IncludeThinkingInHistory = formTri(r, "include_thinking_in_history")

	if _, err := h.convos.UpdateConversation(r.Context(), connect.NewRequest(&spaltv1.UpdateConversationRequest{Id: convID, Settings: settings})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"/settings", http.StatusSeeOther)
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

// convPlugins resolves the merged pipeline for display (with inherited/override
// source badges) and lists catalog plugins not yet present for adding.
func (h *Handler) convPlugins(ctx context.Context, convID string) (rows []convPluginRowVM, addable []pluginOptVM) {
	pipe, err := h.convos.ResolveConversationPipeline(ctx, connect.NewRequest(&spaltv1.ResolveConversationPipelineRequest{ConversationId: convID}))
	if err != nil {
		return nil, nil
	}
	types := h.pluginTypesByName(ctx)
	models := h.listModels(ctx, "")
	display := func(name string) string {
		if t := types[name]; t != nil {
			return orName(t.GetDisplayName(), name)
		}
		return name
	}
	present := map[string]bool{}
	for _, e := range pipe.Msg.GetEntries() {
		present[e.GetPluginName()] = true
		src := "Inherited"
		if e.GetSource() == spaltv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_CONVERSATION {
			src = "Override"
		}
		rows = append(rows, convPluginRowVM{
			Name:    e.GetPluginName(),
			Display: display(e.GetPluginName()),
			Ordinal: e.GetOrdinal(),
			Source:  src,
			Form:    h.buildPluginForm(ctx, types[e.GetPluginName()], e.GetConfig(), models),
		})
	}
	// Conversation overrides that disable an inherited plugin don't appear in the
	// resolved pipeline; surface them so they can be restored.
	if ov, err := h.convos.GetConversationPlugins(ctx, connect.NewRequest(&spaltv1.GetConversationPluginsRequest{ConversationId: convID})); err == nil {
		for _, p := range ov.Msg.GetPlugins() {
			if p.GetDisabled() {
				rows = append(rows, convPluginRowVM{
					Name:     p.GetPluginName(),
					Display:  display(p.GetPluginName()),
					Source:   "Override",
					Disabled: true,
				})
			}
		}
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Ordinal < rows[j].Ordinal })

	for name, t := range types {
		if !present[name] {
			addable = append(addable, pluginOptVM{Name: name, DisplayName: orName(t.GetDisplayName(), name), Description: t.GetDescription()})
		}
	}
	sort.Slice(addable, func(i, j int) bool { return addable[i].DisplayName < addable[j].DisplayName })
	return rows, addable
}

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

	cur, err := h.convos.GetConversationPlugins(r.Context(), connect.NewRequest(&spaltv1.GetConversationPluginsRequest{ConversationId: convID}))
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

	if _, err := h.convos.SetConversationPlugins(r.Context(), connect.NewRequest(&spaltv1.SetConversationPluginsRequest{
		ConversationId: convID, Plugins: plugins,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"/settings?tab=plugins", http.StatusSeeOther)
}

// currentConfigFor returns the existing override config for a plugin, or nil.
func currentConfigFor(plugins []*spaltv1.ConversationPlugin, name string) []byte {
	for _, p := range plugins {
		if p.GetPluginName() == name {
			return p.GetConfig()
		}
	}
	return nil
}

func dropPlugin(plugins []*spaltv1.ConversationPlugin, name string) []*spaltv1.ConversationPlugin {
	out := plugins[:0]
	for _, p := range plugins {
		if p.GetPluginName() != name {
			out = append(out, p)
		}
	}
	return out
}

func upsertPlugin(plugins []*spaltv1.ConversationPlugin, name string, config []byte, disabled bool) []*spaltv1.ConversationPlugin {
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
	return append(plugins, &spaltv1.ConversationPlugin{PluginName: name, Ordinal: ord, Config: config, Disabled: disabled})
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

// orPlaceholder is the number-field placeholder: the inherited value, or a
// neutral dash when nothing is inherited.
func orPlaceholder(inherited string) string {
	if inherited != "" {
		return inherited
	}
	return "—"
}

// sliderStart picks the range input's initial position: the override if set,
// else the inherited value, else the midpoint of [min, max].
func sliderStart(f callFieldVM, min, max string) string {
	if f.Value != "" {
		return f.Value
	}
	if f.Inherited != "" {
		return f.Inherited
	}
	lo, err1 := strconv.ParseFloat(min, 64)
	hi, err2 := strconv.ParseFloat(max, 64)
	if err1 != nil || err2 != nil {
		return min
	}
	return strconv.FormatFloat((lo+hi)/2, 'f', -1, 64)
}

// triInheritLabel annotates the Inherit option with the resolved value.
func triInheritLabel(inherited string) string {
	switch inherited {
	case "on":
		return " (on)"
	case "off":
		return " (off)"
	default:
		return ""
	}
}
