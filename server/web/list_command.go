package web

import (
	"context"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// commandVM is the search box's results: commands, conversations whose
// title matches, and settings pages.
type commandVM struct {
	Query    string
	Commands []cmdVM
	Convs    []rowVM // Active marks the highlighted option
	More     int     // title matches beyond the ones shown
	MoreHref string
	Settings []cmdVM
}

// cmdVM is one command or settings page. Href navigates; Post (with
// Fields) submits instead, for commands that change something.
type cmdVM struct {
	Label    string
	Hits     []hlPart
	Hint     string
	Icon     string
	Href     string
	Post     string
	Fields   map[string]string
	Selected bool
}

const (
	maxCmdCommands = 4
	maxCmdConvs    = 3
	maxCmdSettings = 4
)

// handleCommand answers the search box: GET /partials/command?q=&conv=.
// conv is the open conversation, which adds the commands that act on it.
func (h *Handler) handleCommand(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	c := h.loadCommand(r.Context(), q, r.URL.Query().Get("conv"))
	h.render(w, r, http.StatusOK, commandResults(c))
}

func (h *Handler) loadCommand(ctx context.Context, q, convID string) commandVM {
	c := commandVM{Query: q}
	if q == "" {
		return c
	}
	idx := h.profileIndex(ctx)

	var conv *psmithv1.Conversation
	var active *psmithv1.Context
	if convID != "" && h.convos != nil {
		if resp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID})); err == nil {
			conv, active = resp.Msg.GetConversation(), resp.Msg.GetActiveContext()
		}
	}
	c.Commands = matchCmds(q, commandCatalog(conv, active, prefsOf(ctx).Mode), maxCmdCommands)

	if h.convos != nil {
		var convs []*psmithv1.Conversation
		for _, archived := range []bool{false, true} {
			resp, err := h.convos.ListConversations(ctx, connect.NewRequest(&psmithv1.ListConversationsRequest{PageSize: 50, TitleQuery: &q, Archived: archived}))
			if err == nil {
				convs = append(convs, resp.Msg.GetConversations()...)
			}
		}
		rows := searchRows(time.Now(), convs, idx.names, nil, "", "used", q)
		for i := range rows {
			rows[i].Active = false
		}
		if len(rows) > maxCmdConvs {
			c.More = len(rows)
			c.MoreHref = "/chats?arch=1&q=" + url.QueryEscape(q)
			rows = rows[:maxCmdConvs]
		}
		c.Convs = rows
	}

	isAdmin := false
	if u, ok := auth.FromContext(ctx); ok {
		isAdmin = u.IsAdmin
	}
	var profile *psmithv1.Profile
	if conv != nil {
		profile = idx.byID[conv.GetProfileId()]
	}
	c.Settings = matchCmds(q, settingsCatalog(isAdmin, profile, idx), maxCmdSettings)

	// The first option is the one Enter runs.
	switch {
	case len(c.Commands) > 0:
		c.Commands[0].Selected = true
	case len(c.Convs) > 0:
		c.Convs[0].Active = true
	case len(c.Settings) > 0:
		c.Settings[0].Selected = true
	}
	return c
}

