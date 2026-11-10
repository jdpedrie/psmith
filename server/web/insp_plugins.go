package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
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
	// Overrides counts the conversation's own plugin rows: switches turned
	// off here and plugins added here. Clear conversation changes drops them.
	Overrides int
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
		vm.Overrides = len(ov.Msg.GetPlugins())
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
// and a remove or add when one of those buttons sent the form. Clear drops
// every override, so the conversation runs exactly the profile's pipeline.
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
	if r.PostFormValue("clear") != "" {
		plugins = nil
	}
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
	// Items is the form, field by field, when the inspector can draw it.
	Items []cfgItemVM
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
	q := r.URL.Query()
	h.renderPluginConfig(w, r, vm, t, currentConfigFor(cur.Msg.GetPlugins(), name), q.Get("open"), q.Get("add"), nil)
}

// renderPluginConfig draws the config view. paste, when set, is a Paste
// JSON that didn't parse: its list keeps the text and says why.
func (h *Handler) renderPluginConfig(w http.ResponseWriter, r *http.Request, vm convVM, t *psmithv1.PluginType, current []byte, open, add string, paste *listFieldVM) {
	name := t.GetName()
	cfg := &pluginConfigVM{ConvID: vm.ID, Name: name, Display: orName(t.GetDisplayName(), name)}
	models := h.listModels(r.Context(), "")
	cfg.Form = h.buildPluginForm(r.Context(), t, current, models)
	if inspFlatForm(t) {
		cfg.Items = h.inspConfigItems(r.Context(), t, current, models, open, add)
	} else {
		cfg.Form.Fields, cfg.Form.HasForm = nil, false
	}
	for _, it := range cfg.Items {
		if it.List != nil && paste != nil && it.List.Name == paste.Name {
			it.List.Paste, it.List.PasteError = paste.Paste, paste.PasteError
		}
	}
	vm.Inspector.Tab, vm.Inspector.View, vm.Inspector.Config, vm.ShowInsp, vm.Inspector.Page = "plugins", "config", cfg, true, true
	status := http.StatusOK
	if paste != nil {
		status = http.StatusUnprocessableEntity
	}
	h.renderConversationStatus(w, r, vm, status)
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
	back := "/c/" + convID + "?tab=plugins"
	var cfg []byte
	if inspFlatForm(t) {
		cur := plugins[i].GetConfig()
		cfg, _ = assemblePluginConfig(t, cur, func(field string) string { return r.PostFormValue("cfg_" + field) })
		del := r.PostFormValue("del")
		cfg, err = applyListFields(t, cfg, cur, r.PostForm, del)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		here := "/c/" + convID + "/plugin/" + name
		switch {
		case r.PostFormValue("paste") != "":
			field := r.PostFormValue("paste")
			text := r.PostFormValue("paste_" + field)
			pasted, perr := pasteListRows(t, cfg, field, text)
			if perr != nil {
				vm, lerr := h.loadConversation(r.Context(), r, convID)
				if lerr != nil {
					http.Error(w, "not found", http.StatusNotFound)
					return
				}
				h.renderPluginConfig(w, r, vm, t, cfg, "", "", &listFieldVM{Name: field, Paste: text, PasteError: perr.Error()})
				return
			}
			cfg, back = pasted, here
		case r.PostFormValue("add_row") != "":
			back = here + "?add=" + url.QueryEscape(r.PostFormValue("add_row"))
		case del != "":
			back = here
		}
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
	http.Redirect(w, r, back, http.StatusSeeOther)
}

// inspFlatForm reports whether the inspector's form can edit a plugin's
// settings. Lists get the row editor; a generated id or a profile choice at
// the top level has no field, and drawn as one it would save a string over
// the value, so those plugins get the JSON editor instead.
func inspFlatForm(t *psmithv1.PluginType) bool {
	if !pluginHasForm(t) {
		return false
	}
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() {
			continue
		}
		switch f.GetType() {
		case psmithv1.ConfigField_AUTO_ID, psmithv1.ConfigField_PROFILE_PICKER:
			return false
		}
	}
	return true
}
