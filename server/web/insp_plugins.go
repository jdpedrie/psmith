package web

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// pluginsTabVM is the inspector's Plugins tab: the merged pipeline in run
// order, where each plugin comes from, and what can be added.
type pluginsTabVM struct {
	ConvID  string
	Profile string
	Rows    []plugRowVM
	Addable []plugOptVM
	Dirty   int // unsaved changes the page opens with (fixtures)
}

// plugRowVM is one plugin in the pipeline.
type plugRowVM struct {
	N       int
	Name    string
	Display string
	// Kind is "inherited" (from the profile, on), "off" (inherited, switched
	// off here) or "conversation" (added to this conversation only).
	Kind      string
	Panel     bool // the plugin draws a panel
	Configure bool // conversation-only and has settings
	Dirty     bool
}

type plugOptVM struct {
	Name, Display, Description string
}

// pluginsTab resolves the pipeline for display. Inherited plugins switched
// off here don't appear in the resolved pipeline, so they're merged back in
// from the conversation's override rows at their ordinal.
func (h *Handler) pluginsTab(ctx context.Context, convID, profile string) *pluginsTabVM {
	vm := &pluginsTabVM{ConvID: convID, Profile: profile}
	pipe, err := h.convos.ResolveConversationPipeline(ctx, connect.NewRequest(&psmithv1.ResolveConversationPipelineRequest{ConversationId: convID}))
	if err != nil {
		return vm
	}
	types := h.pluginTypesByName(ctx)
	type ord struct {
		row plugRowVM
		at  int32
	}
	var all []ord
	present := map[string]bool{}
	for _, e := range pipe.Msg.GetEntries() {
		name := e.GetPluginName()
		present[name] = true
		row := plugRowVM{Name: name, Display: name, Kind: "inherited"}
		if e.GetSource() == psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_CONVERSATION {
			row.Kind = "conversation"
		}
		all = append(all, ord{row, e.GetOrdinal()})
	}
	if ov, err := h.convos.GetConversationPlugins(ctx, connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: convID})); err == nil {
		for _, p := range ov.Msg.GetPlugins() {
			if p.GetDisabled() && !present[p.GetPluginName()] {
				present[p.GetPluginName()] = true
				all = append(all, ord{plugRowVM{Name: p.GetPluginName(), Display: p.GetPluginName(), Kind: "off"}, p.GetOrdinal()})
			}
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].at < all[j].at })
	for i, o := range all {
		row := o.row
		row.N = i + 1
		if t := types[row.Name]; t != nil {
			row.Display = orName(t.GetDisplayName(), row.Name)
			row.Panel = t.GetPanel() != nil && row.Kind != "off"
			row.Configure = row.Kind == "conversation" && len(t.GetConfigFields()) > 0
		}
		vm.Rows = append(vm.Rows, row)
	}
	for name, t := range types {
		if !present[name] {
			vm.Addable = append(vm.Addable, plugOptVM{Name: name, Display: orName(t.GetDisplayName(), name), Description: t.GetDescription()})
		}
	}
	sort.Slice(vm.Addable, func(i, j int) bool { return vm.Addable[i].Display < vm.Addable[j].Display })
	return vm
}

