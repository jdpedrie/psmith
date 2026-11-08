package web

import (
	"fmt"
	"net/http"
	"reflect"
	"slices"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// loadModel finds one enabled model and its provider.
func (h *Handler) loadModel(r *http.Request, provID, modelID string) (*psmithv1.UserModelProvider, *psmithv1.UserModel, error) {
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: provID}))
	if err != nil {
		return nil, nil, err
	}
	for _, m := range resp.Msg.GetEnabledModels() {
		if m.GetModelId() == modelID {
			return resp.Msg.GetProvider(), m, nil
		}
	}
	return nil, nil, fmt.Errorf("model %q is not on", modelID)
}

func saPrice(p *float64) string {
	if p == nil {
		return ""
	}
	return fmt.Sprintf("%.2f", *p)
}

func saMetaLine(m *psmithv1.UserModel) string {
	var src string
	switch m.GetMetadataSource() {
	case psmithv1.MetadataSource_METADATA_SOURCE_CATALOG:
		src = "From the models.dev catalog"
	case psmithv1.MetadataSource_METADATA_SOURCE_DRIVER:
		src = "From the provider’s model list"
	case psmithv1.MetadataSource_METADATA_SOURCE_MANUAL:
		src = "Entered by hand"
	default:
		src = "Unknown source"
	}
	if at := m.GetMetadataSnapshotAt(); at != nil {
		src += ", " + at.AsTime().Local().Format("Jan 2")
	}
	return src
}

func saCapToggles(c *psmithv1.ModelCapabilities) []saTog {
	on := map[string]bool{
		"streaming": c.GetStreaming(), "thinking": c.GetThinking(), "tool_use": c.GetToolUse(),
		"vision": c.GetVision(), "prompt_caching": c.GetPromptCaching(), "generates_images": c.GetGeneratesImages(),
	}
	out := make([]saTog, 0, len(saCapOpts))
	for _, o := range saCapOpts {
		out = append(out, saTog{Value: o.Value, Label: o.Label, On: on[o.Value]})
	}
	return out
}

func saModToggles(mods []string) []saTog {
	out := make([]saTog, 0, len(saModOpts))
	for _, o := range saModOpts {
		out = append(out, saTog{Value: o.Value, Label: o.Label, On: slices.Contains(mods, o.Value)})
	}
	return out
}

func saCapsFromForm(vals []string) *psmithv1.ModelCapabilities {
	has := func(s string) bool { return slices.Contains(vals, s) }
	return &psmithv1.ModelCapabilities{
		Streaming: has("streaming"), Thinking: has("thinking"), ToolUse: has("tool_use"),
		Vision: has("vision"), PromptCaching: has("prompt_caching"), GeneratesImages: has("generates_images"),
	}
}

func (h *Handler) modelPageVM(prov *psmithv1.UserModelProvider, m *psmithv1.UserModel) modelPageVM {
	vm := modelPageVM{
		ProvID: prov.GetId(), ProvName: prov.GetLabel(), ProvType: prov.GetType(),
		ID: m.GetModelId(), Name: saModelName(m.GetDisplayName(), m.GetModelId()), Favorite: m.GetFavorite(),
		MetaLine: saMetaLine(m), Caps: saCapToggles(m.GetCapabilities()), Mods: saModToggles(m.GetModalities()),
	}
	if m.ContextWindow != nil {
		vm.Ctx = saGroupInt(int64(m.GetContextWindow()))
	}
	if m.MaxOutputTokens != nil {
		vm.Out = saGroupInt(int64(m.GetMaxOutputTokens()))
	}
	if p := m.GetPricing(); p != nil {
		vm.In, vm.OutP = saPrice(p.InputPerMillionTokens), saPrice(p.OutputPerMillionTokens)
		vm.CR, vm.CW = saPrice(p.CacheReadPerMillionTokens), saPrice(p.CacheWritePerMillionTokens)
	}
	own, inh := csFromProto(m.GetDefaultSettings()), csFromProto(prov.GetDefaultSettings())
	vm.Temp, vm.MaxTok, vm.Effort = own.Temp, own.MaxTok, own.Effort
	vm.TempHint = "Model default"
	if inh.Temp != "" {
		vm.TempHint = "Inherits " + inh.Temp + " from " + prov.GetLabel()
	}
	if inh.MaxTok != "" {
		vm.MaxInherit = inh.MaxTok
		vm.MaxHint = "Inherits " + inh.MaxTok + " from " + prov.GetLabel()
	}
	if inh.Effort != "" {
		vm.EffortInherit = effortLabels[inh.Effort]
	}
	return vm
}

