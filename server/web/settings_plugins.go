package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// pluginRowVM and pluginOptVM are the legacy templates' shapes; the
// conversation settings still use pluginOptVM for its add picker.
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

// --- profile Plugins tab ---

type sbTagVM struct {
	Label string
	Warn  bool
	Href  string // where to fix what the tag says is missing
}

type inhPluginVM struct {
	Name    string
	Display string
	Desc    string
	Tags    []sbTagVM
	On      bool
}

type attPluginVM struct {
	Index   int
	Last    bool
	Name    string
	Display string
	Desc    string
	Tags    []sbTagVM
	Form    pluginConfigForm
	Open    bool
}

type addPluginVM struct {
	Name, Display, Desc string
}

type profilePluginsVM struct {
	Head      profileHeadVM
	Inherited []inhPluginVM
	Attached  []attPluginVM
	Add       []addPluginVM
	AddMCP    []addPluginVM
	AddOpen   bool
	CredName  string // an attached plugin with shared credentials, named in the note
	Dirty     int
	Error     string
}

// pluginCapTags names what a plugin adds, in the boards' words.
func pluginCapTags(t *psmithv1.PluginType) []string {
	c := t.GetCapabilities()
	var out []string
	add := func(on bool, label string) {
		if on {
			out = append(out, label)
		}
	}
	add(c.GetToolProvider(), "Tool")
	add(c.GetSystemPrompter(), "System")
	add(c.GetOutgoingUserTransformer(), "Outgoing")
	add(c.GetAssistantContentTransformer(), "Assistant")
	add(c.GetHistoryTransformer(), "History")
	add(c.GetChunkTransformer(), "Stream")
	add(c.GetDisplayTransformer(), "Display")
	add(c.GetPanelProvider(), "Panel")
	return out
}

func isMCPPlugin(name string) bool { return strings.HasPrefix(name, "mcp:") }

// globalNeeds words what a plugin's shared settings still lack, or "".
func globalNeeds(t *psmithv1.PluginType, global []byte) string {
	var cur map[string]json.RawMessage
	_ = json.Unmarshal(global, &cur)
	var missing []string
	for _, f := range t.GetConfigFields() {
		if !f.GetGlobal() || !f.GetRequired() {
			continue
		}
		if v, ok := cur[f.GetName()]; !ok || jsonScalarString(v) == "" {
			missing = append(missing, orName(f.GetDisplay(), f.GetName()))
		}
	}
	switch len(missing) {
	case 0:
		return ""
	case 1:
		return "Needs " + article(missing[0]) + " " + missing[0]
	default:
		return "Needs setup"
	}
}

func article(s string) string {
	if s != "" && strings.ContainsRune("AEIOUaeiou", rune(s[0])) {
		return "an"
	}
	return "a"
}

// requiredMissing counts the required per-profile fields config leaves empty.
func requiredMissing(t *psmithv1.PluginType, config []byte) int {
	var cur map[string]json.RawMessage
	_ = json.Unmarshal(config, &cur)
	n := 0
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() || !f.GetRequired() {
			continue
		}
		v, ok := cur[f.GetName()]
		if !ok && f.GetDefaultJson() != "" {
			continue
		}
		if !ok || jsonScalarString(v) == "" || string(v) == "null" {
			n++
		}
	}
	return n
}

func (h *Handler) userPluginSettings(ctx context.Context) map[string][]byte {
	out := map[string][]byte{}
	resp, err := h.profiles.ListUserPluginSettings(ctx, connect.NewRequest(&psmithv1.ListUserPluginSettingsRequest{}))
	if err != nil {
		return out
	}
	for _, s := range resp.Msg.GetSettings() {
		out[s.GetPluginName()] = s.GetConfig()
	}
	return out
}

// pluginTags is a plugin's capability tags plus what it still needs.
func pluginTags(t *psmithv1.PluginType, config, global []byte) []sbTagVM {
	var out []sbTagVM
	for _, c := range pluginCapTags(t) {
		out = append(out, sbTagVM{Label: c})
	}
	if isMCPPlugin(t.GetName()) {
		out = append(out, sbTagVM{Label: "MCP"})
	}
	if need := globalNeeds(t, global); need != "" {
		out = append(out, sbTagVM{Label: need + " in Plugins", Warn: true, Href: "/settings/plugins/" + url.PathEscape(t.GetName())})
	}
	switch n := requiredMissing(t, config); n {
	case 0:
	case 1:
		out = append(out, sbTagVM{Label: "1 required field", Warn: true})
	default:
		out = append(out, sbTagVM{Label: strconv.Itoa(n) + " required fields", Warn: true})
	}
	return out
}

