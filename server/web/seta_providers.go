package web

import (
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func saInitial(s string) string {
	for _, r := range s {
		return strings.ToUpper(string(r))
	}
	return "?"
}

func saHost(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	return u.Host
}

// --- list ---

func (h *Handler) handleProviders(w http.ResponseWriter, r *http.Request) {
	h.renderProviders(w, r, nil)
}

func (h *Handler) renderProviders(w http.ResponseWriter, r *http.Request, catalogMsg *testVM) {
	ctx := r.Context()
	resp, err := h.models.ListUserModelProviders(ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	counts := map[string]int{}
	if all, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{})); err == nil {
		for _, e := range all.Msg.GetEntries() {
			counts[e.GetProvider().GetId()]++
		}
	}
	bases := h.templateBases(r)
	vm := providersPageVM{CanRefresh: saIsAdmin(r), CatalogMsg: catalogMsg}
	for _, p := range resp.Msg.GetProviders() {
		cfg, _ := readProviderConfig(p.GetConfig())
		parts := []string{p.GetType()}
		if cfg.BaseURL != "" && cfg.BaseURL != bases[saTemplateKeyFor(p.GetType(), cfg.PresetID)] {
			parts = append(parts, saHost(cfg.BaseURL))
		}
		on := counts[p.GetId()]
		models := strconv.Itoa(on) + " " + saPlural(on, "model", "models") + " on"
		if ids := p.GetLastDiscoveredModelIds(); len(ids) > on {
			models = strconv.Itoa(on) + " of " + strconv.Itoa(len(ids)) + " models on"
		}
		row := provRowVM{ID: p.GetId(), Name: p.GetLabel(), Initial: saInitial(p.GetLabel()), Sub: strings.Join(append(parts, models), " · "), StatusText: "Not tested"}
		if st, ok := lastTest(p); ok {
			if st.OK {
				row.Status, row.StatusText = "ok", "Connected"
			} else {
				row.Status, row.StatusText = "bad", "Last test failed"
			}
		}
		vm.Rows = append(vm.Rows, row)
	}
	if st, err := h.models.GetCatalogStatus(ctx, connect.NewRequest(&psmithv1.GetCatalogStatusRequest{})); err == nil {
		vm.CatalogLine = saCatalogLine(st.Msg.GetProvidersCount(), st.Msg.GetModelsCount(), st.Msg.GetLastRefreshAt().AsTime(), st.Msg.LastRefreshAt != nil)
	}
	h.render(w, r, http.StatusOK, providersScreen(h.loadSnav(ctx, r, "providers"), vm))
}

func saCatalogLine(provs, models int32, at time.Time, known bool) string {
	s := saGroupInt(int64(provs)) + " providers, " + saGroupInt(int64(models)) + " models"
	if known {
		return s + " · refreshed " + at.Local().Format("Jan 2")
	}
	return s + " · never refreshed"
}

func (h *Handler) handleCatalogRefresh(w http.ResponseWriter, r *http.Request) {
	resp, err := h.models.RefreshModelCatalog(r.Context(), connect.NewRequest(&psmithv1.RefreshModelCatalogRequest{}))
	if err != nil {
		h.renderProviders(w, r, &testVM{Message: "Refresh failed: " + saErrMsg(err)})
		return
	}
	h.renderProviders(w, r, &testVM{OK: true, Message: "Refreshed: " + saGroupInt(int64(resp.Msg.GetModelsCount())) + " models"})
}

// --- add provider ---

// saTemplateKeyFor names a provider's template: the driver type for native
// drivers, the preset for openai-compatible ones.
func saTemplateKeyFor(typ, preset string) string {
	if typ == "openai-compatible" {
		if preset == "" {
			return "custom"
		}
		return preset
	}
	return typ
}

func saTemplateKey(t *psmithv1.ProviderTemplate) string {
	return saTemplateKeyFor(t.GetDriverType(), t.GetPresetId())
}

func (h *Handler) templateBases(r *http.Request) map[string]string {
	out := map[string]string{}
	resp, err := h.models.ListProviderTemplates(r.Context(), connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{}))
	if err != nil {
		return out
	}
	for _, t := range resp.Msg.GetTemplates() {
		out[saTemplateKey(t)] = t.GetApiBase()
	}
	return out
}

func (h *Handler) handleProviderNew(w http.ResponseWriter, r *http.Request) {
	h.renderAddProvider(w, r, http.StatusOK, r.URL.Query().Get("t"), nil, "")
}