func (h *Handler) handleModel(w http.ResponseWriter, r *http.Request) {
	h.renderModel(w, r, http.StatusOK, nil, nil, "")
}

func (h *Handler) renderModel(w http.ResponseWriter, r *http.Request, status int, res *testVM, probe []probeRowVM, errMsg string) {
	prov, m, err := h.loadModel(r, r.PathValue("id"), r.PathValue("model"))
	if err != nil {
		http.Error(w, "model not found", http.StatusNotFound)
		return
	}
	vm := h.modelPageVM(prov, m)
	vm.Result, vm.Probe, vm.Error = res, probe, errMsg
	h.render(w, r, status, modelScreen(h.loadSnav(r.Context(), r, "providers"), vm))
}

// handleModelSave writes the model page: identity, limits, prices,
// capabilities, modalities and the three call settings it shows. Other call
// settings on the model are kept.
func (h *Handler) handleModelSave(w http.ResponseWriter, r *http.Request) {
	provID, modelID := r.PathValue("id"), r.PathValue("model")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	_, m, err := h.loadModel(r, provID, modelID)
	if err != nil {
		http.Error(w, "model not found", http.StatusNotFound)
		return
	}
	req, err := modelUpdateFromForm(r, m)
	if err != nil {
		h.renderModel(w, r, http.StatusUnprocessableEntity, nil, nil, err.Error())
		return
	}
	req.UserModelProviderId, req.ModelId = provID, modelID
	if _, err := h.models.UpdateUserModel(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderModel(w, r, http.StatusUnprocessableEntity, nil, nil, saErrMsg(err))
		return
	}
	http.Redirect(w, r, "/settings/providers/"+provID+"/models/"+saModelPath(modelID), http.StatusSeeOther)
}

type saLimitsForm struct {
	ctx, out         *int32
	in, outp, cr, cw *float64
	caps             *psmithv1.ModelCapabilities
	mods             []string
}

func saReadLimits(r *http.Request) (saLimitsForm, error) {
	var l saLimitsForm
	var err error
	if l.ctx, err = saParseInt(r.PostFormValue("context_window")); err != nil {
		return l, err
	}
	if l.out, err = saParseInt(r.PostFormValue("max_output")); err != nil {
		return l, err
	}
	for _, f := range []struct {
		dst  **float64
		name string
	}{{&l.in, "price_in"}, {&l.outp, "price_out"}, {&l.cr, "price_cache_read"}, {&l.cw, "price_cache_write"}} {
		if *f.dst, err = saParseFloat(r.PostFormValue(f.name)); err != nil {
			return l, err
		}
	}
	l.caps = saCapsFromForm(r.PostForm["cap"])
	l.mods = r.PostForm["modality"]
	if l.mods == nil {
		l.mods = []string{}
	}
	return l, nil
}

func (l saLimitsForm) pricing(tiers []*psmithv1.PricingTier) *psmithv1.ModelPricing {
	if l.in == nil && l.outp == nil && l.cr == nil && l.cw == nil && len(tiers) == 0 {
		return nil
	}
	return &psmithv1.ModelPricing{InputPerMillionTokens: l.in, OutputPerMillionTokens: l.outp,
		CacheReadPerMillionTokens: l.cr, CacheWritePerMillionTokens: l.cw, Tiers: tiers}
}

func modelUpdateFromForm(r *http.Request, m *psmithv1.UserModel) (*psmithv1.UpdateUserModelRequest, error) {
	l, err := saReadLimits(r)
	if err != nil {
		return nil, err
	}
	req := &psmithv1.UpdateUserModelRequest{
		Capabilities:     l.caps,
		UpdateModalities: true,
		Modalities:       l.mods,
	}
	if name := strings.TrimSpace(r.PostFormValue("display_name")); name != "" {
		req.DisplayName = &name
	}
	req.ContextWindow, req.ClearContextWindow = l.ctx, l.ctx == nil
	req.MaxOutputTokens, req.ClearMaxOutputTokens = l.out, l.out == nil
	// Pricing replaces wholesale; tiers aren't on this page, so carry them.
	if p := l.pricing(m.GetPricing().GetTiers()); p != nil {
		req.Pricing = p
	} else if m.GetPricing() != nil {
		req.Pricing = &psmithv1.ModelPricing{}
	}

	ds := m.GetDefaultSettings()
	if ds == nil {
		ds = &psmithv1.CallSettings{}
	}
	if ds.Temperature, err = saParseFloat(r.PostFormValue("temperature")); err != nil {
		return nil, err
	}
	if err = saInRange("Temperature", ds.Temperature, 0, 2); err != nil {
		return nil, err
	}
	if ds.MaxOutputTokens, err = saParseInt(r.PostFormValue("max_output_tokens")); err != nil {
		return nil, err
	}
	if e, ok := effortByName[r.PostFormValue("effort")]; ok {
		ds.Thinking = &psmithv1.ThinkingSettings{Effort: e}
	} else {
		ds.Thinking = nil
	}
	req.DefaultSettings = ds
	return req, nil
}

