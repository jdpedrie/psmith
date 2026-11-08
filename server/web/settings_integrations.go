package web

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/embeddings"
)

// Embedder, Langfuse and Speech: one server-side integration each, a config
// row with a write-only secret, a test, and a remove that confirms in place.

// embedderVM and langfuseVM are the legacy templates' shapes.
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

func keyPlaceholder(set bool, empty string) string {
	if set {
		return "Stored encrypted. Type a new key to replace it."
	}
	return empty
}

// maskedSecret stands in for a stored secret the server never returns.
const maskedSecret = "••••••••••••••••"

// --- embedder ---

type sbEmbedderVM struct {
	TypeOpts  []sbOpt
	BaseURL   string
	Model     string
	ModelOrig string
	KeySet    bool
	Enabled   bool
	Waiting   string
	Active    bool
	Status    *testVM
	Dirty     int
	Remove    sbConfirmVM
	Error     string
}

func embedderRemove(open bool) sbConfirmVM {
	return sbConfirmVM{
		ID: "sb-remove", Open: open,
		Label: "Remove configuration", LabelDetail: "Messages already embedded stay searchable. To pause and keep the settings, turn off Use this embedder.",
		Question: "Remove the embedder configuration?", Detail: "Messages already embedded stay searchable. New ones wait until an embedder is configured again.",
		Verb: "Remove", OpenHref: "/settings/embedder?remove=1", CancelHref: "/settings/embedder", Action: "/settings/embedder/delete", InForm: true,
	}
}

func (h *Handler) handleEmbedder(w http.ResponseWriter, r *http.Request) {
	h.renderEmbedder(w, r, nil)
}

func (h *Handler) renderEmbedder(w http.ResponseWriter, r *http.Request, result *testVM) {
	rm := embedderRemove(r.URL.Query().Get("remove") == "1")
	if fragmentFor(r, rm.ID) {
		h.render(w, r, http.StatusOK, sbConfirm(rm))
		return
	}
	cfgResp, err := h.embedder.GetEmbedderConfig(r.Context(), connect.NewRequest(&psmithv1.GetEmbedderConfigRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c := cfgResp.Msg.GetConfig()
	vm := sbEmbedderVM{
		BaseURL: c.GetBaseUrl(), Model: c.GetModel(), ModelOrig: c.GetModel(),
		KeySet: c.GetApiKeySet(), Enabled: c.GetEnabled(), Status: result, Remove: rm,
	}
	if tr, err := h.embedder.ListEmbedderTypes(r.Context(), connect.NewRequest(&psmithv1.ListEmbedderTypesRequest{})); err == nil {
		for i, t := range tr.Msg.GetTypes() {
			vm.TypeOpts = append(vm.TypeOpts, sbOpt{Value: t, Label: t, Selected: t == c.GetType() || (c.GetType() == "" && i == 0)})
		}
	}
	if sr, err := h.embedder.GetEmbedderStats(r.Context(), connect.NewRequest(&psmithv1.GetEmbedderStatsRequest{})); err == nil {
		vm.Waiting = thousands(int64(sr.Msg.GetUnembeddedCount()))
		vm.Active = sr.Msg.GetWorkerActive()
	}
	h.render(w, r, http.StatusOK, embedderScreen(h.loadSnav(r.Context(), r, "embedder"), vm))
}

func (h *Handler) handleEmbedderSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	typ := strings.TrimSpace(r.PostFormValue("type"))
	baseURL := strings.TrimSpace(r.PostFormValue("base_url"))
	model := strings.TrimSpace(r.PostFormValue("model"))
	enabled := r.PostFormValue("enabled") == "true"
	req := &psmithv1.UpdateEmbedderConfigRequest{Type: &typ, BaseUrl: &baseURL, Model: &model, Enabled: &enabled}
	// The vector column is fixed, so the page doesn't ask; sending it
	// repairs a config saved before the server enforced it.
	dims := int32(embeddings.StoredDimensions)
	req.Dimensions = &dims
	if k := r.PostFormValue("api_key"); k != "" {
		req.ApiKey = &k
	}
	if _, err := h.embedder.UpdateEmbedderConfig(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderEmbedder(w, r, &testVM{Message: errMessage(err)})
		return
	}
	http.Redirect(w, r, "/settings/embedder", http.StatusSeeOther)
}

func (h *Handler) handleEmbedderTest(w http.ResponseWriter, r *http.Request) {
	resp, err := h.embedder.TestEmbedderConfig(r.Context(), connect.NewRequest(&psmithv1.TestEmbedderConfigRequest{}))
	result := &testVM{}
	switch {
	case err != nil:
		result.Message = errMessage(err)
	case resp.Msg.GetOk():
		result.OK = true
		result.Message = "Embedded a test phrase in " + strconv.FormatInt(resp.Msg.GetLatencyMs(), 10) + " ms, just now"
	default:
		result.Message = resp.Msg.GetErrorMessage()
	}
	h.renderEmbedder(w, r, result)
}

func (h *Handler) handleEmbedderDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.embedder.DeleteEmbedderConfig(r.Context(), connect.NewRequest(&psmithv1.DeleteEmbedderConfigRequest{})); err != nil {
		h.renderEmbedder(w, r, &testVM{Message: errMessage(err)})
		return
	}
	http.Redirect(w, r, "/settings/embedder", http.StatusSeeOther)
}