func (h *Handler) profilePlugins(ctx context.Context, profileID string) []*psmithv1.ProfilePlugin {
	resp, err := h.profiles.GetProfilePlugins(ctx, connect.NewRequest(&psmithv1.GetProfilePluginsRequest{ProfileId: profileID}))
	if err != nil {
		return nil
	}
	return resp.Msg.GetPlugins()
}

// inheritedPluginNames is what the parent chain hands down, in pipeline
// order: walking leaf to root, a disabled row hides that plugin from every
// ancestor above it, the same rule the resolver applies.
func (h *Handler) inheritedPluginNames(ctx context.Context, ix profileIndex, p *psmithv1.Profile) []string {
	dropped := map[string]bool{}
	ord := map[string]int32{}
	var names []string
	for _, anc := range ix.chain(p)[1:] {
		for _, row := range h.profilePlugins(ctx, anc.GetId()) {
			n := row.GetPluginName()
			if dropped[n] {
				continue
			}
			if row.GetDisabled() {
				dropped[n] = true
				continue
			}
			if _, seen := ord[n]; !seen {
				names = append(names, n)
			}
			ord[n] = row.GetOrdinal()
		}
	}
	sort.SliceStable(names, func(i, j int) bool { return ord[names[i]] < ord[names[j]] })
	return names
}

func (h *Handler) handlePluginsPage(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	vm := h.pluginsTabVM(r.Context(), ix, p)
	if open := r.URL.Query().Get("open"); open != "" {
		for i := range vm.Attached {
			vm.Attached[i].Open = vm.Attached[i].Name == open
		}
	}
	h.render(w, r, http.StatusOK, profilePluginsScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
}

func (h *Handler) pluginsTabVM(ctx context.Context, ix profileIndex, p *psmithv1.Profile) profilePluginsVM {
	catalog := h.pluginTypesByName(ctx)
	global := h.userPluginSettings(ctx)
	models := h.listModels(ctx, "")
	vm := profilePluginsVM{Head: ix.head(p, "plugins")}

	own := h.profilePlugins(ctx, p.GetId())
	attached := map[string]bool{}
	off := map[string]bool{}
	for _, row := range own {
		if row.GetDisabled() {
			off[row.GetPluginName()] = true
			continue
		}
		attached[row.GetPluginName()] = true
		t := catalog[row.GetPluginName()]
		if t == nil {
			t = &psmithv1.PluginType{Name: row.GetPluginName()}
		}
		if vm.CredName == "" && hasGlobalFields(t) {
			vm.CredName = orName(t.GetDisplayName(), t.GetName())
		}
		vm.Attached = append(vm.Attached, attPluginVM{
			Index:   len(vm.Attached),
			Name:    row.GetPluginName(),
			Display: orName(t.GetDisplayName(), row.GetPluginName()),
			Desc:    pluginBlurb(t),
			Tags:    pluginTags(t, row.GetConfig(), global[row.GetPluginName()]),
			Form:    h.buildPluginForm(ctx, t, row.GetConfig(), models),
		})
	}
	if n := len(vm.Attached); n > 0 {
		vm.Attached[n-1].Last = true
	}
	for _, n := range h.inheritedPluginNames(ctx, ix, p) {
		if attached[n] {
			continue
		}
		t := catalog[n]
		if t == nil {
			t = &psmithv1.PluginType{Name: n}
		}
		desc := pluginBlurb(t)
		if off[n] {
			desc = strings.TrimSpace(desc + " Off for " + p.GetName() + ".")
		}
		var tags []sbTagVM
		for _, c := range pluginCapTags(t) {
			tags = append(tags, sbTagVM{Label: c})
		}
		vm.Inherited = append(vm.Inherited, inhPluginVM{Name: n, Display: orName(t.GetDisplayName(), n), Desc: desc, Tags: tags, On: !off[n]})
	}
	for _, t := range catalog {
		if attached[t.GetName()] {
			continue
		}
		opt := addPluginVM{Name: t.GetName(), Display: orName(t.GetDisplayName(), t.GetName()), Desc: firstSentence(t.GetDescription())}
		if isMCPPlugin(t.GetName()) {
			vm.AddMCP = append(vm.AddMCP, opt)
		} else {
			vm.Add = append(vm.Add, opt)
		}
	}
	byName := func(s []addPluginVM) {
		sort.Slice(s, func(i, j int) bool { return s[i].Display < s[j].Display })
	}
	byName(vm.Add)
	byName(vm.AddMCP)
	return vm
}

// pluginBlurb is the line under a plugin's name: its first sentence.
func pluginBlurb(t *psmithv1.PluginType) string {
	return firstSentence(t.GetDescription())
}

func firstSentence(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, ". "); i >= 0 {
		return s[:i+1]
	}
	return s
}