// handleModelOp runs one of the model page's header and row actions.
func (h *Handler) handleModelOp(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	provID, modelID := r.PathValue("id"), r.PathValue("model")
	_, m, err := h.loadModel(r, provID, modelID)
	if err != nil {
		http.Error(w, "model not found", http.StatusNotFound)
		return
	}
	back := "/settings/providers/" + provID + "/models/" + saModelPath(modelID)
	switch r.PathValue("op") {
	case "favorite":
		if _, err := h.models.ToggleUserModelFavorite(ctx, connect.NewRequest(&psmithv1.ToggleUserModelFavoriteRequest{
			UserModelProviderId: provID, ModelId: modelID, Favorite: !m.GetFavorite(),
		})); err != nil {
			h.renderModel(w, r, http.StatusUnprocessableEntity, nil, nil, saErrMsg(err))
			return
		}
		http.Redirect(w, r, back, http.StatusSeeOther)
	case "disable":
		if _, err := h.models.DisableModels(ctx, connect.NewRequest(&psmithv1.DisableModelsRequest{
			UserModelProviderId: provID, ModelIds: []string{modelID},
		})); err != nil {
			h.renderModel(w, r, http.StatusUnprocessableEntity, nil, nil, saErrMsg(err))
			return
		}
		http.Redirect(w, r, "/settings/providers/"+provID, http.StatusSeeOther)
	case "test":
		resp, err := h.models.TestUserModel(ctx, connect.NewRequest(&psmithv1.TestUserModelRequest{UserModelProviderId: provID, ModelId: modelID}))
		h.renderModel(w, r, http.StatusOK, modelTestResult(resp, err, time.Now()), nil, "")
	case "refresh":
		resp, err := h.models.RefreshUserModelMetadata(ctx, connect.NewRequest(&psmithv1.RefreshUserModelMetadataRequest{UserModelProviderId: provID, ModelId: modelID}))
		res := &testVM{OK: true, Message: "Metadata refreshed from the catalog"}
		switch {
		case err != nil:
			res = &testVM{Message: "Refresh failed: " + saErrMsg(err)}
		case !resp.Msg.GetRefreshed():
			res = &testVM{Message: "The catalog has no entry for this model, so nothing changed"}
		}
		h.renderModel(w, r, http.StatusOK, res, nil, "")
	case "probe":
		resp, err := h.models.ProbeUserModel(ctx, connect.NewRequest(&psmithv1.ProbeUserModelRequest{UserModelProviderId: provID, ModelId: modelID, Apply: true}))
		if err != nil {
			h.renderModel(w, r, http.StatusOK, &testVM{Message: "Probe failed: " + saErrMsg(err)}, nil, "")
			return
		}
		res, rows := saProbeSummary(resp.Msg)
		h.renderModel(w, r, http.StatusOK, res, rows, "")
	default:
		http.NotFound(w, r)
	}
}

func modelTestResult(resp *connect.Response[psmithv1.TestUserModelResponse], err error, now time.Time) *testVM {
	if err != nil {
		return &testVM{Message: "Test failed: " + saErrMsg(err)}
	}
	t := resp.Msg
	if !t.GetOk() {
		return &testVM{Message: "Test failed: " + t.GetErrorMessage()}
	}
	sample := strings.TrimSpace(t.GetSampleText())
	if len(sample) > 40 {
		sample = sample[:40] + "…"
	}
	return &testVM{OK: true, Message: fmt.Sprintf("Replied “%s” in %d ms · %d tokens in, %d out · %s",
		sample, t.GetLatencyMs(), t.GetInputTokens(), t.GetOutputTokens(), saAgo(now, now))}
}

var saCapNames = map[string]string{
	"streaming": "Streaming", "tool_use": "Tool use", "vision": "Vision", "thinking": "Thinking",
	"prompt_caching": "Prompt caching", "generates_images": "Makes images",
}

