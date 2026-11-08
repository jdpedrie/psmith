package web

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
)

// panelVM is a plugin's panel in the inspector. The body is the plugin's
// fragments, drawn by component, never by plugin.
type panelVM struct {
	ConvID   string
	Plugin   string
	Title    string
	Subtitle string
	Parts    []panelPartVM
	Error    string
}

// panelPartVM is one fragment the web draws: text, a card list, or (for a
// component it doesn't know) the props as JSON.
type panelPartVM struct {
	Kind  string // text, cards, raw
	HTML  string
	Cards []panelCardVM
}

// panelCardVM is one card. A card with an action is a button; one with
// badges and an action reads as chosen (the plugin offers to undo it).
type panelCardVM struct {
	Title       string
	Description string
	Badges      []string
	Action      string // the plugin action, without the scheme
	Params      map[string]string
	External    string // external:<url> or the card's url
	Chosen      bool
}

// panelParts turns fragments into what the template draws.
func panelParts(frags []*psmithv1.UIFragment) []panelPartVM {
	var out []panelPartVM
	for _, f := range frags {
		switch f.GetComponent() {
		case "text":
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(f.GetProps(), &p)
			out = append(out, panelPartVM{Kind: "text", HTML: renderMarkdown(p.Text)})
		case "card_list":
			var p struct {
				Items []struct {
					Title       string   `json:"title"`
					Description string   `json:"description"`
					Badges      []string `json:"badges"`
					Action      string   `json:"action"`
					URL         string   `json:"url"`
				} `json:"items"`
			}
			_ = json.Unmarshal(f.GetProps(), &p)
			part := panelPartVM{Kind: "cards"}
			for _, it := range p.Items {
				c := panelCardVM{Title: it.Title, Description: it.Description, Badges: it.Badges, External: it.URL}
				if a, params, ok := pluginapi.ParsePanelAction(it.Action); ok {
					c.Action, c.Params = a, params
					c.Chosen = len(it.Badges) > 0
				} else if u, ok := strings.CutPrefix(it.Action, "external:"); ok {
					c.External = u
				}
				part.Cards = append(part.Cards, c)
			}
			out = append(out, part)
		default:
			out = append(out, panelPartVM{Kind: "raw", HTML: prettyJSON(f.GetProps())})
		}
	}
	return out
}

// actionValue is the form value a card's button posts.
func actionValue(c panelCardVM) string {
	vs := url.Values{}
	for k, v := range c.Params {
		vs.Set(k, v)
	}
	return c.Action + "?" + vs.Encode()
}

// handlePluginPanel shows a plugin's panel in the inspector.
func (h *Handler) handlePluginPanel(w http.ResponseWriter, r *http.Request) {
	convID, name := r.PathValue("id"), r.PathValue("name")
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	p := &panelVM{ConvID: convID, Plugin: name, Title: name}
	if t := h.pluginTypesByName(r.Context())[name]; t != nil {
		p.Title = orName(t.GetPanel().GetTitle(), orName(t.GetDisplayName(), name))
		p.Subtitle = t.GetPanel().GetSubtitle()
	}
	resp, err := h.convos.GetPluginPanel(r.Context(), connect.NewRequest(&psmithv1.GetPluginPanelRequest{ConversationId: convID, PluginName: name}))
	if err != nil {
		if connect.CodeOf(err) == connect.CodeNotFound {
			http.Error(w, "panel not found", http.StatusNotFound)
			return
		}
		p.Error = sentence(connectMessage(err))
	} else {
		p.Parts = panelParts(resp.Msg.GetFragments())
	}
	vm.Inspector.Tab, vm.Inspector.View, vm.Inspector.Panel, vm.ShowInsp, vm.Inspector.Page = "plugins", "panel", p, true, true
	h.renderConversation(w, r, vm)
}

// handlePluginAction sends a card's action to its plugin. htmx swaps the
// re-rendered body in place; without script the panel reloads.
func (h *Handler) handlePluginAction(w http.ResponseWriter, r *http.Request) {
	convID, name := r.PathValue("id"), r.PathValue("name")
	_ = r.ParseForm()
	action, query, _ := strings.Cut(r.PostFormValue("action"), "?")
	if action == "" {
		http.Error(w, "action required", http.StatusBadRequest)
		return
	}
	params := map[string]string{}
	if vs, err := url.ParseQuery(query); err == nil {
		for k := range vs {
			params[k] = vs.Get(k)
		}
	}
	resp, err := h.convos.InvokePluginAction(r.Context(), connect.NewRequest(&psmithv1.InvokePluginActionRequest{
		ConversationId: convID, PluginName: name, Action: action, Params: params,
	}))
	p := &panelVM{ConvID: convID, Plugin: name}
	if err != nil {
		if connect.CodeOf(err) == connect.CodeNotFound {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		p.Error = sentence(connectMessage(err))
	} else {
		p.Parts = panelParts(resp.Msg.GetFragments())
	}
	if r.Header.Get("HX-Request") != "" {
		h.render(w, r, http.StatusOK, panelBody(*p))
		return
	}
	http.Redirect(w, r, "/c/"+convID+"/panel/"+name, http.StatusSeeOther)
}
