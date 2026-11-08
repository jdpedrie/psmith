package web

import (
	"context"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// welcomeVM is the start page: a card per profile and the latest
// conversations. First is an account with no conversations yet.
type welcomeVM struct {
	First    bool
	Profiles []profileCardVM
	Recent   []rowVM
}

// profileCardVM is a profile as a card: name, description and the model a
// new conversation would start on.
type profileCardVM struct {
	ID         string
	Name       string
	Desc       string
	Color      int
	Model      string // "Claude Opus 4.7 · Anthropic"
	ModelValue string // "providerID|modelID", "" when the profile names none
	Default    bool
}

// modelInfo is an enabled model's display name and provider label.
type modelInfo struct {
	Name, Provider string
}

// enabledModels maps "providerID|modelID" to names for every model the
// caller has turned on, in the server's order.
func (h *Handler) enabledModels(ctx context.Context) ([]string, map[string]modelInfo) {
	out := map[string]modelInfo{}
	var order []string
	if h.models == nil {
		return order, out
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		h.logger.Warn("web: list models failed", "err", err)
		return order, out
	}
	for _, e := range resp.Msg.GetEntries() {
		v := modelValue(e.GetProvider().GetId(), e.GetModel().GetModelId())
		name := e.GetModel().GetDisplayName()
		if name == "" {
			name = e.GetModel().GetModelId()
		}
		out[v] = modelInfo{Name: name, Provider: e.GetProvider().GetLabel()}
		order = append(order, v)
	}
	return order, out
}

// profileCards turns the chat profiles into cards. The model is the
// profile's own default, or its parent's when it inherits one.
func (h *Handler) profileCards(ctx context.Context, idx profileIdx, models map[string]modelInfo) []profileCardVM {
	out := make([]profileCardVM, 0, len(idx.order))
	for _, p := range idx.order {
		card := profileCardVM{ID: p.GetId(), Name: p.GetName(), Desc: p.GetDescription(), Color: profileColor(p.GetId()), Default: p.GetIsDefault()}
		if v := profileModel(idx, p); v != "" {
			card.ModelValue = v
			if m, ok := models[v]; ok {
				card.Model = m.Name
				if m.Provider != "" {
					card.Model += " · " + m.Provider
				}
			}
		}
		out = append(out, card)
	}
	return out
}

// profileModel walks the parent chain for the first default model.
func profileModel(idx profileIdx, p *psmithv1.Profile) string {
	seen := map[string]bool{}
	for p != nil && !seen[p.GetId()] {
		seen[p.GetId()] = true
		d := p.GetDefaultSettings()
		if d.GetDefaultProviderId() != "" && d.GetDefaultModelId() != "" {
			return modelValue(d.GetDefaultProviderId(), d.GetDefaultModelId())
		}
		p = idx.byID[p.GetParentProfileId()]
	}
	return ""
}

// loadWelcome builds the start page beside the list l.
func (h *Handler) loadWelcome(ctx context.Context, l listVM) welcomeVM {
	_, models := h.enabledModels(ctx)
	w := welcomeVM{First: l.Empty, Profiles: h.profileCards(ctx, h.profileIndex(ctx), models)}
	for _, r := range l.Rows {
		if len(w.Recent) == 4 {
			break
		}
		if !r.Pinned {
			w.Recent = append(w.Recent, r)
		}
	}
	return w
}