func saProbeSummary(p *psmithv1.ProbeUserModelResponse) (*testVM, []probeRowVM) {
	var rows []probeRowVM
	for _, c := range p.GetResults() {
		row := probeRowVM{Capability: orDefault(saCapNames[c.GetCapability()], c.GetCapability()), Detail: c.GetDetail()}
		switch c.GetOutcome() {
		case psmithv1.ProbeOutcome_PROBE_OUTCOME_SUPPORTED:
			row.Outcome, row.Good = "works", true
		case psmithv1.ProbeOutcome_PROBE_OUTCOME_UNSUPPORTED:
			row.Outcome = "refused"
		case psmithv1.ProbeOutcome_PROBE_OUTCOME_SKIPPED:
			row.Outcome = "skipped"
		default:
			row.Outcome = "inconclusive"
		}
		rows = append(rows, row)
	}
	label := func(names []string) string {
		out := make([]string, len(names))
		for i, n := range names {
			out[i] = orDefault(saCapNames[n], n)
		}
		return strings.Join(out, ", ")
	}
	res := &testVM{OK: true, Message: "Probe done. The stored capabilities already match."}
	if len(p.GetEnabled()) > 0 {
		res.Message = "Probe switched on " + label(p.GetEnabled()) + "."
	}
	if len(p.GetContradicted()) > 0 {
		res = &testVM{Message: res.Message + " Refused: " + label(p.GetContradicted()) + ". Turn those off if they stay refused."}
	}
	return res, rows
}

// --- call settings pages ---

func (h *Handler) handleProviderDefaults(w http.ResponseWriter, r *http.Request) {
	h.renderProviderDefaults(w, r, http.StatusOK, nil, "")
}

func (h *Handler) renderProviderDefaults(w http.ResponseWriter, r *http.Request, status int, f *csForm, errMsg string) {
	id := r.PathValue("id")
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: id}))
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	prov := resp.Msg.GetProvider()
	d := providerDefaultsVM(prov)
	if f != nil {
		d.F = *f
	}
	d.Error = errMsg
	h.render(w, r, status, defaultsScreen(h.loadSnav(r.Context(), r, "providers"), d))
}

func providerDefaultsVM(prov *psmithv1.UserModelProvider) defaultsPageVM {
	name := prov.GetLabel()
	return defaultsPageVM{
		Crumbs: []saCrumb{{"Providers", "/settings/providers"}, {name, "/settings/providers/" + prov.GetId()}},
		Title:  name + " defaults",
		Lede:   "Every " + name + " model starts here. A model’s own settings win, then the profile’s, then the conversation’s. Not set means the model’s own default.",
		Action: "/settings/providers/" + prov.GetId() + "/defaults",
		Level:  "provider", ProvName: name, ProvType: prov.GetType(),
		F: csFromProto(prov.GetDefaultSettings()),
	}
}

func (h *Handler) handleProviderDefaultsSave(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	f := csFormFromValues(r.PostForm)
	cs, err := f.toProto()
	if err != nil {
		h.renderProviderDefaults(w, r, http.StatusUnprocessableEntity, &f, err.Error())
		return
	}
	if _, err := h.models.UpdateUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.UpdateUserModelProviderRequest{Id: id, DefaultSettings: cs})); err != nil {
		h.renderProviderDefaults(w, r, http.StatusUnprocessableEntity, &f, saErrMsg(err))
		return
	}
	http.Redirect(w, r, "/settings/providers/"+id+"/defaults", http.StatusSeeOther)
}

func (h *Handler) handleModelDefaults(w http.ResponseWriter, r *http.Request) {
	h.renderModelDefaults(w, r, http.StatusOK, nil, "")
}

func (h *Handler) renderModelDefaults(w http.ResponseWriter, r *http.Request, status int, f *csForm, errMsg string) {
	prov, m, err := h.loadModel(r, r.PathValue("id"), r.PathValue("model"))
	if err != nil {
		http.Error(w, "model not found", http.StatusNotFound)
		return
	}
	name := saModelName(m.GetDisplayName(), m.GetModelId())
	base := "/settings/providers/" + prov.GetId()
	d := defaultsPageVM{
		Crumbs: []saCrumb{{"Providers", "/settings/providers"}, {prov.GetLabel(), base}, {name, base + "/models/" + saModelPath(m.GetModelId())}},
		Title:  name + " call settings",
		Lede:   "These sit above " + prov.GetLabel() + "’s defaults and below profiles and conversations. Leave a field empty to inherit.",
		Action: base + "/model-defaults/" + saModelPath(m.GetModelId()),
		Level:  "model", ProvName: prov.GetLabel(), ProvType: prov.GetType(),
		F: csFromProto(m.GetDefaultSettings()), Inh: csFromProto(prov.GetDefaultSettings()),
		Error: errMsg,
	}
	if f != nil {
		d.F = *f
	}
	h.render(w, r, status, defaultsScreen(h.loadSnav(r.Context(), r, "providers"), d))
}