// --- langfuse ---

type sbLangfuseVM struct {
	Host      string
	PublicKey string
	SecretSet bool
	Replace   bool // the secret row shows an input
	Enabled   bool
	LastEmit  string
	Status    *testVM
	Dirty     int
	Remove    sbConfirmVM
}

func langfuseRemove(open bool) sbConfirmVM {
	return sbConfirmVM{
		ID: "sb-remove", Open: open,
		Label: "Remove configuration", LabelDetail: "The keys go and tracing stops. To keep the keys and pause tracing, turn off Send traces instead.",
		Question: "Remove the Langfuse configuration?", Detail: "The keys go and tracing stops. To keep the keys and pause tracing, turn off Send traces instead.",
		Verb: "Remove", OpenHref: "/settings/langfuse?remove=1", CancelHref: "/settings/langfuse", Action: "/settings/langfuse/delete", InForm: true,
	}
}

func (h *Handler) handleLangfuse(w http.ResponseWriter, r *http.Request) {
	h.renderLangfuse(w, r, nil)
}

func (h *Handler) renderLangfuse(w http.ResponseWriter, r *http.Request, result *testVM) {
	rm := langfuseRemove(r.URL.Query().Get("remove") == "1")
	if fragmentFor(r, rm.ID) {
		h.render(w, r, http.StatusOK, sbConfirm(rm))
		return
	}
	cfgResp, err := h.langfuse.GetLangfuseConfig(r.Context(), connect.NewRequest(&psmithv1.GetLangfuseConfigRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c := cfgResp.Msg.GetConfig()
	vm := sbLangfuseVM{
		Host: c.GetHost(), PublicKey: c.GetPublicKey(), SecretSet: c.GetSecretKeySet(),
		Replace: r.URL.Query().Get("replace") == "1" || !c.GetSecretKeySet(),
		Enabled: c.GetEnabled(), Status: result, Remove: rm, LastEmit: "None since the server started",
	}
	if t := c.GetLastEmittedAt(); t != nil && !t.AsTime().IsZero() {
		vm.LastEmit = agoLabel(time.Now(), t.AsTime().Local())
	}
	h.render(w, r, http.StatusOK, langfuseScreen(h.loadSnav(r.Context(), r, "langfuse"), vm))
}

func (h *Handler) handleLangfuseSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	host := strings.TrimSpace(r.PostFormValue("host"))
	pub := strings.TrimSpace(r.PostFormValue("public_key"))
	enabled := r.PostFormValue("enabled") == "true"
	req := &psmithv1.UpdateLangfuseConfigRequest{Host: &host, PublicKey: &pub, Enabled: &enabled}
	if k := r.PostFormValue("secret_key"); k != "" {
		req.SecretKey = &k
	}
	if _, err := h.langfuse.UpdateLangfuseConfig(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderLangfuse(w, r, &testVM{Message: errMessage(err)})
		return
	}
	http.Redirect(w, r, "/settings/langfuse", http.StatusSeeOther)
}

func (h *Handler) handleLangfuseTest(w http.ResponseWriter, r *http.Request) {
	resp, err := h.langfuse.TestLangfuseConfig(r.Context(), connect.NewRequest(&psmithv1.TestLangfuseConfigRequest{}))
	result := &testVM{}
	switch {
	case err != nil:
		result.Message = errMessage(err)
	case resp.Msg.GetOk():
		result.OK = true
		result.Message = "Test trace sent in " + strconv.FormatInt(resp.Msg.GetLatencyMs(), 10) + " ms, just now. Look for it in your Langfuse Traces tab."
	default:
		result.Message = resp.Msg.GetErrorMessage()
	}
	h.renderLangfuse(w, r, result)
}

func (h *Handler) handleLangfuseDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.langfuse.DeleteLangfuseConfig(r.Context(), connect.NewRequest(&psmithv1.DeleteLangfuseConfigRequest{})); err != nil {
		h.renderLangfuse(w, r, &testVM{Message: errMessage(err)})
		return
	}
	http.Redirect(w, r, "/settings/langfuse", http.StatusSeeOther)
}
