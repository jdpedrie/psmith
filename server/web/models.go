package web

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// --- rich model picker ---

// capsVM is the subset of model capabilities the picker surfaces as badges.
type capsVM struct {
	Thinking      bool
	Vision        bool
	ToolUse       bool
	PromptCaching bool
}

// pickerModelVM is one selectable model row, carrying the metadata strip the
// iOS picker shows (context window, cost bucket, knowledge cutoff, capability
// badges) plus its selected/disabled state.
type pickerModelVM struct {
	ProviderID  string
	ModelID     string
	Value       string // "providerID|modelID"
	DisplayName string
	Selected    bool

	ContextLabel string // e.g. "200K", "1M"
	CostBucket   string // "$" … "$$$$"
	CostHint     string // tooltip with the actual prices
	Cutoff       string
	Caps         capsVM

	ContextWindow int32
	Favorite      bool

	Disabled bool     // lacks a capability the active pipeline requires
	Missing  []string // human labels of the missing capabilities
}

// providerGroupVM groups a provider's models under its label, the way the iOS
// picker sections them.
type providerGroupVM struct {
	ProviderID string
	Label      string
	Type       string
	Models     []pickerModelVM
}

// pickerData bundles everything the model picker view needs.
type pickerData struct {
	ConvID  string
	Groups  []providerGroupVM
	Total   int
	Current pickerModelVM // the currently-selected model (for the chip)
	// Why the list is shorter than the account's full set. Rendered above the
	// groups so a missing provider reads as a rule rather than a bug.
	Notice string
}

// ProviderLabel names a provider in the picker's groups.
func (d pickerData) ProviderLabel(id string) string {
	for _, g := range d.Groups {
		if g.ProviderID == id {
			return g.Label
		}
	}
	return ""
}

// modelPicker builds the grouped, metadata-rich model list for a conversation,
// marking the selected model and disabling any that lack a capability in
// required. Pass a zero capsVM when only the current chip is needed (the
// conversation page), to skip pipeline resolution.
func (h *Handler) modelPicker(ctx context.Context, convID, selected string, required capsVM, harness *harnessVM) pickerData {
	data := pickerData{ConvID: convID}
	if h.models == nil {
		return data
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		h.logger.Warn("web: list models failed", "err", err)
		return data
	}

	byProvider := map[string]*providerGroupVM{}
	var order []string
	for _, e := range resp.Msg.GetEntries() {
		prov, m := e.GetProvider(), e.GetModel()
		pid := prov.GetId()
		// A bound conversation can change model but not provider. Filtering
		// rather than disabling: a whole provider's worth of dead rows is
		// noise, where one absent section plus the notice reads as a rule.
		if harness != nil && pid != harness.ProviderID {
			continue
		}
		g, ok := byProvider[pid]
		if !ok {
			label := prov.GetLabel()
			if label == "" {
				label = prov.GetType()
			}
			g = &providerGroupVM{ProviderID: pid, Label: label, Type: prov.GetType()}
			byProvider[pid] = g
			order = append(order, pid)
		}
		vm := modelRowVM(pid, m, selected, required)
		g.Models = append(g.Models, vm)
		data.Total++
		if vm.Selected {
			data.Current = vm
		}
	}

	sort.Slice(order, func(i, j int) bool {
		return byProvider[order[i]].Label < byProvider[order[j]].Label
	})
	for _, pid := range order {
		g := byProvider[pid]
		sort.Slice(g.Models, func(i, j int) bool { return g.Models[i].DisplayName < g.Models[j].DisplayName })
		data.Groups = append(data.Groups, *g)
	}

	if harness != nil {
		data.Notice = harness.ProviderLabel + " holds this conversation's transcript, so it stays on this provider."
	}

	// No stored selection yet: default to the first model so the chip isn't blank.
	if data.Current.Value == "" && len(data.Groups) > 0 && len(data.Groups[0].Models) > 0 {
		data.Current = data.Groups[0].Models[0]
	}
	return data
}

