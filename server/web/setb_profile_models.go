package web

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

type profileModelsVM struct {
	Head           profileHeadVM
	ReplyOpts      []sbOpt
	CompOpts       []sbOpt
	TitleOpts      []sbOpt
	Mode           string // "" (inherit) | REPLACE | APPEND
	CompGuide      string
	TitleGuide     string
	Temp           string
	TempInherited  string
	MaxTokens      string
	MaxPlaceholder string
	EffortOpts     []sbOpt
	EffortChanged  string // the label it changed from, while unsaved
	CacheOpts      []sbOpt
	SlotNote       string
	CallNote       string
	Dirty          int
	Error          string
}

var effortNames = []struct {
	Value, Label string
	Effort       psmithv1.ThinkingEffort
}{
	{"off", "Off", psmithv1.ThinkingEffort_THINKING_EFFORT_OFF},
	{"low", "Low", psmithv1.ThinkingEffort_THINKING_EFFORT_LOW},
	{"medium", "Medium", psmithv1.ThinkingEffort_THINKING_EFFORT_MEDIUM},
	{"high", "High", psmithv1.ThinkingEffort_THINKING_EFFORT_HIGH},
	{"xhigh", "Extra high", psmithv1.ThinkingEffort_THINKING_EFFORT_XHIGH},
}

func effortLabel(e psmithv1.ThinkingEffort) string {
	for _, n := range effortNames {
		if n.Effort == e {
			return n.Label
		}
	}
	return ""
}

// modelLayers is the call settings a model's provider and the model itself
// contribute, keyed by "providerID|modelID", with the names to credit them.
type modelLayer struct {
	Provider, Model         *psmithv1.CallSettings
	ProviderName, ModelName string
}

func (h *Handler) modelLayers(ctx context.Context) map[string]modelLayer {
	out := map[string]modelLayer{}
	if h.models == nil {
		return out
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		return out
	}
	for _, e := range resp.Msg.GetEntries() {
		out[modelValue(e.GetProvider().GetId(), e.GetModel().GetModelId())] = modelLayer{
			Provider:     e.GetProvider().GetDefaultSettings(),
			Model:        e.GetModel().GetDefaultSettings(),
			ProviderName: orName(e.GetProvider().GetLabel(), e.GetProvider().GetType()),
			ModelName:    orName(e.GetModel().GetDisplayName(), e.GetModel().GetModelId()),
		}
	}
	return out
}

// resolvedParent is the parent profile with its own chain applied, or nil.
func (h *Handler) resolvedParent(ctx context.Context, p *psmithv1.Profile) *psmithv1.Profile {
	if p.GetParentProfileId() == "" {
		return nil
	}
	resp, err := h.profiles.GetProfile(ctx, connect.NewRequest(&psmithv1.GetProfileRequest{Id: p.GetParentProfileId(), Resolve: true}))
	if err != nil {
		return nil
	}
	if r := resp.Msg.GetResolved(); r != nil {
		return r
	}
	return resp.Msg.GetProfile()
}

func profileModelRef(pid, mid string) string {
	if pid == "" || mid == "" {
		return ""
	}
	return modelValue(pid, mid)
}

func (h *Handler) handleProfileModels(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	h.render(w, r, http.StatusOK, profileModelsScreen(h.loadSnav(r.Context(), r, "profiles"), h.modelsVM(r.Context(), ix, p)))
}

