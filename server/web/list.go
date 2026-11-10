package web

import (
	"context"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// listVM is the conversation list column: header, search, chips, sort, rows
// and the account footer. The URL carries the list's state (filter, sort,
// query, include-archived, select mode) so every view of it is a link.
type listVM struct {
	Rows      []rowVM
	NextToken string
	Filter    string // "all", "archived", or a profile id
	Sort      string // "used" or "created"
	Query     string
	Archived  bool // search includes archived conversations
	ActiveID  string
	Chips     []chipVM
	UserName  string
	Initial   string
	Server    string
	IsAdmin   bool

	// Empty is an account with no conversations at all: the column shows
	// the empty state instead of chips, sort and rows.
	Empty bool
	// ArchivedCount is set when every conversation is archived (board
	// ListEmptyArchive): the empty list says so and opens the archive.
	// ArchivedMore says the count is a first page, not the total.
	ArchivedCount int
	ArchivedMore  bool
	// LoadError is why ListConversations failed (board ListLoadError).
	LoadError string
	// Select is select-many mode; Selected holds the ids already ticked
	// (a bulk delete confirm re-renders with them).
	Select   bool
	Selected map[string]bool
	// ConfirmBulk asks before deleting the selection (?bulk=delete).
	ConfirmBulk bool

	// RenameID and ConfirmID put one row into its rename or delete-confirm
	// state. Both are links (?renaming=, ?deleting=) so they work without JS.
	RenameID  string
	ConfirmID string
	// MenuID opens a row's menu and HoverID draws a row hovered. Only the
	// board fixtures set them: a browser does both itself.
	MenuID  string
	HoverID string

	Offline     bool   // draw the reconnecting state (fixtures; app.js does it live)
	RetryIn     string // "4s"
	AccountOpen bool   // draw the account menu open (fixtures)
	Command     *commandVM
}

type chipVM struct {
	Label string
	Href  string
	Color int // profile color slot; 0 for All and Archived
	On    bool
}

type rowVM struct {
	ID       string
	Title    string
	Hits     []hlPart // title split around the search match; empty when not searching
	Time     string
	Group    string // set on the first row of a date (or Pinned) section
	Profile  string
	Color    int
	Active   bool
	Live     bool // a reply is streaming
	Pinned   bool
	Archived bool
	Draft    string // unsent text the browser holds for this conversation; filled in by app.js
	// Activity is the newest message's time (unix ms), whatever the sort.
	// list.js marks a row unread when it moves while the row isn't open.
	Activity int64
	at       time.Time
}

// hlPart is a run of a highlighted title: Hit runs are the search match.
type hlPart struct {
	Text string
	Hit  bool
}

// highlight splits s around every case-insensitive occurrence of q.
func highlight(s, q string) []hlPart {
	if q == "" {
		return nil
	}
	ls, lq := strings.ToLower(s), strings.ToLower(q)
	var out []hlPart
	for {
		i := strings.Index(ls, lq)
		// Lowercasing can change byte lengths outside ASCII; fall back to
		// no highlight rather than slice mid-rune.
		if i < 0 || len(ls) != len(s) {
			if s != "" {
				out = append(out, hlPart{Text: s})
			}
			return out
		}
		if i > 0 {
			out = append(out, hlPart{Text: s[:i]})
		}
		out = append(out, hlPart{Text: s[i : i+len(q)], Hit: true})
		s, ls = s[i+len(q):], ls[i+len(q):]
	}
}

// The row-state keys stay clear of the conversation page's own ?rename
// (its title) and ?confirm (the inspector's), which share the URL.
const (
	renameKey  = "renaming"
	confirmKey = "deleting"
)

// listState reads the list's filter, sort and query from the request.
func listState(r *http.Request) (filter, sort, query string) {
	q := r.URL.Query()
	filter = q.Get("f")
	if filter == "" {
		filter = "all"
	}
	sort = q.Get("sort")
	if sort != "created" {
		sort = "used"
	}
	return filter, sort, strings.TrimSpace(q.Get("q"))
}

// listQuery is the query string that keeps the list's state across links.
func (l listVM) listQuery() string { return l.query(nil) }

// query is listQuery plus extra parameters.
func (l listVM) query(extra url.Values) string {
	v := url.Values{}
	if l.Filter != "all" && l.Filter != "" {
		v.Set("f", l.Filter)
	}
	if l.Sort == "created" {
		v.Set("sort", "created")
	}
	if l.Query != "" {
		v.Set("q", l.Query)
		if l.Archived {
			v.Set("arch", "1")
		}
	}
	for k, vs := range extra {
		v[k] = vs
	}
	if len(v) == 0 {
		return ""
	}
	return "?" + v.Encode()
}

// listHref is /chats with the list's state.
func (l listVM) listHref() string { return "/chats" + l.listQuery() }

// basePath is the page the list sits on without its state: the open
// conversation, or /chats. Filtering, sorting and searching stay on it, so
// they change the list and leave the conversation open.
func (l listVM) basePath() string {
	if l.ActiveID != "" {
		return "/c/" + l.ActiveID
	}
	return "/chats"
}

// convHref links a row, keeping the list's state.
func (l listVM) convHref(id string) string { return "/c/" + id + l.listQuery() }

// stateHref is the page the list sits on with one row in a state (rename,
// confirm): the open conversation, or /chats.
func (l listVM) stateHref(key, id string) string {
	return l.basePath() + l.query(url.Values{key: {id}})
}

// pageHref is the page the list sits on, with its state.
func (l listVM) pageHref() string {
	if l.ActiveID != "" {
		return l.convHref(l.ActiveID)
	}
	return l.listHref()
}

// userInfo fills the account fields from the request's user.
func (l *listVM) userInfo(ctx context.Context) {
	if u, ok := auth.FromContext(ctx); ok {
		l.UserName = u.Username
		if u.DisplayName != nil && *u.DisplayName != "" {
			l.UserName = *u.DisplayName
		}
		l.IsAdmin = u.IsAdmin
	}
	if l.UserName != "" {
		l.Initial = strings.ToUpper(l.UserName[:1])
	}
}

// loadList builds the list column for the request. activeID marks the open
// conversation. The first page carries the pinned section.
func (h *Handler) loadList(ctx context.Context, r *http.Request, activeID, pageToken string) listVM {
	filter, sort, query := listState(r)
	q := r.URL.Query()
	vm := listVM{Filter: filter, Sort: sort, Query: query, ActiveID: activeID, Server: r.Host,
		Archived: query != "" && q.Get("arch") == "1",
		Select:   q.Get("select") != "", RenameID: q.Get(renameKey), ConfirmID: q.Get(confirmKey)}
	vm.userInfo(ctx)
	if vm.Select {
		vm.Selected = map[string]bool{}
		for _, id := range q["id"] {
			vm.Selected[id] = true
		}
		vm.ConfirmBulk = q.Get("bulk") == "delete" && len(vm.Selected) > 0
	}

	profiles := h.profileIndex(ctx)
	base := listVM{Sort: sort}
	vm.Chips = append(vm.Chips,
		chipVM{Label: "All", Href: vm.basePath() + withFilter(base, "all"), On: filter == "all"},
		chipVM{Label: "Archived", Href: vm.basePath() + withFilter(base, "archived"), On: filter == "archived"},
	)
	for _, p := range profiles.order {
		vm.Chips = append(vm.Chips, chipVM{Label: p.GetName(), Href: vm.basePath() + withFilter(base, p.GetId()), Color: profileColor(p.GetId()), On: filter == p.GetId()})
	}
	if h.convos == nil {
		return vm
	}

	list := func(archived bool, token string) ([]*psmithv1.Conversation, string, error) {
		req := &psmithv1.ListConversationsRequest{PageSize: 100, PageToken: token, Archived: archived}
		if sort == "created" {
			o := psmithv1.ConversationOrder_CONVERSATION_ORDER_RECENTLY_CREATED
			req.Order = &o
		}
		if query != "" {
			req.TitleQuery = &query
		}
		if filter != "all" && filter != "archived" {
			req.ProfileId = &filter
		}
		resp, err := h.convos.ListConversations(ctx, connect.NewRequest(req))
		if err != nil {
			h.logger.Warn("web: list conversations failed", "err", err)
			return nil, "", err
		}
		return resp.Msg.GetConversations(), resp.Msg.GetNextPageToken(), nil
	}

	live := h.liveConversations(ctx)
	now := time.Now()
	if query != "" {
		// Search is one ranked list: the title matches, newest first, with
		// archived ones mixed in when asked.
		convs, _, err := list(filter == "archived", "")
		if err == nil && vm.Archived && filter != "archived" {
			var more []*psmithv1.Conversation
			more, _, err = list(true, "")
			convs = append(convs, more...)
		}
		if err != nil {
			vm.LoadError = friendlyError(err)
			return vm
		}
		vm.Rows = searchRows(now, convs, profiles.names, live, activeID, sort, query)
		return vm
	}

	convs, next, err := list(filter == "archived", pageToken)
	if err != nil {
		vm.LoadError = friendlyError(err)
		return vm
	}
	// A later page continues the section the page before it ended in (g).
	prev := ""
	if pageToken != "" {
		prev = q.Get("g")
	}
	if filter == "archived" {
		vm.Rows = monthRows(now, convs, profiles.names, activeID, sort, prev)
	} else {
		vm.Rows = buildRows(now, convs, profiles.names, live, activeID, sort, prev)
	}
	vm.NextToken = next
	if filter == "all" && pageToken == "" && len(vm.Rows) == 0 {
		// Nothing active. With an archive that's not "no conversations yet".
		arch, more, err := list(true, "")
		if err != nil {
			vm.LoadError = friendlyError(err)
			return vm
		}
		vm.ArchivedCount, vm.ArchivedMore = len(arch), more != ""
		vm.Empty = len(arch) == 0
	}
	return vm
}

// bare is the column with nothing active to show: only the All and
// Archived chips, no sort, and an empty state in place of rows.
func (l listVM) bare() bool { return l.Empty || l.ArchivedCount > 0 }

// archivedLabel is the empty state's archive count: "12", or "100+" when
// the first page wasn't the whole archive.
func (l listVM) archivedLabel() string {
	n := strconv.Itoa(l.ArchivedCount)
	if l.ArchivedMore {
		n += "+"
	}
	return n
}

func withFilter(l listVM, f string) string {
	l.Filter = f
	return l.listQuery()
}

func newRow(now time.Time, c *psmithv1.Conversation, names map[string]string, live map[string]bool, activeID, sort string) rowVM {
	row := rowVM{
		ID: c.GetId(), Title: convoTitle(c), Profile: names[c.GetProfileId()], Color: profileColor(c.GetProfileId()),
		Active: c.GetId() == activeID, Live: live[c.GetId()], Pinned: c.GetPinnedAt() != nil, Archived: c.GetArchivedAt() != nil,
	}
	row.at = c.GetLastActivityAt().AsTime()
	if c.GetLastActivityAt() != nil {
		row.Activity = row.at.UnixMilli()
	}
	if c.GetLastActivityAt() == nil || sort == "created" {
		row.at = c.GetCreatedAt().AsTime()
	}
	row.Time = listTime(now, row.at)
	return row
}

// buildRows turns conversations into rows with section heads. Pinned rows
// come first under "Pinned"; the rest bucket by date.
func buildRows(now time.Time, convs []*psmithv1.Conversation, names map[string]string, live map[string]bool, activeID, sort, prev string) []rowVM {
	out := make([]rowVM, 0, len(convs))
	var pinned, rest []rowVM
	last := prev
	for _, c := range convs {
		row := newRow(now, c, names, live, activeID, sort)
		if row.Pinned && !row.Archived {
			pinned = append(pinned, row)
			continue
		}
		if g := dateGroup(now, row.at); g != last {
			row.Group, last = g, g
		}
		rest = append(rest, row)
	}
	if len(pinned) > 0 {
		pinned[0].Group = "Pinned"
	}
	out = append(out, pinned...)
	return append(out, rest...)
}

// monthRows groups the archive by month: it is a record, not a queue, and
// "Previous 30 days" says little about something archived in spring.
func monthRows(now time.Time, convs []*psmithv1.Conversation, names map[string]string, activeID, sort, prev string) []rowVM {
	out := make([]rowVM, 0, len(convs))
	last := prev
	for _, c := range convs {
		row := newRow(now, c, names, nil, activeID, sort)
		g := row.at.In(now.Location()).Format("January")
		if row.at.Year() != now.Year() {
			g = row.at.In(now.Location()).Format("January 2006")
		}
		if g != last {
			row.Group, last = g, g
		}
		out = append(out, row)
	}
	return out
}

// searchRows is a flat list of title matches, newest first, each title
// marked where it matched.
func searchRows(now time.Time, convs []*psmithv1.Conversation, names map[string]string, live map[string]bool, activeID, sort, query string) []rowVM {
	out := make([]rowVM, 0, len(convs))
	seen := map[string]bool{}
	for _, c := range convs {
		if seen[c.GetId()] {
			continue
		}
		seen[c.GetId()] = true
		row := newRow(now, c, names, live, activeID, sort)
		row.Hits = highlight(row.Title, query)
		out = append(out, row)
	}
	sortByTime(out)
	return out
}

func sortByTime(rows []rowVM) {
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].at.After(rows[j].at) })
}

