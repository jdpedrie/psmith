package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

type pluginRowVM struct {
	Name     string
	Display  string
	Disabled bool
	Form     pluginConfigForm
}

type pluginOptVM struct {
	Name        string
	DisplayName string
	Description string
}

func (h *Handler) handlePluginsPage(w http.ResponseWriter, r *http.Request) {
	profileID := r.PathValue("id")
	prof, err := h.profiles.GetProfile(r.Context(), connect.NewRequest(&reevev1.GetProfileRequest{Id: profileID}))
	if err != nil {
		http.Error(w, "profile not found", http.StatusNotFound)
		return
	}
	plugResp, err := h.profiles.GetProfilePlugins(r.Context(), connect.NewRequest(&reevev1.GetProfilePluginsRequest{ProfileId: profileID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	catalog := h.pluginTypesByName(r.Context())
	models := h.listModels(r.Context(), "")
	attached := map[string]bool{}
	var rows []pluginRowVM
	for _, p := range plugResp.Msg.GetPlugins() {
		attached[p.GetPluginName()] = true
		t := catalog[p.GetPluginName()]
		rows = append(rows, pluginRowVM{
			Name:     p.GetPluginName(),
			Display:  orName(displayName(t), p.GetPluginName()),
			Disabled: p.GetDisabled(),
			Form:     h.buildPluginForm(r.Context(), t, p.GetConfig(), models),
		})
	}

	// Offer only plugins not already attached.
	var types []pluginOptVM
	for _, tpe := range catalog {
		if attached[tpe.GetName()] {
			continue
		}
		types = append(types, pluginOptVM{Name: tpe.GetName(), DisplayName: orName(tpe.GetDisplayName(), tpe.GetName()), Description: tpe.GetDescription()})
	}
	sort.Slice(types, func(i, j int) bool { return types[i].DisplayName < types[j].DisplayName })
	h.render(w, r, http.StatusOK, profilePluginsPage(profileID, prof.Msg.GetProfile().GetName(), rows, types))
}

// handlePluginsSave persists the edited pipeline (config + disabled per row).
func (h *Handler) handlePluginsSave(w http.ResponseWriter, r *http.Request) {
	profileID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	catalog := h.pluginTypesByName(r.Context())
	existing := map[string][]byte{}
	for _, p := range h.currentPlugins(r, profileID) {
		existing[p.GetPluginName()] = p.GetConfig()
	}
	var plugins []*reevev1.ProfilePlugin
	for i := 0; ; i++ {
		name := r.PostFormValue(fmt.Sprintf("pname_%d", i))
		if name == "" {
			break
		}
		t := catalog[name]
		var cfg []byte
		if pluginHasForm(t) {
			// Assemble from the declared fields (p{i}_cfg_<field>), starting from
			// the current stored config so unknown keys survive.
			prefix := fmt.Sprintf("p%d_cfg_", i)
			cfg, _ = assemblePluginConfig(t, existing[name], func(field string) string {
				return r.PostFormValue(prefix + field)
			})
		} else {
			raw := strings.TrimSpace(r.PostFormValue(fmt.Sprintf("pconfig_%d", i)))
			if raw == "" {
				raw = "{}"
			} else if !json.Valid([]byte(raw)) {
				http.Error(w, "config is not valid JSON", http.StatusBadRequest)
				return
			}
			cfg = []byte(raw)
		}
		plugins = append(plugins, &reevev1.ProfilePlugin{
			PluginName: name,
			Ordinal:    int32(i),
			Config:     cfg,
			Disabled:   r.PostFormValue(fmt.Sprintf("pdisabled_%d", i)) != "",
		})
	}
	if err := h.setPlugins(r, profileID, plugins); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+profileID+"/plugins", http.StatusSeeOther)
}

// handlePluginAdd appends a plugin type to the pipeline with empty config.
func (h *Handler) handlePluginAdd(w http.ResponseWriter, r *http.Request) {
	profileID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	name := r.PostFormValue("plugin_name")
	if name == "" {
		http.Error(w, "plugin_name required", http.StatusBadRequest)
		return
	}
	current := h.currentPlugins(r, profileID)
	current = append(current, &reevev1.ProfilePlugin{PluginName: name, Ordinal: int32(len(current)), Config: []byte("{}")})
	if err := h.setPlugins(r, profileID, current); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+profileID+"/plugins", http.StatusSeeOther)
}

// handlePluginRemove drops the plugin at the given ordinal.
func (h *Handler) handlePluginRemove(w http.ResponseWriter, r *http.Request) {
	profileID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	idx, err := strconv.Atoi(r.PostFormValue("ordinal"))
	if err != nil {
		http.Error(w, "bad ordinal", http.StatusBadRequest)
		return
	}
	current := h.currentPlugins(r, profileID)
	if idx < 0 || idx >= len(current) {
		http.Redirect(w, r, "/settings/profiles/"+profileID+"/plugins", http.StatusSeeOther)
		return
	}
	current = append(current[:idx], current[idx+1:]...)
	for i, p := range current {
		p.Ordinal = int32(i)
	}
	if err := h.setPlugins(r, profileID, current); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+profileID+"/plugins", http.StatusSeeOther)
}

func (h *Handler) currentPlugins(r *http.Request, profileID string) []*reevev1.ProfilePlugin {
	resp, err := h.profiles.GetProfilePlugins(r.Context(), connect.NewRequest(&reevev1.GetProfilePluginsRequest{ProfileId: profileID}))
	if err != nil {
		return nil
	}
	return resp.Msg.GetPlugins()
}

func (h *Handler) setPlugins(r *http.Request, profileID string, plugins []*reevev1.ProfilePlugin) error {
	_, err := h.profiles.SetProfilePlugins(r.Context(), connect.NewRequest(&reevev1.SetProfilePluginsRequest{
		ProfileId: profileID,
		Plugins:   plugins,
	}))
	return err
}
