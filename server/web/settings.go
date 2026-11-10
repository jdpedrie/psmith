package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// --- view models ---

type testVM struct {
	OK         bool
	Message    string
	ModelCount int32
	Detail     string // the service's own error, under a failure's line
}

// --- settings home ---

// handleSettings is General. On a phone the same URL shows the navigation
// list instead; the page carries a marker the stylesheet keys on.
func (h *Handler) handleSettings(w http.ResponseWriter, r *http.Request) {
	h.renderGeneral(w, r, http.StatusOK, generalState{Index: true})
}

// --- shared helpers ---

// saModelPath escapes a model id for a URL path, keeping the slashes that
// router-style ids (openrouter's "anthropic/claude-…") carry.
func saModelPath(id string) string {
	parts := strings.Split(id, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// saGroupInt renders 16384 as "16,384".
func saGroupInt(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

// saParseInt reads the form number for the field called name. It may carry
// thousands separators; empty means unset.
func saParseInt(name, v string) (*int32, error) {
	v = strings.ReplaceAll(strings.TrimSpace(v), ",", "")
	if v == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("%s must be a whole number, not %q", name, v)
	}
	i := int32(n)
	return &i, nil
}

func saParseFloat(name, v string) (*float64, error) {
	v = strings.ReplaceAll(strings.TrimSpace(v), ",", "")
	if v == "" {
		return nil, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return nil, fmt.Errorf("%s must be a number, not %q", name, v)
	}
	return &f, nil
}

func saFloat(f float64) string {
	return strconv.FormatFloat(f, 'f', -1, 64)
}

// saAgo is the "just now" tail of a status line.
func saAgo(now, t time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return strconv.Itoa(int(d.Minutes())) + " min ago"
	case d < 24*time.Hour:
		return strconv.Itoa(int(d.Hours())) + " h ago"
	default:
		return t.Format("Jan 2")
	}
}

func saIsAdmin(r *http.Request) bool {
	u, ok := auth.FromContext(r.Context())
	return ok && u.IsAdmin
}

func saErrMsg(err error) string {
	var ce *connect.Error
	if errors.As(err, &ce) {
		return ce.Message()
	}
	return err.Error()
}

// providerConfig is the slice of a provider's driver config the pages show.
type providerConfig struct {
	APIKey   string `json:"api_key"`
	BaseURL  string `json:"base_url"`
	PresetID string `json:"preset_id"`
	Catalog  string `json:"catalog_provider_id"`
}

func readProviderConfig(raw []byte) (providerConfig, map[string]any) {
	var pc providerConfig
	all := map[string]any{}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &pc)
		_ = json.Unmarshal(raw, &all)
	}
	return pc, all
}

// saMaskKey keeps a key's vendor prefix and last four characters.
func saMaskKey(k string) string {
	if k == "" {
		return "Not set"
	}
	prefix := ""
	if i := strings.LastIndexAny(k[:min(len(k), 8)], "-_"); i >= 0 {
		prefix = k[:i+1]
	}
	suffix := ""
	if len(k) > 8 {
		suffix = k[len(k)-4:]
	}
	return prefix + strings.Repeat("•", 12) + suffix
}

func saCapTags(c *psmithv1.ModelCapabilities) []string {
	var out []string
	if c.GetVision() {
		out = append(out, "Vision")
	}
	if c.GetToolUse() {
		out = append(out, "Tools")
	}
	if c.GetThinking() {
		out = append(out, "Thinking")
	}
	if c.GetGeneratesImages() {
		out = append(out, "Images")
	}
	return out
}

func saModelName(display, id string) string {
	if strings.TrimSpace(display) != "" {
		return display
	}
	return id
}

// --- provider page ---

func (h *Handler) handleProvider(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	h.renderProviderPage(w, r, http.StatusOK, r.PathValue("id"), providerPageState{
		KeyEditing: q.Get("key") != "",
		Confirming: q.Get("remove") != "",
		DelModel:   q.Get("delmodel"),
	})
}

type providerPageState struct {
	KeyEditing bool
	Confirming bool
	DelModel   string // the off hand-added model whose row asks before Delete
	TestModel  string // the model whose row shows Test
	Test       *testVM
	Error      string
}

func (h *Handler) renderProviderPage(w http.ResponseWriter, r *http.Request, status int, id string, st providerPageState) {
	vm, err := h.loadProviderPage(r, id)
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	vm.KeyEditing, vm.Confirming, vm.Error = st.KeyEditing, st.Confirming, st.Error
	for i := range vm.Models {
		m := &vm.Models[i]
		m.Confirming = !m.On && m.ID == st.DelModel
		if m.ID == st.TestModel {
			m.Test = st.Test
		}
	}
	h.render(w, r, status, providerScreen(h.loadSnav(r.Context(), r, "providers"), vm))
}

