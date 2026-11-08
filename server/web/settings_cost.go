package web

import (
	"fmt"
	"math"
	"net/http"
	"strconv"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func saCommas(s string) string {
	whole, frac := s, ""
	for i := range s {
		if s[i] == '.' {
			whole, frac = s[:i], s[i:]
			break
		}
	}
	n, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return s
	}
	return saGroupInt(n) + frac
}

// usageWindow resolves a range choice to the half-open window the cost
// ledger takes and the line that names it.
func usageWindow(now time.Time, rng, from, to string) (since, until *time.Time, label string) {
	day := func(t time.Time) time.Time { return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location()) }
	span := func(a, b time.Time) string {
		switch {
		case a.Year() != b.Year():
			return a.Format("January 2, 2006") + " to " + b.Format("January 2, 2006")
		case a.Month() != b.Month():
			return a.Format("January 2") + " to " + b.Format("January 2, 2006")
		case a.Day() == b.Day():
			return a.Format("January 2, 2006")
		}
		return a.Format("January 2") + " to " + b.Format("2, 2006")
	}
	switch rng {
	case "30d":
		s := day(now).AddDate(0, 0, -29)
		return &s, nil, span(s, now)
	case "custom":
		var label string
		f, ferr := time.ParseInLocation("2006-01-02", from, now.Location())
		t, terr := time.ParseInLocation("2006-01-02", to, now.Location())
		if ferr == nil {
			since = &f
		}
		if terr == nil {
			u := t.AddDate(0, 0, 1)
			until = &u
		}
		switch {
		case ferr == nil && terr == nil:
			label = span(f, t)
		case ferr == nil:
			label = "Since " + f.Format("January 2, 2006")
		case terr == nil:
			label = "Through " + t.Format("January 2, 2006")
		default:
			label = "All time"
		}
		return since, until, label
	default:
		s := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
		return &s, nil, span(s, now)
	}
}

func (h *Handler) handleCost(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	u := spendVM{Range: q.Get("range"), From: q.Get("from"), To: q.Get("to")}
	if u.Range != "30d" && u.Range != "custom" {
		u.Range = "month"
	}
	since, until, label := usageWindow(time.Now(), u.Range, u.From, u.To)
	u.Period = label
	req := &psmithv1.ListProviderCostsRequest{}
	if since != nil {
		req.Since = timestamppb.New(*since)
	}
	if until != nil {
		req.Until = timestamppb.New(*until)
	}
	resp, err := h.models.ListProviderCosts(r.Context(), connect.NewRequest(req))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	types := h.providerTypeNames(r)
	var turns int64
	for _, p := range resp.Msg.GetProviders() {
		row := spendRowVM{ID: p.GetProviderId(), Name: p.GetProviderLabel(), Type: orDefault(types[p.GetProviderType()], p.GetProviderType()),
			Turns: saGroupInt(p.GetEventCount()), Spend: saMoney(p.GetTotalCostUsd())}
		if p.GetEventCount() == 0 {
			row.Turns, row.None = "No events", true
		}
		turns += p.GetEventCount()
		u.Rows = append(u.Rows, row)
	}
	u.Total = saMoney(resp.Msg.GetGrandTotalUsd())
	u.TotalTurns = saGroupInt(turns)
	u.Turns = saGroupInt(turns) + " " + saPlural(int(turns), "turn", "turns")
	h.render(w, r, http.StatusOK, spendScreen(h.loadSnav(r.Context(), r, "usage"), u))
}

// providerTypeNames maps driver type names to their display names.
func (h *Handler) providerTypeNames(r *http.Request) map[string]string {
	out := map[string]string{}
	resp, err := h.models.ListProviderTypes(r.Context(), connect.NewRequest(&psmithv1.ListProviderTypesRequest{}))
	if err != nil {
		return out
	}
	for _, t := range resp.Msg.GetTypes() {
		out[t.GetName()] = t.GetDisplayName()
	}
	return out
}

// saMoney renders dollars to the cent, or to the first significant digit below
// a cent so a few tokens of spend don't read as nothing.
func saMoney(f float64) string {
	switch {
	case f <= 0:
		return "$0.00"
	case f < 0.01:
		digits := int(math.Ceil(-math.Log10(f)))
		return "$" + strconv.FormatFloat(f, 'f', digits, 64)
	default:
		return "$" + saCommas(fmt.Sprintf("%.2f", f))
	}
}