// lastGroup is the section the last row belongs to.
func lastGroup(rows []rowVM) string {
	for i := len(rows) - 1; i >= 0; i-- {
		if rows[i].Group != "" {
			return rows[i].Group
		}
	}
	return ""
}

// listTime is the row's time label: a clock time today, a weekday this week,
// then a date.
func listTime(now, t time.Time) string {
	t = t.In(now.Location())
	startOfToday := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch {
	case !t.Before(startOfToday):
		return t.Format("15:04")
	case !t.Before(startOfToday.AddDate(0, 0, -6)):
		return t.Format("Mon")
	case t.Year() == now.Year():
		return t.Format("Jan 2")
	default:
		return t.Format("Jan 2006")
	}
}

type profileIdx struct {
	order []*psmithv1.Profile
	names map[string]string
	byID  map[string]*psmithv1.Profile
}

// profileIndex lists the caller's chat profiles (templates excluded) in the
// server's order, with a name lookup.
func (h *Handler) profileIndex(ctx context.Context) profileIdx {
	idx := profileIdx{names: map[string]string{}, byID: map[string]*psmithv1.Profile{}}
	if h.profiles == nil {
		return idx
	}
	resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	if err != nil {
		return idx
	}
	for _, p := range resp.Msg.GetProfiles() {
		idx.names[p.GetId()] = p.GetName()
		idx.byID[p.GetId()] = p
		if !p.GetParentOnly() {
			idx.order = append(idx.order, p)
		}
	}
	return idx
}

