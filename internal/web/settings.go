package web

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

// itoa and orDefault are small helpers used by the settings templates.
func itoa(n int32) string { return strconv.Itoa(int(n)) }

func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// --- view models ---

type providerVM struct {
	ID    string
	Type  string
	Label string
}

type providerTypeVM struct {
	Name        string
	DisplayName string
}

type enabledModelVM struct {
	ModelID     string
	DisplayName string
}

type discoveredVM struct {
	ModelID     string
	DisplayName string
	Enabled     bool
}

type testVM struct {
	OK         bool
	Message    string
	ModelCount int32
}

type profileRowVM struct {
	ID          string
	Name        string
	Description string
	Template    bool
}

type profileFormVM struct {
	ID            string
	Name          string
	SystemMessage string
	Description   string
}

// --- settings home ---

func (h *Handler) handleSettings(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, settingsPage())
}

// --- providers ---

func (h *Handler) handleProviders(w http.ResponseWriter, r *http.Request) {
	resp, err := h.models.ListUserModelProviders(r.Context(), connect.NewRequest(&reevev1.ListUserModelProvidersRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var provs []providerVM
	for _, p := range resp.Msg.GetProviders() {
		provs = append(provs, providerVM{ID: p.GetId(), Type: p.GetType(), Label: p.GetLabel()})
	}
	h.render(w, r, http.StatusOK, providersPage(provs))
}

func (h *Handler) handleProviderNew(w http.ResponseWriter, r *http.Request) {
	resp, err := h.models.ListProviderTypes(r.Context(), connect.NewRequest(&reevev1.ListProviderTypesRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var types []providerTypeVM
	for _, t := range resp.Msg.GetTypes() {
		types = append(types, providerTypeVM{Name: t.GetName(), DisplayName: t.GetDisplayName()})
	}
	h.render(w, r, http.StatusOK, providerNewPage(types, ""))
}

func (h *Handler) handleProviderCreate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	typ := r.PostFormValue("type")
	label := strings.TrimSpace(r.PostFormValue("label"))
	if typ == "" || label == "" {
		http.Error(w, "type and label are required", http.StatusBadRequest)
		return
	}
	cfg := map[string]string{}
	if k := strings.TrimSpace(r.PostFormValue("api_key")); k != "" {
		cfg["api_key"] = k
	}
	if b := strings.TrimSpace(r.PostFormValue("base_url")); b != "" {
		cfg["base_url"] = b
	}
	cfgJSON, _ := json.Marshal(cfg)

	resp, err := h.models.CreateUserModelProvider(r.Context(), connect.NewRequest(&reevev1.CreateUserModelProviderRequest{
		Type:   typ,
		Label:  label,
		Config: cfgJSON,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/providers/"+resp.Msg.GetProvider().GetId(), http.StatusSeeOther)
}

func (h *Handler) handleProvider(w http.ResponseWriter, r *http.Request) {
	h.renderProviderDetail(w, r, http.StatusOK, r.PathValue("id"), nil, nil)
}

func (h *Handler) handleProviderDiscover(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	resp, err := h.models.DiscoverModels(r.Context(), connect.NewRequest(&reevev1.DiscoverModelsRequest{
		UserModelProviderId: id,
	}))
	if err != nil {
		h.renderProviderDetail(w, r, http.StatusOK, id, nil, &testVM{OK: false, Message: "Discover failed: " + err.Error()})
		return
	}
	var discovered []discoveredVM
	for _, m := range resp.Msg.GetModels() {
		discovered = append(discovered, discoveredVM{
			ModelID:     m.GetModelId(),
			DisplayName: m.GetDisplayName(),
			Enabled:     m.GetAlreadyEnabled(),
		})
	}
	h.renderProviderDetail(w, r, http.StatusOK, id, discovered, nil)
}

func (h *Handler) handleProviderEnable(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	ids := r.PostForm["model_ids"]
	if len(ids) > 0 {
		if _, err := h.models.EnableModels(r.Context(), connect.NewRequest(&reevev1.EnableModelsRequest{
			UserModelProviderId: id,
			ModelIds:            ids,
		})); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}

func (h *Handler) handleProviderTest(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	resp, err := h.models.TestUserModelProvider(r.Context(), connect.NewRequest(&reevev1.TestUserModelProviderRequest{
		UserModelProviderId: id,
	}))
	result := &testVM{}
	if err != nil {
		result.OK, result.Message = false, err.Error()
	} else {
		result.OK = resp.Msg.GetOk()
		result.Message = resp.Msg.GetErrorMessage()
		result.ModelCount = resp.Msg.GetModelCount()
	}
	h.renderProviderDetail(w, r, http.StatusOK, id, nil, result)
}

func (h *Handler) handleProviderDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.models.DeleteUserModelProvider(r.Context(), connect.NewRequest(&reevev1.DeleteUserModelProviderRequest{
		Id: id,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/providers", http.StatusSeeOther)
}

// renderProviderDetail loads a provider and its enabled models and renders the
// detail page, optionally with a freshly-discovered model list and/or a test
// result banner.
func (h *Handler) renderProviderDetail(w http.ResponseWriter, r *http.Request, status int, id string, discovered []discoveredVM, test *testVM) {
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&reevev1.GetUserModelProviderRequest{Id: id}))
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	prov := resp.Msg.GetProvider()
	var enabled []enabledModelVM
	for _, m := range resp.Msg.GetEnabledModels() {
		name := m.GetDisplayName()
		if name == "" {
			name = m.GetModelId()
		}
		enabled = append(enabled, enabledModelVM{ModelID: m.GetModelId(), DisplayName: name})
	}
	h.render(w, r, status, providerDetailPage(
		providerVM{ID: prov.GetId(), Type: prov.GetType(), Label: prov.GetLabel()},
		enabled, discovered, test,
	))
}