func (h *Handler) modelsVM(ctx context.Context, ix profileIndex, p *psmithv1.Profile) profileModelsVM {
	groups := h.modelGroups(ctx)
	parent := h.resolvedParent(ctx, p)
	head := ix.head(p, "models")
	none := "Not set"
	inh := func(v string) string { return inheritLabel(modelName(groups, v), none) }

	d := p.GetDefaultSettings()
	own := profileModelRef(d.GetDefaultProviderId(), d.GetDefaultModelId())
	pd := parent.GetDefaultSettings()
	parentReply := profileModelRef(pd.GetDefaultProviderId(), pd.GetDefaultModelId())

	vm := profileModelsVM{
		Head:       head,
		ReplyOpts:  modelSelectOpts(groups, inh(parentReply), own),
		CompOpts:   modelSelectOpts(groups, inh(profileModelRef(parent.GetCompressionProviderId(), parent.GetCompressionModelId())), profileModelRef(p.GetCompressionProviderId(), p.GetCompressionModelId())),
		TitleOpts:  modelSelectOpts(groups, inh(profileModelRef(parent.GetTitleProviderId(), parent.GetTitleModelId())), profileModelRef(p.GetTitleProviderId(), p.GetTitleModelId())),
		CompGuide:  p.GetCompressionGuide(),
		TitleGuide: p.GetTitleGuide(),
	}
	switch p.GetCompressionMode() {
	case psmithv1.CompressionMode_COMPRESSION_MODE_REPLACE:
		vm.Mode = "REPLACE"
	case psmithv1.CompressionMode_COMPRESSION_MODE_APPEND:
		vm.Mode = "APPEND"
	}
	if head.ParentName != "" {
		vm.SlotNote = "Leave a slot on Inherit to use what " + head.ParentName + " picks. With no title model anywhere in the chain, auto-titling is off."
	} else {
		vm.SlotNote = "With no title model set, auto-titling is off."
	}
	vm.CallNote = "These apply to every conversation on " + p.GetName() + ". Blank fields inherit from the model, then the provider. A conversation can still override any of them."

	// What a blank call-settings field falls back to: the parent's resolved
	// settings over the effective model's, over its provider's.
	effModel := own
	if effModel == "" {
		effModel = parentReply
	}
	layer := h.modelLayers(ctx)[effModel]
	parentCS := orCS(pd.GetCallSettings())
	below := mergeCall(parentCS, mergeCall(layer.Model, layer.Provider))
	ownCS := orCS(d.GetCallSettings())
	modelCS, provCS := orCS(layer.Model), orCS(layer.Provider)

	if ownCS.Temperature != nil {
		vm.Temp = strconv.FormatFloat(ownCS.GetTemperature(), 'f', -1, 64)
	}
	if below.Temperature != nil {
		vm.TempInherited = strconv.FormatFloat(below.GetTemperature(), 'f', 1, 64)
	}
	if ownCS.MaxOutputTokens != nil {
		vm.MaxTokens = strconv.Itoa(int(ownCS.GetMaxOutputTokens()))
	}
	vm.MaxPlaceholder = "Model default"
	switch {
	case parentCS.MaxOutputTokens != nil:
		vm.MaxPlaceholder = thousands(int64(parentCS.GetMaxOutputTokens())) + " from " + head.ParentName
	case modelCS.MaxOutputTokens != nil:
		vm.MaxPlaceholder = thousands(int64(modelCS.GetMaxOutputTokens())) + " from " + layer.ModelName
	case provCS.MaxOutputTokens != nil:
		vm.MaxPlaceholder = thousands(int64(provCS.GetMaxOutputTokens())) + " from " + layer.ProviderName
	}

	inhEffort := effortLabel(below.GetThinking().GetEffort())
	ownEffort := ownCS.GetThinking().GetEffort()
	vm.EffortOpts = []sbOpt{{Value: "", Label: inheritLabel(inhEffort, "Inherit"), Selected: ownEffort == psmithv1.ThinkingEffort_THINKING_EFFORT_UNSPECIFIED}}
	for _, n := range effortNames {
		vm.EffortOpts = append(vm.EffortOpts, sbOpt{Value: n.Value, Label: n.Label, Selected: n.Effort == ownEffort})
	}
	inhCache := ""
	if below.ExplicitCache != nil {
		inhCache = map[bool]string{true: "On", false: "Off"}[below.GetExplicitCache()]
	}
	vm.CacheOpts = []sbOpt{
		{Value: "", Label: inheritLabel(inhCache, "Inherit"), Selected: ownCS.ExplicitCache == nil},
		{Value: "on", Label: "On", Selected: ownCS.ExplicitCache != nil && ownCS.GetExplicitCache()},
		{Value: "off", Label: "Off", Selected: ownCS.ExplicitCache != nil && !ownCS.GetExplicitCache()},
	}
	return vm
}

