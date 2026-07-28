package web

import (
	"fmt"
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

type costRowVM struct {
	Label  string
	Type   string
	Total  string
	Events int64
}

func usd(f float64) string { return fmt.Sprintf("$%.4f", f) }

func (h *Handler) handleCost(w http.ResponseWriter, r *http.Request) {
	resp, err := h.models.ListProviderCosts(r.Context(), connect.NewRequest(&psmithv1.ListProviderCostsRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var rows []costRowVM
	for _, p := range resp.Msg.GetProviders() {
		rows = append(rows, costRowVM{
			Label:  p.GetProviderLabel(),
			Type:   p.GetProviderType(),
			Total:  usd(p.GetTotalCostUsd()),
			Events: p.GetEventCount(),
		})
	}
	h.render(w, r, http.StatusOK, costPage(rows, usd(resp.Msg.GetGrandTotalUsd())))
}
