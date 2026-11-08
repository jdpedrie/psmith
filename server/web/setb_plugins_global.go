package web

import (
	"encoding/json"
	"net/http"
	"sort"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The global Plugins page: every compiled-in plugin with what its shared
// (Global) settings still need, the registered MCP servers as the plugins
// they become, and one page per plugin for its shared settings.

type globalPluginRowVM struct {
	Name    string
	Display string
	Tags    []string
	Status  string
	Kind    string // none | warn | set | embedder
}

type mcpPluginRowVM struct {
	ID     string
	Name   string
	Tags   []string
	Status string
	OK     bool
}

type pluginsPageVM struct {
	Builtin []globalPluginRowVM
	MCP     []mcpPluginRowVM
}

// usesEmbedder names the plugins whose only shared dependency is the
// embedder, which the plugin descriptor has no way to declare.
var usesEmbedder = map[string]bool{"memory": true}

func hasGlobalFields(t *psmithv1.PluginType) bool {
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() {
			return true
		}
	}
	return false
}

func (h *Handler) handleGlobalPlugins(w http.ResponseWriter, r *http.Request) {
	resp, err := h.profiles.ListPluginTypes(r.Context(), connect.NewRequest(&psmithv1.ListPluginTypesRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	global := h.userPluginSettings(r.Context())
	var vm pluginsPageVM
	var mcpTags []string
	for _, t := range resp.Msg.GetPluginTypes() {
		if isMCPPlugin(t.GetName()) {
			mcpTags = pluginCapTags(t)
			continue
		}
		row := globalPluginRowVM{Name: t.GetName(), Display: orName(t.GetDisplayName(), t.GetName()), Tags: pluginCapTags(t), Status: "None", Kind: "none"}
		switch {
		case usesEmbedder[t.GetName()]:
			row.Kind, row.Status = "embedder", ""
		case !hasGlobalFields(t):
		case globalNeeds(t, global[t.GetName()]) != "":
			row.Kind, row.Status = "warn", globalNeeds(t, global[t.GetName()])
		default:
			row.Kind, row.Status = "set", "Set"
		}
		vm.Builtin = append(vm.Builtin, row)
	}
	sort.Slice(vm.Builtin, func(i, j int) bool { return vm.Builtin[i].Display < vm.Builtin[j].Display })

	servers, _ := h.listMCPServers(r.Context())
	tests := h.testMCPServers(r.Context(), servers)
	if mcpTags == nil {
		mcpTags = []string{"Tool"}
	}
	for _, s := range servers {
		t := tests[s.GetId()]
		row := mcpPluginRowVM{ID: s.GetId(), Name: s.GetName(), Tags: mcpTags, OK: t.OK}
		if t.OK {
			row.Status = sbPlural(len(t.Tools), "tool")
		} else {
			row.Status = "Failing · " + shortErr(t.Err)
		}
		vm.MCP = append(vm.MCP, row)
	}
	n := h.loadSnav(r.Context(), r, "plugins")
	n.ServersBad = failing(tests)
	h.render(w, r, http.StatusOK, globalPluginsScreen(n, vm))
}

// --- one plugin's shared settings ---

type perProfileFieldVM struct {
	Display string
	Summary string
}

type pluginConfigPageVM struct {
	Name       string
	Display    string
	Desc       string
	Shared     []configFieldVM
	PerProfile []perProfileFieldVM
	Dirty      int
	Error      string
}

// fieldDefaultSummary words a per-profile field's default: "Default 5",
// "Default Moderate", "Not set by default".
func fieldDefaultSummary(f *psmithv1.ConfigField) string {
	d := f.GetDefaultJson()
	if d == "" || d == "null" || d == `""` {
		return "Not set by default"
	}
	v := jsonScalarString(json.RawMessage(d))
	for _, o := range f.GetOptions() {
		if o.GetValue() == v {
			v = orName(o.GetLabel(), v)
		}
	}
	if f.GetType() == psmithv1.ConfigField_BOOLEAN {
		v = map[string]string{"true": "On", "false": "Off"}[v]
	}
	return "Default " + v
}

func (h *Handler) pluginConfigVM(r *http.Request, name string) (pluginConfigPageVM, *psmithv1.PluginType, bool) {
	t := h.pluginTypesByName(r.Context())[name]
	if t == nil || isMCPPlugin(name) {
		return pluginConfigPageVM{}, nil, false
	}
	var cfg []byte
	if resp, err := h.profiles.GetUserPluginSettings(r.Context(), connect.NewRequest(&psmithv1.GetUserPluginSettingsRequest{PluginName: name})); err == nil {
		cfg = resp.Msg.GetSettings().GetConfig()
	}
	vm := pluginConfigPageVM{
		Name:    name,
		Display: orName(t.GetDisplayName(), name),
		Desc:    t.GetDescription(),
		Shared:  configFieldVMs(t, cfg, h.listModels(r.Context(), ""), true),
	}
	for _, f := range t.GetConfigFields() {
		if !f.GetGlobal() {
			vm.PerProfile = append(vm.PerProfile, perProfileFieldVM{Display: orName(f.GetDisplay(), f.GetName()), Summary: fieldDefaultSummary(f)})
		}
	}
	return vm, t, true
}

func (h *Handler) handleGlobalPluginConfig(w http.ResponseWriter, r *http.Request) {
	vm, _, ok := h.pluginConfigVM(r, r.PathValue("name"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	h.render(w, r, http.StatusOK, pluginConfigScreen(h.loadSnav(r.Context(), r, "plugins"), vm))
}

func (h *Handler) handleGlobalPluginConfigSave(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	vm, t, ok := h.pluginConfigVM(r, name)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var current []byte
	if resp, err := h.profiles.GetUserPluginSettings(r.Context(), connect.NewRequest(&psmithv1.GetUserPluginSettingsRequest{PluginName: name})); err == nil {
		current = resp.Msg.GetSettings().GetConfig()
	}
	cfg, err := assembleGlobalConfig(t, current, func(field string) string { return r.PostFormValue("cfg_" + field) })
	if err == nil {
		_, err = h.profiles.UpsertUserPluginSettings(r.Context(), connect.NewRequest(&psmithv1.UpsertUserPluginSettingsRequest{PluginName: name, Config: cfg}))
	}
	if err != nil {
		vm.Error = errMessage(err)
		h.render(w, r, http.StatusBadRequest, pluginConfigScreen(h.loadSnav(r.Context(), r, "plugins"), vm))
		return
	}
	http.Redirect(w, r, "/settings/plugins/"+name, http.StatusSeeOther)
}
