package web

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
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
}

// modelPicker builds the grouped, metadata-rich model list for a conversation,
// marking the selected model and disabling any that lack a capability in
// required. Pass a zero capsVM when only the current chip is needed (the
// conversation page), to skip pipeline resolution.
func (h *Handler) modelPicker(ctx context.Context, convID, selected string, required capsVM) pickerData {
	data := pickerData{ConvID: convID}
	if h.models == nil {
		return data
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&spaltv1.ListAllUserModelsRequest{}))
	if err != nil {
		h.logger.Warn("web: list models failed", "err", err)
		return data
	}

	byProvider := map[string]*providerGroupVM{}
	var order []string
	for _, e := range resp.Msg.GetEntries() {
		prov, m := e.GetProvider(), e.GetModel()
		pid := prov.GetId()
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

	// No stored selection yet: default to the first model so the chip isn't blank.
	if data.Current.Value == "" && len(data.Groups) > 0 && len(data.Groups[0].Models) > 0 {
		data.Current = data.Groups[0].Models[0]
	}
	return data
}

func modelRowVM(providerID string, m *spaltv1.UserModel, selected string, required capsVM) pickerModelVM {
	name := m.GetDisplayName()
	if name == "" {
		name = m.GetModelId()
	}
	vm := pickerModelVM{
		ProviderID:  providerID,
		ModelID:     m.GetModelId(),
		Value:       modelValue(providerID, m.GetModelId()),
		DisplayName: name,
		Cutoff:      m.GetKnowledgeCutoff(),
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
	conv, err := h.convos.GetConversation(ctx, connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return req
	}
	prof, err := h.profiles.GetProfile(ctx, connect.NewRequest(&spaltv1.GetProfileRequest{
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

func missingCaps(have *spaltv1.ModelCapabilities, required capsVM) []string {
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
		return fmt.Sprintf("%dK", n/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

// costBucket maps output price/M to a $-bucket, with a tooltip carrying the
// real input/output prices. Same intent as the iOS cost chip.
func costBucket(p *spaltv1.ModelPricing) (bucket, hint string) {
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

// handleModelPicker renders the rich picker. For htmx it returns the overlay
// fragment; without JS it renders a standalone page.
func (h *Handler) handleModelPicker(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	selected := currentSettingsModel(getResp.Msg.GetConversation())
	data := h.modelPicker(r.Context(), convID, selected, h.requiredCaps(r.Context(), convID))

	if r.Header.Get("HX-Request") != "" {
		h.render(w, r, http.StatusOK, modelPickerModal(data))
		return
	}
	h.render(w, r, http.StatusOK, modelPickerPage(data))
}

// handleSetModel records the chosen model as the conversation default. For htmx
// it returns the refreshed composer model chip plus an out-of-band swap that
// dismisses the picker overlay; without JS it redirects back to the chat.
func (h *Handler) handleSetModel(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	value := r.FormValue("model")
	if pid, mid, ok := splitModelValue(value); ok {
		h.setConversationModel(r.Context(), convID, pid, mid)
	}

	if r.Header.Get("HX-Request") != "" {
		data := h.modelPicker(r.Context(), convID, value, capsVM{})
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		// The chip swaps in place; the empty #modal OOB swap closes the overlay.
		_, _ = w.Write([]byte(renderComp(r.Context(), modelChip(data.ConvID, data.Current))))
		_, _ = w.Write([]byte(`<div id="modal" hx-swap-oob="innerHTML"></div>`))
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// setConversationModel writes the default provider/model onto the conversation,
// preserving other settings. Best-effort.
func (h *Handler) setConversationModel(ctx context.Context, convID, providerID, modelID string) {
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &spaltv1.ConversationSettings{}
	}
	settings.DefaultProviderId = &providerID
	settings.DefaultModelId = &modelID
	if _, err := h.convos.UpdateConversation(ctx, connect.NewRequest(&spaltv1.UpdateConversationRequest{
		Id:       convID,
		Settings: settings,
	})); err != nil {
		h.logger.Warn("web: set model failed", "err", err)
	}
}

// currentSettingsModel returns the conversation's stored model value, or "".
func currentSettingsModel(conv *spaltv1.Conversation) string {
	if s := conv.GetSettings(); s != nil && s.GetDefaultProviderId() != "" && s.GetDefaultModelId() != "" {
		return modelValue(s.GetDefaultProviderId(), s.GetDefaultModelId())
	}
	return ""
}