func (h *Handler) handleModelDefaultsSave(w http.ResponseWriter, r *http.Request) {
	provID, modelID := r.PathValue("id"), r.PathValue("model")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	f := csFormFromValues(r.PostForm)
	cs, err := f.toProto()
	if err != nil {
		h.renderModelDefaults(w, r, http.StatusUnprocessableEntity, &f, err.Error())
		return
	}
	if _, err := h.models.UpdateUserModel(r.Context(), connect.NewRequest(&psmithv1.UpdateUserModelRequest{
		UserModelProviderId: provID, ModelId: modelID, DefaultSettings: cs,
	})); err != nil {
		h.renderModelDefaults(w, r, http.StatusUnprocessableEntity, &f, saErrMsg(err))
		return
	}
	http.Redirect(w, r, "/settings/providers/"+provID+"/model-defaults/"+saModelPath(modelID), http.StatusSeeOther)
}

// --- manual models ---

func (h *Handler) handleAddModel(w http.ResponseWriter, r *http.Request) {
	h.renderAddModel(w, r, http.StatusOK, nil, "")
}

func (h *Handler) renderAddModel(w http.ResponseWriter, r *http.Request, status int, form *addModelVM, errMsg string) {
	resp, err := h.models.GetUserModelProvider(r.Context(), connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: r.PathValue("id")}))
	if err != nil {
		http.Error(w, "provider not found", http.StatusNotFound)
		return
	}
	prov := resp.Msg.GetProvider()
	a := addModelVM{
		Caps: saCapToggles(&psmithv1.ModelCapabilities{Streaming: true}),
		Mods: saModToggles([]string{"text"}),
	}
	if form != nil {
		a = *form
	}
	a.ProvID, a.ProvName, a.Error = prov.GetId(), prov.GetLabel(), errMsg
	calls := a.Calls.F
	a.Calls = providerDefaultsVM(prov)
	a.Calls.Level, a.Calls.Inh, a.Calls.F = "model", a.Calls.F, calls
	h.render(w, r, status, addModelScreen(h.loadSnav(r.Context(), r, "providers"), a))
}

func (h *Handler) handleAddModelSave(w http.ResponseWriter, r *http.Request) {
	provID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	v := r.PostForm
	form := addModelVM{
		ModelID: strings.TrimSpace(v.Get("model_id")), Name: strings.TrimSpace(v.Get("display_name")),
		Ctx: v.Get("context_window"), Out: v.Get("max_output"),
		In: v.Get("price_in"), OutP: v.Get("price_out"), CR: v.Get("price_cache_read"), CW: v.Get("price_cache_write"),
		Caps: saCapToggles(saCapsFromForm(v["cap"])), Mods: saModToggles(v["modality"]),
	}
	form.Calls.F = csFormFromValues(v)
	form.CallsOpen = !reflect.ValueOf(form.Calls.F).IsZero()
	fail := func(msg string) { h.renderAddModel(w, r, http.StatusUnprocessableEntity, &form, msg) }
	if form.ModelID == "" || form.Name == "" {
		fail("A model needs an ID and a display name")
		return
	}
	l, err := saReadLimits(r)
	if err != nil {
		fail(err.Error())
		return
	}
	req := &psmithv1.AddManualModelRequest{
		UserModelProviderId: provID, ModelId: form.ModelID, DisplayName: form.Name,
		ContextWindow: l.ctx, MaxOutputTokens: l.out, Pricing: l.pricing(nil),
		Modalities: l.mods, Capabilities: l.caps,
	}
	if form.CallsOpen {
		cs, err := form.Calls.F.toProto()
		if err != nil {
			fail(err.Error())
			return
		}
		req.DefaultSettings = cs
	}
	if _, err := h.models.AddManualModel(r.Context(), connect.NewRequest(req)); err != nil {
		fail(saErrMsg(err))
		return
	}
	http.Redirect(w, r, "/settings/providers/"+provID+"/models/"+saModelPath(form.ModelID), http.StatusSeeOther)
}