func modelRowVM(providerID string, m *psmithv1.UserModel, selected string, required capsVM) pickerModelVM {
	name := m.GetDisplayName()
	if name == "" {
		name = m.GetModelId()
	}
	vm := pickerModelVM{
		ProviderID:    providerID,
		ModelID:       m.GetModelId(),
		Value:         modelValue(providerID, m.GetModelId()),
		DisplayName:   name,
		Cutoff:        m.GetKnowledgeCutoff(),
		ContextWindow: m.GetContextWindow(),
		Favorite:      m.GetFavorite(),
	}
	vm.Selected = vm.Value == selected
	if m.ContextWindow != nil {
		vm.ContextLabel = abbrevTokens(m.GetContextWindow())
	}
	if c := m.GetCapabilities(); c != nil {
		vm.Caps = capsVM{Thinking: c.GetThinking(), Vision: c.GetVision(), ToolUse: c.GetToolUse(), PromptCaching: c.GetPromptCaching()}
	}
	if p := m.GetPricing(); p != nil {
		vm.CostBucket, vm.CostHint = costBucket(p)
	}
	vm.Missing = missingCaps(m.GetCapabilities(), required)
	vm.Disabled = len(vm.Missing) > 0
	return vm
}

// requiredCaps reports the capability floor a model must meet for the
// conversation: the resolved profile's RequiredModelCapabilities (the server
// rolls the pipeline's requirements into that field, same source iOS reads).
func (h *Handler) requiredCaps(ctx context.Context, convID string) capsVM {
	var req capsVM
	if h.convos == nil || h.profiles == nil {
		return req
	}
	conv, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return req
	}
	prof, err := h.profiles.GetProfile(ctx, connect.NewRequest(&psmithv1.GetProfileRequest{
		Id: conv.Msg.GetConversation().GetProfileId(), Resolve: true,
	}))
	if err != nil {
		return req
	}
	if c := prof.Msg.GetProfile().GetRequiredModelCapabilities(); c != nil {
		req = capsVM{Thinking: c.GetThinking(), Vision: c.GetVision(), ToolUse: c.GetToolUse(), PromptCaching: c.GetPromptCaching()}
	}
	return req
}

func missingCaps(have *psmithv1.ModelCapabilities, required capsVM) []string {
	var missing []string
	if required.Thinking && !have.GetThinking() {
		missing = append(missing, "thinking")
	}
	if required.Vision && !have.GetVision() {
		missing = append(missing, "vision")
	}
	if required.ToolUse && !have.GetToolUse() {
		missing = append(missing, "tool use")
	}
	if required.PromptCaching && !have.GetPromptCaching() {
		missing = append(missing, "prompt caching")
	}
	return missing
}