// handleConvPluginsSave saves the Plugins tab: each inherited plugin's switch,
// and a remove or add when one of those buttons sent the form.
func (h *Handler) handleConvPluginsSave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	pipe, err := h.convos.ResolveConversationPipeline(r.Context(), connect.NewRequest(&psmithv1.ResolveConversationPipelineRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	cur, err := h.convos.GetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	plugins := applyPluginForm(pipe.Msg.GetEntries(), cur.Msg.GetPlugins(), r.PostForm)
	if _, err := h.convos.SetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.SetConversationPluginsRequest{
		ConversationId: convID, Plugins: plugins,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=plugins", http.StatusSeeOther)
}

// applyPluginForm turns the posted tab into the conversation's override rows.
// Switches are named on_<plugin> with "true"/"false"; remove=<plugin> drops
// an override; add=<plugin> appends a conversation-only plugin.
func applyPluginForm(resolved []*psmithv1.ResolvedPipelineEntry, overrides []*psmithv1.ConversationPlugin, form map[string][]string) []*psmithv1.ConversationPlugin {
	get := func(k string) string {
		if v := form[k]; len(v) > 0 {
			return v[0]
		}
		return ""
	}
	out := append([]*psmithv1.ConversationPlugin(nil), overrides...)
	find := func(name string) int {
		for i, p := range out {
			if p.GetPluginName() == name {
				return i
			}
		}
		return -1
	}
	for _, e := range resolved {
		if e.GetSource() == psmithv1.ResolvedPipelineSource_RESOLVED_PIPELINE_SOURCE_CONVERSATION {
			continue
		}
		if get("on_"+e.GetPluginName()) == "false" {
			// Keep the inherited position so the row stays where it was.
			out = append(out, &psmithv1.ConversationPlugin{PluginName: e.GetPluginName(), Ordinal: e.GetOrdinal(), Disabled: true})
		}
	}
	for _, p := range overrides {
		if p.GetDisabled() && get("on_"+p.GetPluginName()) == "true" {
			out = dropPlugin(out, p.GetPluginName())
		}
	}
	if rm := get("remove"); rm != "" {
		out = dropPlugin(out, rm)
	}
	if add := get("add"); add != "" && find(add) < 0 {
		var ord int32
		for _, e := range resolved {
			if e.GetOrdinal() >= ord {
				ord = e.GetOrdinal() + 1
			}
		}
		for _, p := range out {
			if p.GetOrdinal() >= ord {
				ord = p.GetOrdinal() + 1
			}
		}
		out = append(out, &psmithv1.ConversationPlugin{PluginName: add, Ordinal: ord})
	}
	return out
}

// pluginConfigVM is the inspector view that configures a conversation-only
// plugin.
type pluginConfigVM struct {
	ConvID  string
	Name    string
	Display string
	Form    pluginConfigForm
}

// handlePluginConfig shows a conversation-only plugin's settings in the
// inspector.
func (h *Handler) handlePluginConfig(w http.ResponseWriter, r *http.Request) {
	convID, name := r.PathValue("id"), r.PathValue("name")
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	cur, err := h.convos.GetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	t := h.pluginTypesByName(r.Context())[name]
	if t == nil || currentConfigIndex(cur.Msg.GetPlugins(), name) < 0 {
		http.Error(w, "plugin not found", http.StatusNotFound)
		return
	}
	cfg := &pluginConfigVM{ConvID: convID, Name: name, Display: orName(t.GetDisplayName(), name)}
	cfg.Form = h.buildPluginForm(r.Context(), t, currentConfigFor(cur.Msg.GetPlugins(), name), h.listModels(r.Context(), ""))
	vm.Inspector.Tab, vm.Inspector.View, vm.Inspector.Config, vm.ShowInsp, vm.Inspector.Page = "plugins", "config", cfg, true, true
	h.renderConversation(w, r, vm)
}

func currentConfigIndex(plugins []*psmithv1.ConversationPlugin, name string) int {
	for i, p := range plugins {
		if p.GetPluginName() == name {
			return i
		}
	}
	return -1
}

// handlePluginConfigSave writes a conversation-only plugin's settings.
func (h *Handler) handlePluginConfigSave(w http.ResponseWriter, r *http.Request) {
	convID, name := r.PathValue("id"), r.PathValue("name")
	_ = r.ParseForm()
	cur, err := h.convos.GetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.GetConversationPluginsRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	plugins := cur.Msg.GetPlugins()
	i := currentConfigIndex(plugins, name)
	if i < 0 {
		http.Error(w, "plugin not found", http.StatusNotFound)
		return
	}
	t := h.pluginTypesByName(r.Context())[name]
	var cfg []byte
	if pluginHasForm(t) {
		cfg, _ = assemblePluginConfig(t, plugins[i].GetConfig(), func(field string) string { return r.PostFormValue("cfg_" + field) })
	} else if raw := strings.TrimSpace(r.PostFormValue("config")); raw != "" {
		if !json.Valid([]byte(raw)) {
			http.Error(w, "config is not valid JSON", http.StatusBadRequest)
			return
		}
		cfg = []byte(raw)
	}
	plugins[i].Config = cfg
	if _, err := h.convos.SetConversationPlugins(r.Context(), connect.NewRequest(&psmithv1.SetConversationPluginsRequest{ConversationId: convID, Plugins: plugins})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=plugins", http.StatusSeeOther)
}