// pluginsFromForm reads the Plugins tab as posted: the attached rows in
// the order their positions (ppos_i) give, with their config, minus the
// ones marked removed, then a disabled row for each inherited plugin
// switched off. msg is set when the form can't be saved as it stands.
func (h *Handler) pluginsFromForm(r *http.Request, p *psmithv1.Profile) (attached, off []*psmithv1.ProfilePlugin, msg string) {
	catalog := h.pluginTypesByName(r.Context())
	existing := map[string][]byte{}
	keptOff := map[string]bool{}
	for _, row := range h.profilePlugins(r.Context(), p.GetId()) {
		existing[row.GetPluginName()] = row.GetConfig()
		if row.GetDisabled() {
			keptOff[row.GetPluginName()] = true
		}
	}
	pos := map[string]int{}
	for i := 0; ; i++ {
		name := r.PostFormValue(fmt.Sprintf("pname_%d", i))
		if name == "" {
			break
		}
		if r.PostFormValue(fmt.Sprintf("premoved_%d", i)) == "true" {
			continue
		}
		pos[name] = i
		if n, err := strconv.Atoi(r.PostFormValue(fmt.Sprintf("ppos_%d", i))); err == nil {
			pos[name] = n
		}
		t := catalog[name]
		var cfg []byte
		if pluginHasForm(t) {
			prefix := fmt.Sprintf("p%d_cfg_", i)
			cfg, _ = assemblePluginConfig(t, existing[name], func(field string) string {
				return r.PostFormValue(prefix + field)
			})
		} else if raw, present := r.PostForm[fmt.Sprintf("pconfig_%d", i)]; present {
			s := strings.TrimSpace(raw[0])
			if s == "" {
				s = "{}"
			} else if !json.Valid([]byte(s)) {
				return nil, nil, "The config for " + orName(displayName(t), name) + " is not valid JSON."
			}
			cfg = []byte(s)
		} else {
			cfg = existing[name]
		}
		attached = append(attached, &psmithv1.ProfilePlugin{PluginName: name, Config: cfg})
	}
	sort.SliceStable(attached, func(a, b int) bool { return pos[attached[a].GetPluginName()] < pos[attached[b].GetPluginName()] })
	for k := 0; ; k++ {
		name := r.PostFormValue(fmt.Sprintf("inh_name_%d", k))
		if name == "" {
			break
		}
		delete(keptOff, name)
		if r.PostFormValue(fmt.Sprintf("inh_on_%d", k)) == "false" {
			off = append(off, &psmithv1.ProfilePlugin{PluginName: name, Config: []byte("{}"), Disabled: true})
		}
	}
	// Disabled rows for plugins no longer inherited still mean something if
	// a parent brings them back, so they stay.
	for _, n := range sortedKeys(keptOff) {
		off = append(off, &psmithv1.ProfilePlugin{PluginName: n, Config: []byte("{}"), Disabled: true})
	}
	return attached, off, ""
}

func numbered(plugins []*psmithv1.ProfilePlugin) []*psmithv1.ProfilePlugin {
	for i, pl := range plugins {
		pl.Ordinal = int32(i)
	}
	return plugins
}

// handlePluginsSave persists the Plugins tab.
func (h *Handler) handlePluginsSave(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	attached, off, msg := h.pluginsFromForm(r, p)
	if msg != "" {
		h.renderPluginsErr(w, r, ix, p, msg)
		return
	}
	if err := h.setPlugins(r, p.GetId(), numbered(append(attached, off...))); err != nil {
		h.renderPluginsErr(w, r, ix, p, errMessage(err))
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+p.GetId()+"/plugins", http.StatusSeeOther)
}

