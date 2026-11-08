package web

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// sbOpt is one select option, or an optgroup when Group is set.
type sbOpt struct {
	Value, Label string
	Selected     bool
	Group        string
	Items        []sbOpt
}

// sbConfirmVM drives sbConfirm. ID names the swapped element; OpenHref and
// CancelHref are full-page fallbacks that also answer ?fragment=<ID>.
type sbConfirmVM struct {
	ID          string
	Open        bool
	Label       string
	LabelDetail string
	Question    string
	Detail      string
	Verb        string
	OpenHref    string
	CancelHref  string
	Action      string
	// InForm renders the open state's button as a formaction on the page's
	// own form, since a form can't nest in another.
	InForm bool
}

func selectedValue(opts []sbOpt) string {
	for _, o := range opts {
		if o.Selected {
			return o.Value
		}
		for _, g := range o.Items {
			if g.Selected {
				return g.Value
			}
		}
	}
	return ""
}

func sbSep(href string) string {
	if strings.Contains(href, "?") {
		return "&"
	}
	return "?"
}

// fragmentFor reports whether the request asks for just the element id, the
// way the in-place confirms fetch their open and closed states.
func fragmentFor(r *http.Request, id string) bool {
	return r.URL.Query().Get("fragment") == id
}

// modelGroups is the caller's enabled models grouped by provider, in the
// order ListAllUserModels returns them, for the profile model selects.
type modelGroup struct {
	Provider string
	Models   []modelVM
}

func (h *Handler) modelGroups(ctx context.Context) []modelGroup {
	if h.models == nil {
		return nil
	}
	resp, err := h.models.ListAllUserModels(ctx, connect.NewRequest(&psmithv1.ListAllUserModelsRequest{}))
	if err != nil {
		h.logger.Warn("web: list models failed", "err", err)
		return nil
	}
	var out []modelGroup
	idx := map[string]int{}
	for _, e := range resp.Msg.GetEntries() {
		pid := e.GetProvider().GetId()
		i, ok := idx[pid]
		if !ok {
			i = len(out)
			idx[pid] = i
			out = append(out, modelGroup{Provider: orName(e.GetProvider().GetLabel(), e.GetProvider().GetType())})
		}
		out[i].Models = append(out[i].Models, modelVM{
			Value: modelValue(pid, e.GetModel().GetModelId()),
			Label: orName(e.GetModel().GetDisplayName(), e.GetModel().GetModelId()),
		})
	}
	return out
}

// modelName finds a model's display name in groups, falling back to its id.
func modelName(groups []modelGroup, value string) string {
	if value == "" {
		return ""
	}
	for _, g := range groups {
		for _, m := range g.Models {
			if m.Value == value {
				return m.Label
			}
		}
	}
	if _, mid, ok := splitModelValue(value); ok {
		return mid
	}
	return value
}

// modelSelectOpts builds a model select: an inherit option first, then the
// models grouped by provider, with value selected.
func modelSelectOpts(groups []modelGroup, inheritLabel, value string) []sbOpt {
	opts := []sbOpt{{Value: "", Label: inheritLabel, Selected: value == ""}}
	found := value == ""
	for _, g := range groups {
		grp := sbOpt{Group: g.Provider}
		for _, m := range g.Models {
			sel := m.Value == value
			found = found || sel
			grp.Items = append(grp.Items, sbOpt{Value: m.Value, Label: m.Label, Selected: sel})
		}
		opts = append(opts, grp)
	}
	if !found {
		// A stored model that is no longer enabled still shows, so saving the
		// page doesn't silently drop it.
		opts = append(opts, sbOpt{Value: value, Label: modelName(groups, value), Selected: true})
	}
	return opts
}

// inheritLabel words an Inherit option: "Inherit (Claude Haiku 4.5)", or
// fallback when nothing below sets the value.
func inheritLabel(resolved, fallback string) string {
	if resolved == "" {
		return fallback
	}
	return "Inherit (" + resolved + ")"
}

// agoLabel is "4 min ago · 10:42" for a recent instant.
func agoLabel(now, t time.Time) string {
	d := now.Sub(t)
	var ago string
	switch {
	case d < time.Minute:
		ago = "just now"
	case d < time.Hour:
		ago = strconv.Itoa(int(d.Minutes())) + " min ago"
	case d < 24*time.Hour:
		ago = strconv.Itoa(int(d.Hours())) + " h ago"
	default:
		return t.Format("Jan 2, 15:04")
	}
	return ago + " · " + t.Format("15:04")
}

// thousands formats n with comma separators.
func thousands(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	if neg {
		return "-" + s
	}
	return s
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