func (h *Handler) loadProviderPage(r *http.Request, id string) (providerPageVM, error) {
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if err != nil {
		return providerPageVM{}, err
	}
	prov := resp.Msg.GetProvider()
	cfg, _ := readProviderConfig(prov.GetConfig())
	vm := providerPageVM{
		ID:        prov.GetId(),
		Type:      prov.GetType(),
		Name:      prov.GetLabel(),
		KeyMasked: saMaskKey(cfg.APIKey),
		NoCache:   prov.GetType() != "anthropic",
		Caching:   true,
	}
	if prov.GetType() == "openai-compatible" {
		vm.Compatible, vm.BaseURL, vm.Catalog = true, cfg.BaseURL, cfg.Catalog
		vm.Catalogs = h.catalogOptions(r, cfg.Catalog)
	}
	if st, ok := lastTest(prov); ok {
		vm.Test = st.vm(time.Now())
	}
	enabled := map[string]bool{}
	for _, m := range resp.Msg.GetEnabledModels() {
		enabled[m.GetModelId()] = true
		pm := providerModelVM{
			Name: saModelName(m.GetDisplayName(), m.GetModelId()),
			ID:   m.GetModelId(),
			Caps: saCapTags(m.GetCapabilities()),
			On:   true,
		}
		if m.ContextWindow != nil {
			pm.Context = abbrevTokens(m.GetContextWindow())
		}
		if m.GetPricing() != nil {
			pm.Cost, _ = costBucket(m.GetPricing())
		}
		vm.Models = append(vm.Models, pm)
	}
	sort.Slice(vm.Models, func(i, j int) bool { return vm.Models[i].Name < vm.Models[j].Name })
	// Hand-added models that are off keep their rows on the server, so they
	// list after the ones that are on, ready to come back.
	var off []providerModelVM
	for _, m := range resp.Msg.GetDisabledModels() {
		pm := providerModelVM{Name: saModelName(m.GetDisplayName(), m.GetModelId()), ID: m.GetModelId(), Caps: saCapTags(m.GetCapabilities())}
		if m.ContextWindow != nil {
			pm.Context = abbrevTokens(m.GetContextWindow())
		}
		if m.GetPricing() != nil {
			pm.Cost, _ = costBucket(m.GetPricing())
		}
		off = append(off, pm)
	}
	sort.Slice(off, func(i, j int) bool { return off[i].Name < off[j].Name })
	vm.Models = append(vm.Models, off...)
	vm.NewCount = newModels(prov, func(mid string) bool { return enabled[mid] })
	if ds := prov.GetDefaultSettings(); ds != nil {
		if ds.MaxOutputTokens != nil {
			vm.MaxTokens = saGroupInt(int64(ds.GetMaxOutputTokens()))
		}
		if ds.Temperature != nil {
			vm.Temp = saFloat(ds.GetTemperature())
		}
		if a := ds.GetAnthropic(); a != nil && a.CacheEnabled != nil {
			vm.Caching = a.GetCacheEnabled()
		}
	}
	return vm, nil
}

// handleProviderSave writes the connection and the defaults the provider
// page shows. The defaults merge into the stored set so fields only the full
// defaults page edits survive.
func (h *Handler) handleProviderSave(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	prov := resp.Msg.GetProvider()
	req := &psmithv1.UpdateUserModelProviderRequest{Id: id}
	if label := strings.TrimSpace(r.PostFormValue("label")); label != "" && label != prov.GetLabel() {
		req.Label = &label
	}
	// The server merges config keys over the stored ones, so only what this
	// page edits is sent.
	patch := map[string]any{}
	if key := strings.TrimSpace(r.PostFormValue("api_key")); key != "" {
		patch["api_key"] = key
	}
	if prov.GetType() == "openai-compatible" {
		cfg, _ := readProviderConfig(prov.GetConfig())
		if _, ok := r.PostForm["base_url"]; ok {
			base := strings.TrimSpace(r.PostFormValue("base_url"))
			if base == "" {
				h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: "An OpenAI-compatible provider needs a base URL"})
				return
			}
			if base != cfg.BaseURL {
				patch["base_url"] = base
			}
		}
		if cat, ok := r.PostForm["catalog"]; ok && cat[0] != cfg.Catalog {
			patch["catalog_provider_id"] = cat[0]
		}
	}
	if len(patch) > 0 {
		raw, _ := json.Marshal(patch)
		req.Config = raw
	}
	ds := prov.GetDefaultSettings()
	if ds == nil {
		ds = &psmithv1.CallSettings{}
	}
	maxTok, err := saParseInt("Max output tokens", r.PostFormValue("max_output_tokens"))
	if err == nil {
		err = saInRange("Max output tokens", maxTok, 1, 1<<30)
	}
	if err == nil {
		var temp *float64
		if temp, err = saParseFloat("Temperature", r.PostFormValue("temperature")); err == nil {
			err = saInRange("Temperature", temp, 0, 2)
		}
		ds.MaxOutputTokens, ds.Temperature = maxTok, temp
	}
	if err != nil {
		h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: err.Error()})
		return
	}
	if v := r.PostFormValue("cache_enabled"); v != "" && prov.GetType() == "anthropic" {
		on := v == "true"
		if ds.Anthropic == nil {
			ds.Anthropic = &psmithv1.AnthropicExtras{}
		}
		// On is the driver's default, so it is stored as unset.
		if on {
			ds.Anthropic.CacheEnabled = nil
		} else {
			ds.Anthropic.CacheEnabled = &on
		}
	}
	req.DefaultSettings = ds
	if _, err := h.models.UpdateUserModelProvider(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}