// liveConversations is the set of conversations with a reply streaming now.
func (h *Handler) liveConversations(ctx context.Context) map[string]bool {
	out := map[string]bool{}
	if h.supervisor == nil || h.queries == nil {
		return out
	}
	u, ok := auth.FromContext(ctx)
	if !ok {
		return out
	}
	runs, err := h.queries.ListActiveStreamRunsByUser(ctx, u.ID)
	if err != nil {
		return out
	}
	for _, run := range runs {
		out[run.ConversationID.String()] = true
	}
	return out
}

// handleChats is the app with nothing open: the list, and a start page that
// offers the profiles and the most recent conversations. An account with no
// model to chat with goes to first-run setup instead.
func (h *Handler) handleChats(w http.ResponseWriter, r *http.Request) {
	if step := h.setupStep(r.Context()); step != "" {
		http.Redirect(w, r, step, http.StatusSeeOther)
		return
	}
	l := h.loadList(r.Context(), r, "", "")
	h.render(w, r, http.StatusOK, welcomeScreen(l, h.loadWelcome(r.Context(), l)))
}

// handleListPartial re-renders the list column, keeping its filter, sort,
// query and highlighted row.
func (h *Handler) handleListPartial(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, listColumn(h.loadList(r.Context(), r, r.URL.Query().Get("active"), "")))
}

// handleListRowsPartial serves Show more: the next page of rows.
func (h *Handler) handleListRowsPartial(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, listRows(h.loadList(r.Context(), r, r.URL.Query().Get("active"), r.URL.Query().Get("token"))))
}