func (h *Handler) renderPluginsErr(w http.ResponseWriter, r *http.Request, ix profileIndex, p *psmithv1.Profile, msg string) {
	vm := h.pluginsTabVM(r.Context(), ix, p)
	vm.Error = msg
	h.showAfterPost(w, r, "/settings/profiles/"+p.GetId()+"/plugins", profilePluginsScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
}

// handlePluginAdd appends a plugin with empty config. The Add buttons sit
// on the tab's form, so the rest of what was posted is saved with it; a
// request without the tab's fields adds to what is stored.
func (h *Handler) handlePluginAdd(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	name := r.PostFormValue("plugin_name")
	if name == "" {
		http.Error(w, "plugin_name required", http.StatusBadRequest)
		return
	}
	attached, off, msg := h.tabOrStored(r, p)
	if msg != "" {
		h.renderPluginsErr(w, r, ix, p, msg)
		return
	}
	attached = append(attached, &psmithv1.ProfilePlugin{PluginName: name, Config: []byte("{}")})
	var keep []*psmithv1.ProfilePlugin
	for _, o := range off {
		if o.GetPluginName() != name {
			keep = append(keep, o)
		}
	}
	if err := h.setPlugins(r, p.GetId(), numbered(append(attached, keep...))); err != nil {
		h.renderPluginsErr(w, r, ix, p, errMessage(err))
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+p.GetId()+"/plugins?open="+url.QueryEscape(name), http.StatusSeeOther)
}

// handlePluginRemove drops one attached plugin right away. The tab's remove
// buttons post here without JS, carrying the rest of the form; with it they
// mark the row and the save bar commits the removal with everything else.
func (h *Handler) handlePluginRemove(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	name := r.PostFormValue("remove")
	attached, off, msg := h.tabOrStored(r, p)
	if msg != "" {
		h.renderPluginsErr(w, r, ix, p, msg)
		return
	}
	var kept []*psmithv1.ProfilePlugin
	for _, a := range attached {
		if a.GetPluginName() != name {
			kept = append(kept, a)
		}
	}
	if err := h.setPlugins(r, p.GetId(), numbered(append(kept, off...))); err != nil {
		h.renderPluginsErr(w, r, ix, p, errMessage(err))
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+p.GetId()+"/plugins", http.StatusSeeOther)
}

// handlePluginMove moves one attached plugin a place up or down and saves
// the tab with it. The arrows post here without script, carrying the rest
// of the form, as Remove does; with script they reorder the rows in place
// and the save bar commits the order with everything else.
func (h *Handler) handlePluginMove(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	dir, name, _ := strings.Cut(r.PostFormValue("move"), ":")
	attached, off, msg := h.tabOrStored(r, p)
	if msg != "" {
		h.renderPluginsErr(w, r, ix, p, msg)
		return
	}
	attached = movePlugin(attached, name, dir == "up")
	if err := h.setPlugins(r, p.GetId(), numbered(append(attached, off...))); err != nil {
		h.renderPluginsErr(w, r, ix, p, errMessage(err))
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+p.GetId()+"/plugins", http.StatusSeeOther)
}

// movePlugin swaps the named plugin with its neighbor above (up) or below.
// At either end, or for a name that isn't there, the order stays.
func movePlugin(plugins []*psmithv1.ProfilePlugin, name string, up bool) []*psmithv1.ProfilePlugin {
	for i, pl := range plugins {
		if pl.GetPluginName() != name {
			continue
		}
		j := i + 1
		if up {
			j = i - 1
		}
		if j >= 0 && j < len(plugins) {
			plugins[i], plugins[j] = plugins[j], plugins[i]
		}
		break
	}
	return plugins
}

// tabOrStored is the pipeline as the tab posted it, or as stored when the
// request didn't come from the tab.
func (h *Handler) tabOrStored(r *http.Request, p *psmithv1.Profile) (attached, off []*psmithv1.ProfilePlugin, msg string) {
	if r.PostFormValue("pname_0") != "" || r.PostFormValue("inh_name_0") != "" {
		return h.pluginsFromForm(r, p)
	}
	for _, row := range h.profilePlugins(r.Context(), p.GetId()) {
		if row.GetDisabled() {
			off = append(off, row)
		} else {
			attached = append(attached, row)
		}
	}
	return attached, off, ""
}

func (h *Handler) currentPlugins(r *http.Request, profileID string) []*psmithv1.ProfilePlugin {
	return h.profilePlugins(r.Context(), profileID)
}

func (h *Handler) setPlugins(r *http.Request, profileID string, plugins []*psmithv1.ProfilePlugin) error {
	_, err := h.profiles.SetProfilePlugins(r.Context(), connect.NewRequest(&psmithv1.SetProfilePluginsRequest{
		ProfileId: profileID,
		Plugins:   plugins,
	}))
	return err
}