func (h *Handler) handleProviderTest(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	h.testProvider(r, id)
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}

// testProvider runs the connection test; the server records the outcome for
// the list's status dot.
func (h *Handler) testProvider(r *http.Request, id string) provStatus {
	resp, err := h.models.TestUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.TestUserModelProviderRequest{
		UserModelProviderId: id,
	}))
	st := provStatus{At: time.Now()}
	switch {
	case err != nil:
		st.Msg = saErrMsg(err)
	case !resp.Msg.GetOk():
		st.Msg = resp.Msg.GetErrorMessage()
	default:
		st.OK, st.LatencyMS = true, resp.Msg.GetLatencyMs()
	}
	return st
}

func (h *Handler) handleProviderDisable(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_ = r.ParseForm()
	if mid := r.PostFormValue("model_id"); mid != "" {
		if _, err := h.models.DisableModels(r.Context(), connect.NewRequest(&psmithv1.DisableModelsRequest{
			UserModelProviderId: id, ModelIds: []string{mid},
		})); err != nil {
			h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: saErrMsg(err)})
			return
		}
	}
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}

// catalogOptions lists the models.dev catalogs an OpenAI-compatible provider
// can borrow prices and limits from: every compatible template's. cur stays
// listed even when no template names it.
func (h *Handler) catalogOptions(r *http.Request, cur string) []saOpt {
	var out []saOpt
	seen := map[string]bool{"": true}
	if resp, err := h.models.ListProviderTemplates(r.Context(), connect.NewRequest(&psmithv1.ListProviderTemplatesRequest{})); err == nil {
		for _, t := range resp.Msg.GetTemplates() {
			id := t.GetCatalogProviderId()
			if t.GetDriverType() != "openai-compatible" || seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, saOpt{Value: id, Label: t.GetName()})
		}
	}
	if !seen[cur] {
		out = append(out, saOpt{Value: cur, Label: cur})
	}
	return out
}

// handleProviderRowTest tests one model from the provider's list and draws
// the outcome in its row.
func (h *Handler) handleProviderRowTest(w http.ResponseWriter, r *http.Request) {
	id, mid := r.PathValue("id"), r.PathValue("model")
	resp, err := h.models.TestUserModel(r.Context(), connect.NewRequest(&psmithv1.TestUserModelRequest{UserModelProviderId: id, ModelId: mid}))
	h.renderProviderPage(w, r, http.StatusOK, id, providerPageState{TestModel: mid, Test: rowTestResult(resp, err)})
}

func rowTestResult(resp *connect.Response[psmithv1.TestUserModelResponse], err error) *testVM {
	if err != nil {
		return &testVM{Message: "Test failed: " + saErrMsg(err)}
	}
	t := resp.Msg
	if !t.GetOk() {
		return &testVM{Message: "Test failed: " + t.GetErrorMessage()}
	}
	return &testVM{OK: true, Message: fmt.Sprintf("Answered in %d ms · %d tokens in, %d out", t.GetLatencyMs(), t.GetInputTokens(), t.GetOutputTokens())}
}

// handleModelDelete deletes a model added by hand, on or off. Discover won't
// bring it back, so the page asks first.
func (h *Handler) handleModelDelete(w http.ResponseWriter, r *http.Request) {
	id, mid := r.PathValue("id"), r.PathValue("model")
	if _, err := h.models.DisableModels(r.Context(), connect.NewRequest(&psmithv1.DisableModelsRequest{
		UserModelProviderId: id, ModelIds: []string{mid}, DeleteManual: true,
	})); err != nil {
		h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/providers/"+id, http.StatusSeeOther)
}

func (h *Handler) handleProviderDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.models.DeleteUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.DeleteUserModelProviderRequest{
		Id: id,
	})); err != nil {
		h.renderProviderPage(w, r, http.StatusUnprocessableEntity, id, providerPageState{Error: saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/providers", http.StatusSeeOther)
}

func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}