// matchCmds keeps the entries whose label contains q, labels that start
// with it first, and marks where each matched.
func matchCmds(q string, all []cmdVM, limit int) []cmdVM {
	lq := strings.ToLower(q)
	var out []cmdVM
	for _, c := range all {
		if strings.Contains(strings.ToLower(c.Label), lq) {
			c.Hits = firstHit(c.Label, q)
			out = append(out, c)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		pi := strings.HasPrefix(strings.ToLower(out[i].Label), lq)
		pj := strings.HasPrefix(strings.ToLower(out[j].Label), lq)
		return pi && !pj
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// firstHit marks only the first occurrence: a command label is short and
// one bold run reads better than several.
func firstHit(s, q string) []hlPart {
	parts := highlight(s, q)
	seen := false
	var out []hlPart
	for _, p := range parts {
		if p.Hit && seen {
			p.Hit = false
		}
		if p.Hit {
			seen = true
		}
		if n := len(out); n > 0 && !p.Hit && !out[n-1].Hit {
			out[n-1].Text += p.Text
			continue
		}
		out = append(out, p)
	}
	return out
}

// commandCatalog is every command, with the ones for the open conversation
// first.
func commandCatalog(conv *psmithv1.Conversation, active *psmithv1.Context, mode string) []cmdVM {
	var out []cmdVM
	if conv != nil {
		id := conv.GetId()
		back := map[string]string{"back": "/c/" + id}
		tokens := abbrevTokens(int32(active.GetLastMessageTotalTokens())) + " tokens"
		if active.GetLastMessageTotalTokens() == 0 {
			tokens = ""
		}
		pin := "Pin this conversation"
		if conv.GetPinnedAt() != nil {
			pin = "Unpin this conversation"
		}
		out = append(out,
			cmdVM{Label: "Compress this context", Hint: tokens, Icon: "compress", Href: "/c/" + id + "/compact"},
			cmdVM{Label: "Change model", Hint: "M", Icon: "gauge", Href: "/c/" + id + "/model"},
			cmdVM{Label: "Rename this conversation", Icon: "edit", Href: "/c/" + id + "?rename=1"},
			cmdVM{Label: "Generate a title", Icon: "regen", Post: "/chats/" + id + "/title", Fields: back},
			cmdVM{Label: pin, Icon: "plus", Post: "/c/" + id + "/pin", Fields: back},
		)
		if conv.GetArchivedAt() != nil {
			out = append(out, cmdVM{Label: "Unarchive this conversation", Icon: "back", Post: "/c/" + id + "/unarchive", Fields: back})
		} else {
			out = append(out, cmdVM{Label: "Archive this conversation", Icon: "trash", Post: "/c/" + id + "/archive", Fields: back})
		}
		out = append(out, cmdVM{Label: "Delete this conversation", Icon: "trash", Href: "/c/" + id + "?tab=info&confirm=delete"})
	}
	other := "dark"
	if mode == "dark" {
		other = "light"
	}
	out = append(out,
		cmdVM{Label: "New conversation", Hint: "C", Icon: "plus", Href: "/new"},
		cmdVM{Label: "Select conversations", Hint: "X", Icon: "edit", Href: "/chats?select=1"},
		cmdVM{Label: "Show archived conversations", Icon: "search13", Href: "/chats?f=archived"},
		cmdVM{Label: "Keyboard shortcuts", Hint: "?", Icon: "gear16", Href: "/shortcuts"},
		cmdVM{Label: "Switch to " + other + " appearance", Icon: "gear16", Post: "/prefs/appearance", Fields: map[string]string{"mode": other}},
		cmdVM{Label: "Sign out", Icon: "back", Post: "/logout"},
	)
	return out
}

// settingsCatalog is every settings page, plus the open conversation's
// profile fields.
func settingsCatalog(isAdmin bool, profile *psmithv1.Profile, idx profileIdx) []cmdVM {
	page := func(label, href string) cmdVM {
		return cmdVM{Label: label, Hint: "Settings", Icon: "gear16", Href: href}
	}
	var out []cmdVM
	if profile != nil {
		href := "/settings/profiles/" + profile.GetId()
		hint := profile.GetName() + " profile"
		for _, f := range []string{"Default model", "System message", "Compaction model", "Compaction guide", "Auto-title model", "Auto-title guide", "Plugins"} {
			out = append(out, cmdVM{Label: f, Hint: hint, Icon: "gear16", Href: href})
		}
	}
	out = append(out,
		page("General", "/settings/general"),
		page("Appearance", "/settings/appearance"),
		page("Usage and cost", "/settings/cost"),
		page("Providers", "/settings/providers"),
		page("Profiles", "/settings/profiles"),
		page("Plugins", "/settings/plugins"),
		page("MCP servers", "/settings/mcp-servers"),
		page("Embedder", "/settings/embedder"),
		page("Langfuse", "/settings/langfuse"),
		page("Speech", "/settings/speech"),
	)
	if isAdmin {
		out = append(out, page("Users", "/settings/users"))
	}
	for _, p := range idx.order {
		out = append(out, cmdVM{Label: p.GetName(), Hint: "Profile", Icon: "gear16", Href: "/settings/profiles/" + p.GetId()})
	}
	return out
}