// abbrevTokens renders a token count as K/M, matching the iOS strip ("200K").
func abbrevTokens(n int32) string {
	switch {
	case n >= 1_000_000:
		v := float64(n) / 1_000_000
		if v == float64(int(v)) {
			return fmt.Sprintf("%dM", int(v))
		}
		return fmt.Sprintf("%.1fM", v)
	case n >= 1_000:
		return fmt.Sprintf("%dk", n/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

// costBucket maps output price/M to a $-bucket, with a tooltip carrying the
// real input/output prices. Same intent as the iOS cost chip.
func costBucket(p *psmithv1.ModelPricing) (bucket, hint string) {
	out := p.GetOutputPerMillionTokens()
	if out <= 0 {
		return "", ""
	}
	switch {
	case out < 2:
		bucket = "$"
	case out < 10:
		bucket = "$$"
	case out < 30:
		bucket = "$$$"
	default:
		bucket = "$$$$"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "$%.2f in / $%.2f out per 1M tokens", p.GetInputPerMillionTokens(), out)
	return bucket, b.String()
}

// pickerVM is the model picker in the inspector.
type pickerVM struct {
	ConvID       string
	Query        string
	ProfileModel string // "Demo uses Claude Opus 4.7"
	UsingProfile bool   // the conversation sets no model of its own
	// NoProfileModel: the profile names no model, so "Use the profile's
	// model" has nothing to use and the next send runs on the model the
	// header shows.
	NoProfileModel bool
	Favorites      []pickerModelVM
	Groups         []providerGroupVM
	Notice         string
	Foot           string
}

// badges are a model's capability chips, in the order the picker shows them.
func badges(c capsVM) []string {
	var out []string
	if c.Vision {
		out = append(out, "Vision")
	}
	if c.ToolUse {
		out = append(out, "Tools")
	}
	if c.Thinking {
		out = append(out, "Thinking")
	}
	return out
}

// metaLine is "200k · $$$", or whichever half is known.
func metaLine(m pickerModelVM) string {
	var parts []string
	if m.ContextLabel != "" {
		parts = append(parts, m.ContextLabel)
	}
	if m.CostBucket != "" {
		parts = append(parts, m.CostBucket)
	}
	return strings.Join(parts, " · ")
}

// needs is a disabled model's reason: "Needs tool use".
func needs(missing []string) string {
	return "Needs " + strings.Join(missing, " and ")
}

// buildPicker filters and arranges the picker's rows.
func buildPicker(data pickerData, q string, req capsVM, profile string) *pickerVM {
	vm := &pickerVM{ConvID: data.ConvID, Query: q, Notice: data.Notice}
	q = strings.ToLower(strings.TrimSpace(q))
	match := func(g providerGroupVM, m pickerModelVM) bool {
		return q == "" || strings.Contains(strings.ToLower(m.DisplayName+" "+m.ModelID+" "+g.Label), q)
	}
	for _, g := range data.Groups {
		grp := g
		grp.Models = nil
		for _, m := range g.Models {
			if !match(g, m) {
				continue
			}
			grp.Models = append(grp.Models, m)
			if m.Favorite {
				vm.Favorites = append(vm.Favorites, m)
			}
		}
		if len(grp.Models) > 0 {
			vm.Groups = append(vm.Groups, grp)
		}
	}
	var need []string
	if req.ToolUse {
		need = append(need, "tool use")
	}
	if req.Vision {
		need = append(need, "vision")
	}
	if req.Thinking {
		need = append(need, "thinking")
	}
	if req.PromptCaching {
		need = append(need, "prompt caching")
	}
	vm.Foot = "Applies from the next message."
	if len(need) > 0 {
		vm.Foot += " " + profile + " needs " + strings.Join(need, " and ") + ", so models without it are off."
	}
	return vm
}

// handleModelPicker opens the picker in the inspector.
func (h *Handler) handleModelPicker(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	conv := getResp.Msg.GetConversation()
	req := h.requiredCaps(r.Context(), convID)
	data := h.modelPicker(r.Context(), convID, vm.Model.Value, req, harnessVMFrom(conv.GetHarness()))
	p := buildPicker(data, r.URL.Query().Get("q"), req, vm.Profile)
	p.UsingProfile = currentSettingsModel(conv) == ""
	if d := h.resolvedProfile(r.Context(), conv.GetProfileId()).GetDefaultSettings(); d.GetDefaultProviderId() != "" {
		p.ProfileModel = vm.Profile + " uses " + h.modelName(r.Context(), d.GetDefaultProviderId(), d.GetDefaultModelId())
	} else {
		p.ProfileModel = vm.Profile + " sets no model"
		p.NoProfileModel, p.UsingProfile = true, false
	}
	vm.Inspector.View, vm.Inspector.Picker, vm.ShowInsp, vm.Inspector.Page = "model", p, true, true
	h.renderConversation(w, r, vm)
}

// handleSetModel sets the conversation's model; an empty value goes back to
// the profile's.
func (h *Handler) handleSetModel(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	value := r.FormValue("model")
	if value == "" {
		h.clearConversationModel(r.Context(), convID)
	} else if pid, mid, ok := splitModelValue(value); ok {
		h.setConversationModel(r.Context(), convID, pid, mid)
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// clearConversationModel drops the conversation's own model so the
// profile's applies again.
func (h *Handler) clearConversationModel(ctx context.Context, convID string) {
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		return
	}
	settings.DefaultProviderId, settings.DefaultModelId = nil, nil
	if _, err := h.convos.UpdateConversation(ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{Id: convID, Settings: settings})); err != nil {
		h.logger.Warn("web: clear model failed", "err", err)
	}
}

// setConversationModel writes the default provider/model onto the conversation,
// preserving other settings. Best-effort.
func (h *Handler) setConversationModel(ctx context.Context, convID, providerID, modelID string) {
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &psmithv1.ConversationSettings{}
	}
	settings.DefaultProviderId = &providerID
	settings.DefaultModelId = &modelID
	if _, err := h.convos.UpdateConversation(ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id:       convID,
		Settings: settings,
	})); err != nil {
		h.logger.Warn("web: set model failed", "err", err)
	}
}

// currentSettingsModel returns the conversation's stored model value, or "".
func currentSettingsModel(conv *psmithv1.Conversation) string {
	if s := conv.GetSettings(); s != nil && s.GetDefaultProviderId() != "" && s.GetDefaultModelId() != "" {
		return modelValue(s.GetDefaultProviderId(), s.GetDefaultModelId())
	}
	return ""
}