func (h *Handler) handleProfileModelsSave(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	req, err := modelsUpdate(p, r.PostFormValue)
	if err == nil {
		_, err = h.profiles.UpdateProfile(r.Context(), connect.NewRequest(req))
	}
	if err != nil {
		vm := postedModels(h.modelsVM(r.Context(), ix, p), r.PostFormValue)
		vm.Error = errMessage(err)
		h.showAfterPost(w, r, "/settings/profiles/"+p.GetId()+"/models", profileModelsScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+p.GetId()+"/models", http.StatusSeeOther)
}

func orCS(cs *psmithv1.CallSettings) *psmithv1.CallSettings {
	if cs == nil {
		return &psmithv1.CallSettings{}
	}
	return cs
}

type formError string

func (e formError) Error() string { return string(e) }

// modelsUpdate turns the Models tab's fields into an update. The default
// settings blob is rewritten from the stored one, so knobs this page
// doesn't show (top-p, stop sequences, provider extras) survive.
func modelsUpdate(p *psmithv1.Profile, get func(string) string) (*psmithv1.UpdateProfileRequest, error) {
	req := &psmithv1.UpdateProfileRequest{Id: p.GetId()}
	var clear []string

	defaults := &psmithv1.ProfileDefaults{}
	if d := p.GetDefaultSettings(); d != nil {
		defaults = proto.Clone(d).(*psmithv1.ProfileDefaults)
	}
	if pid, mid, ok := splitModelValue(get("reply_model")); ok {
		defaults.DefaultProviderId, defaults.DefaultModelId = &pid, &mid
	} else {
		defaults.DefaultProviderId, defaults.DefaultModelId = nil, nil
	}
	cs := defaults.GetCallSettings()
	if cs == nil {
		cs = &psmithv1.CallSettings{}
	}
	if v := strings.TrimSpace(get("temperature")); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 2 {
			return nil, formError("Temperature is a number from 0 to 2.")
		}
		cs.Temperature = &f
	} else {
		cs.Temperature = nil
	}
	if v := strings.ReplaceAll(strings.TrimSpace(get("max_output_tokens")), ",", ""); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return nil, formError("Max output tokens is a whole number above 0.")
		}
		n32 := int32(n)
		cs.MaxOutputTokens = &n32
	} else {
		cs.MaxOutputTokens = nil
	}
	cs.Thinking = nil
	for _, n := range effortNames {
		if get("thinking_effort") == n.Value {
			cs.Thinking = &psmithv1.ThinkingSettings{Effort: n.Effort}
		}
	}
	switch get("prompt_caching") {
	case "on":
		cs.ExplicitCache = proto.Bool(true)
	case "off":
		cs.ExplicitCache = proto.Bool(false)
	default:
		cs.ExplicitCache = nil
	}
	defaults.CallSettings = cs
	req.DefaultSettings = defaults

	if pid, mid, ok := splitModelValue(get("compression_model")); ok {
		req.CompressionProviderId, req.CompressionModelId = &pid, &mid
	} else {
		clear = append(clear, "compression_provider_id", "compression_model_id")
	}
	if g := strings.TrimSpace(get("compression_guide")); g != "" {
		req.CompressionGuide = &g
	} else {
		clear = append(clear, "compression_guide")
	}
	switch get("compression_mode") {
	case "REPLACE":
		m := psmithv1.CompressionMode_COMPRESSION_MODE_REPLACE
		req.CompressionMode = &m
	case "APPEND":
		m := psmithv1.CompressionMode_COMPRESSION_MODE_APPEND
		req.CompressionMode = &m
	default:
		clear = append(clear, "compression_mode")
	}
	if pid, mid, ok := splitModelValue(get("title_model")); ok {
		req.TitleProviderId, req.TitleModelId = &pid, &mid
	} else {
		clear = append(clear, "title_provider_id", "title_model_id")
	}
	if g := strings.TrimSpace(get("title_guide")); g != "" {
		req.TitleGuide = &g
	} else {
		clear = append(clear, "title_guide")
	}
	req.ClearFields = clear
	return req, nil
}

// postedModels puts what was posted back on the Models tab after a refused
// save, with the save bar up, so nothing typed is lost.
func postedModels(vm profileModelsVM, get func(string) string) profileModelsVM {
	n := 0
	pick := func(opts []sbOpt, v string) []sbOpt {
		if selectedValue(opts) != v {
			n++
		}
		out := make([]sbOpt, len(opts))
		for i, o := range opts {
			o.Selected = o.Group == "" && o.Value == v
			if o.Group != "" {
				items := make([]sbOpt, len(o.Items))
				for j, it := range o.Items {
					it.Selected = it.Value == v
					items[j] = it
				}
				o.Items = items
			}
			out[i] = o
		}
		return out
	}
	text := func(cur *string, v string) {
		if *cur != v {
			n++
		}
		*cur = v
	}
	vm.ReplyOpts = pick(vm.ReplyOpts, get("reply_model"))
	vm.CompOpts = pick(vm.CompOpts, get("compression_model"))
	vm.TitleOpts = pick(vm.TitleOpts, get("title_model"))
	vm.EffortOpts = pick(vm.EffortOpts, get("thinking_effort"))
	vm.CacheOpts = pick(vm.CacheOpts, get("prompt_caching"))
	text(&vm.Mode, get("compression_mode"))
	text(&vm.CompGuide, get("compression_guide"))
	text(&vm.TitleGuide, get("title_guide"))
	text(&vm.Temp, get("temperature"))
	text(&vm.MaxTokens, get("max_output_tokens"))
	vm.Dirty = max(n, 1)
	return vm
}