// renderAddProvider draws the template tiles and the connection form for
// sel. form carries what the user typed when a create failed.
func (h *Handler) renderAddProvider(w http.ResponseWriter, r *http.Request, status int, sel string, form url.Values, errMsg string) {
	ctx := r.Context()
	tresp, err := h.models.ListProviderTemplates(ctx, connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	have := map[string]bool{}
	if presp, err := h.models.ListUserModelProviders(ctx, connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{})); err == nil {
		for _, p := range presp.Msg.GetProviders() {
			cfg, _ := readProviderConfig(p.GetConfig())
			have[saTemplateKeyFor(p.GetType(), cfg.PresetID)] = true
		}
	}
	types := h.providerTypeNames(r)
	a := addProviderVM{Error: errMsg}
	var chosen *psmithv1.ProviderTemplate
	for _, t := range tresp.Msg.GetTemplates() {
		k := saTemplateKey(t)
		if have[k] {
			continue
		}
		if sel == "" {
			sel = k
		}
		tile := provTileVM{Key: k, Name: t.GetName(), Initial: saInitial(t.GetName()), Sub: saHost(t.GetApiBase()), On: k == sel}
		if tile.On {
			chosen = t
		}
		a.Tiles = append(a.Tiles, tile)
	}
	if sel == "" {
		sel = "custom"
	}
	a.Tiles = append(a.Tiles, provTileVM{Key: "custom", Name: "Custom", Initial: "+", Sub: "Any compatible endpoint", On: sel == "custom"})
	a.Sel = sel
	a.KeyHint = "Paste your API key"
	if chosen != nil {
		a.Name, a.BaseURL = chosen.GetName(), chosen.GetApiBase()
		a.Driver = orDefault(types[chosen.GetDriverType()], chosen.GetDriverType())
		if chosen.GetPresetId() != "" {
			a.Driver += ", " + chosen.GetName() + " preset"
		}
		if chosen.GetEnvKey() != "" {
			a.KeyHint = "Paste your " + chosen.GetEnvKey()
		}
	} else {
		a.Custom = true
	}
	if form != nil {
		a.Name, a.BaseURL, a.CustomDriver = form.Get("label"), form.Get("base_url"), form.Get("driver")
	}
	h.render(w, r, status, addProviderScreen(h.loadSnav(ctx, r, "providers"), a))
}

// handleProviderCreate adds a provider from a template, tests it, and opens
// discovery. A failed test still keeps the provider: the page says why.
func (h *Handler) handleProviderCreate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	ctx := r.Context()
	sel := r.PostFormValue("t")
	label := strings.TrimSpace(r.PostFormValue("label"))
	key := strings.TrimSpace(r.PostFormValue("api_key"))
	base := strings.TrimSpace(r.PostFormValue("base_url"))
	fail := func(msg string) { h.renderAddProvider(w, r, http.StatusUnprocessableEntity, sel, r.PostForm, msg) }

	typ := r.PostFormValue("type")
	cfg := map[string]any{}
	if sel == "custom" {
		typ = r.PostFormValue("driver")
		if typ != "anthropic" {
			typ = "openai-compatible"
		}
		if base == "" {
			fail("A custom provider needs a base URL")
			return
		}
	} else if sel != "" {
		tresp, err := h.models.ListProviderTemplates(ctx, connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{}))
		if err != nil {
			fail(saErrMsg(err))
			return
		}
		for _, t := range tresp.Msg.GetTemplates() {
			if saTemplateKey(t) != sel {
				continue
			}
			typ = t.GetDriverType()
			if t.GetPresetId() != "" {
				cfg["preset_id"] = t.GetPresetId()
				cfg["catalog_provider_id"] = t.GetCatalogProviderId()
			}
		}
	}
	if typ == "" {
		fail("Pick a provider")
		return
	}
	if label == "" {
		fail("Give the provider a name")
		return
	}
	if key == "" && typ == "openai-compatible" {
		// Local servers take no key, but the driver sends one; any value does.
		key = "none"
	}
	if key != "" {
		cfg["api_key"] = key
	}
	if base != "" {
		cfg["base_url"] = base
	}
	raw, _ := json.Marshal(cfg)
	resp, err := h.models.CreateUserModelProvider(ctx, connect.NewRequest(&psmithv1.CreateUserModelProviderRequest{Type: typ, Label: label, Config: raw}))
	if err != nil {
		fail(saErrMsg(err))
		return
	}
	id := resp.Msg.GetProvider().GetId()
	if st := h.testProvider(r, id); !st.OK {
		http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/settings/providers/"+id+"/discover", http.StatusSeeOther)
}

// --- discover ---

func (h *Handler) handleProviderDiscover(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	presp, err := h.models.GetUserModelProvider(ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	d := discoverVM{ProvID: id, ProvName: presp.Msg.GetProvider().GetLabel()}
	resp, err := h.models.DiscoverModels(ctx, connect.NewRequest(&psmithv1.DiscoverModelsRequest{UserModelProviderId: id}))
	if err != nil {
		d.Error = "Discover failed: " + saErrMsg(err)
		h.render(w, r, http.StatusOK, discoverScreen(h.loadSnav(ctx, r, "providers"), d))
		return
	}
	var ids []string
	for _, m := range resp.Msg.GetModels() {
		ids = append(ids, m.GetModelId())
		row := discRowVM{ID: m.GetModelId(), Name: saModelName(m.GetDisplayName(), m.GetModelId()), Caps: saCapTags(m.GetCapabilities()), On: m.GetAlreadyEnabled()}
		if m.ContextWindow != nil {
			row.Context = abbrevTokens(m.GetContextWindow())
		}
		if m.GetPricing() != nil {
			row.Cost, _ = costBucket(m.GetPricing())
		}
		if !row.On {
			d.NewCount++
		}
		d.Rows = append(d.Rows, row)
	}
	// Models already on first, then by name: the list reads as "what you
	// have, then what you could add".
	sort.SliceStable(d.Rows, func(i, j int) bool {
		if d.Rows[i].On != d.Rows[j].On {
			return d.Rows[i].On
		}
		return d.Rows[i].Name < d.Rows[j].Name
	})
	h.render(w, r, http.StatusOK, discoverScreen(h.loadSnav(ctx, r, "providers"), d))
}

func (h *Handler) handleProviderEnable(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if ids := r.PostForm["model_ids"]; len(ids) > 0 {
		if _, err := h.models.EnableModels(r.Context(), connect.NewRequest(&psmithv1.EnableModelsRequest{
			UserModelProviderId: id,
			ModelIds:            ids,
		})); err != nil {
			h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: saErrMsg(err)})
			return
		}
	}
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}
