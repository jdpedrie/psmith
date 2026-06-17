package web

import (
	"net/http"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
)

func keyHint(set bool) string {
	if set {
		return "(set; leave blank to keep)"
	}
	return "(stored encrypted)"
}

func workerState(active bool) string {
	if active {
		return "active"
	}
	return "idle"
}

// --- view models ---

type embedderVM struct {
	Type            string
	BaseURL         string
	Model           string
	Dimensions      int32
	APIKeySet       bool
	Enabled         bool
	Types           []string
	UnembeddedCount int32
	WorkerActive    bool
	Result          *testVM
}

type langfuseVM struct {
	Host         string
	PublicKey    string
	SecretKeySet bool
	Enabled      bool
	Result       *testVM
}

// --- embedder ---

func (h *Handler) handleEmbedder(w http.ResponseWriter, r *http.Request) {
	h.renderEmbedder(w, r, nil)
}

func (h *Handler) renderEmbedder(w http.ResponseWriter, r *http.Request, result *testVM) {
	cfgResp, err := h.embedder.GetEmbedderConfig(r.Context(), connect.NewRequest(&spaltv1.GetEmbedderConfigRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c := cfgResp.Msg.GetConfig()
	vm := embedderVM{
		Type:       c.GetType(),
		BaseURL:    c.GetBaseUrl(),
		Model:      c.GetModel(),
		Dimensions: c.GetDimensions(),
		APIKeySet:  c.GetApiKeySet(),
		Enabled:    c.GetEnabled(),
		Result:     result,
	}
	if tr, err := h.embedder.ListEmbedderTypes(r.Context(), connect.NewRequest(&spaltv1.ListEmbedderTypesRequest{})); err == nil {
		vm.Types = tr.Msg.GetTypes()
	}
	if sr, err := h.embedder.GetEmbedderStats(r.Context(), connect.NewRequest(&spaltv1.GetEmbedderStatsRequest{})); err == nil {
		vm.UnembeddedCount = sr.Msg.GetUnembeddedCount()
		vm.WorkerActive = sr.Msg.GetWorkerActive()
	}
	h.render(w, r, http.StatusOK, embedderPage(vm))
}

func (h *Handler) handleEmbedderSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	typ := strings.TrimSpace(r.PostFormValue("type"))
	baseURL := strings.TrimSpace(r.PostFormValue("base_url"))
	model := strings.TrimSpace(r.PostFormValue("model"))
	enabled := r.PostFormValue("enabled") != ""
	req := &spaltv1.UpdateEmbedderConfigRequest{
		Type:    &typ,
		BaseUrl: &baseURL,
		Model:   &model,
		Enabled: &enabled,
	}
	if d, err := strconv.Atoi(strings.TrimSpace(r.PostFormValue("dimensions"))); err == nil {
		d32 := int32(d)
		req.Dimensions = &d32
	}
	// Only send the API key when the user typed one; blank leaves it unchanged.
	if k := r.PostFormValue("api_key"); k != "" {
		req.ApiKey = &k
	}
	if _, err := h.embedder.UpdateEmbedderConfig(r.Context(), connect.NewRequest(req)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/embedder", http.StatusSeeOther)
}

func (h *Handler) handleEmbedderTest(w http.ResponseWriter, r *http.Request) {
	resp, err := h.embedder.TestEmbedderConfig(r.Context(), connect.NewRequest(&spaltv1.TestEmbedderConfigRequest{}))
	result := &testVM{}
	if err != nil {
		result.Message = err.Error()
	} else {
		result.OK = resp.Msg.GetOk()
		result.Message = resp.Msg.GetErrorMessage()
	}
	h.renderEmbedder(w, r, result)
}

func (h *Handler) handleEmbedderDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.embedder.DeleteEmbedderConfig(r.Context(), connect.NewRequest(&spaltv1.DeleteEmbedderConfigRequest{})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/embedder", http.StatusSeeOther)
}

// --- langfuse ---

func (h *Handler) handleLangfuse(w http.ResponseWriter, r *http.Request) {
	h.renderLangfuse(w, r, nil)
}

func (h *Handler) renderLangfuse(w http.ResponseWriter, r *http.Request, result *testVM) {
	cfgResp, err := h.langfuse.GetLangfuseConfig(r.Context(), connect.NewRequest(&spaltv1.GetLangfuseConfigRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c := cfgResp.Msg.GetConfig()
	h.render(w, r, http.StatusOK, langfusePage(langfuseVM{
		Host:         c.GetHost(),
		PublicKey:    c.GetPublicKey(),
		SecretKeySet: c.GetSecretKeySet(),
		Enabled:      c.GetEnabled(),
		Result:       result,
	}))
}

func (h *Handler) handleLangfuseSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	host := strings.TrimSpace(r.PostFormValue("host"))
	pub := strings.TrimSpace(r.PostFormValue("public_key"))
	enabled := r.PostFormValue("enabled") != ""
	req := &spaltv1.UpdateLangfuseConfigRequest{
		Host:      &host,
		PublicKey: &pub,
		Enabled:   &enabled,
	}
	if k := r.PostFormValue("secret_key"); k != "" {
		req.SecretKey = &k
	}
	if _, err := h.langfuse.UpdateLangfuseConfig(r.Context(), connect.NewRequest(req)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/langfuse", http.StatusSeeOther)
}

func (h *Handler) handleLangfuseTest(w http.ResponseWriter, r *http.Request) {
	resp, err := h.langfuse.TestLangfuseConfig(r.Context(), connect.NewRequest(&spaltv1.TestLangfuseConfigRequest{}))
	result := &testVM{}
	if err != nil {
		result.Message = err.Error()
	} else {
		result.OK = resp.Msg.GetOk()
		result.Message = resp.Msg.GetErrorMessage()
	}
	h.renderLangfuse(w, r, result)
}

func (h *Handler) handleLangfuseDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.langfuse.DeleteLangfuseConfig(r.Context(), connect.NewRequest(&spaltv1.DeleteLangfuseConfigRequest{})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/langfuse", http.StatusSeeOther)
}
