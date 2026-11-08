package web

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
)

// inspVM is the inspector column and the composer's slot: which tab or
// sub-view the column shows, the data that view needs, and the card that
// stands in for the composer while compression, review or elicitation runs.
type inspVM struct {
	Tab  string // "context", "settings", "plugins"
	View string // "" (the tab), "model", "info", "panel", "config", "contexts"
	// Page is set when the URL asked for the inspector. Below 1180px the
	// column only shows when asked for, and then as the whole page.
	Page bool

	Cost     string
	Turns    int
	Cache    string
	Changes  int
	Contexts []ctxRowVM
	Branches []branchRowVM // the transcript's branch points, in order
	Title    string        // the conversation's title, for the narrow page header

	// Compress is the context tab's button state: "" (offer it), "open" (the
	// card is showing), "running", "review".
	Compress string
	Rename   string // context id being renamed in the contexts view
	Confirm  string // context id (or "conversation") awaiting a delete confirm

	Settings *callSettingsVM
	Plugins  *pluginsTabVM
	Picker   *pickerVM
	Info     *infoVM
	Panel    *panelVM
	Config   *pluginConfigVM

	Card *slotVM
}

type ctxRowVM struct {
	N      int // position, oldest first; 0 in fixtures that list rows as drawn
	ID     string
	Label  string // "Context 2"
	Title  string // the context's own title, or Label when it has none
	Detail string
	Active bool
	// Viewing marks the context the read-only page shows.
	Viewing bool
	Turns   int
	CostUSD float64
	Tokens  int64
	Summary string // "Context 2 · 22 turns · compressed Nov 4 · $0.71"
}

// inspTabs are the inspector's tabs, in order.
var inspTabs = []string{"context", "settings", "plugins"}

func validTab(t string) bool {
	for _, x := range inspTabs {
		if x == t {
			return true
		}
	}
	return false
}

// fillInspector fills the inspector and the composer slot for the
// conversation screen from the request: ?tab= picks the tab, and the routes
// that open a sub-view set it after this runs.
func (h *Handler) fillInspector(ctx context.Context, r *http.Request, vm *convVM, conv *psmithv1.Conversation, active *psmithv1.Context, msgs []*psmithv1.Message) {
	in := &vm.Inspector
	in.Title = vm.Title
	in.Branches = branchRows(vm.Items)
	// GetConversation's active context carries no aggregates; the list does.
	for _, x := range in.Contexts {
		if x.Active {
			active = proto.Clone(active).(*psmithv1.Context)
			active.LastMessageTotalTokens, active.CumulativeCostUsd = x.Tokens, x.CostUSD
			in.Cost = fmt.Sprintf("$%.4f", x.CostUSD)
			vm.Gauge = h.gauge(ctx, active, int32(vm.Gauge.Window))
		}
	}
	// With no model of its own the conversation runs on the profile's, which
	// is what the header and the gauge should describe.
	if currentSettingsModel(conv) == "" {
		if d := h.resolvedProfile(ctx, conv.GetProfileId()).GetDefaultSettings(); d.GetDefaultProviderId() != "" {
			val := modelValue(d.GetDefaultProviderId(), d.GetDefaultModelId())
			if val != vm.Model.Value {
				pick := h.modelPicker(ctx, vm.ID, val, capsVM{}, vm.Harness)
				if pick.Current.Value == val {
					vm.Model = modelChipVM{Value: val, Name: pick.Current.DisplayName, Provider: pick.ProviderLabel(pick.Current.ProviderID)}
					vm.Gauge = h.gauge(ctx, active, pick.Current.ContextWindow)
				}
			}
		}
	}
	q := r.URL.Query()
	if t := q.Get("tab"); t != "" {
		in.Page = true
		vm.ShowInsp = true
		switch {
		case validTab(t):
			in.Tab = t
		case t == "contexts":
			in.Tab, in.View = "context", "contexts"
		case t == "info":
			in.View = "info"
		}
	}
	if in.View == "contexts" {
		in.Rename = q.Get("rename")
		in.Confirm = q.Get("confirm")
	}

	h.fillSlot(ctx, r, vm, conv, active, msgs)

	switch {
	case in.View == "info":
		h.fillInfo(ctx, vm, conv, q.Get("confirm") == "delete")
	case in.Tab == "settings":
		in.Settings = h.callSettings(ctx, conv, vm.Model)
	case in.Tab == "plugins":
		in.Plugins = h.pluginsTab(ctx, conv.GetId(), vm.Profile)
	}
}

// contextRows lists a conversation's contexts oldest first, labelled by
// position, with the stats each row shows.
func (h *Handler) contextRows(ctx context.Context, convID, activeID string) []ctxRowVM {
	resp, err := h.convos.ListContexts(ctx, connect.NewRequest(&psmithv1.ListContextsRequest{ConversationId: convID}))
	if err != nil {
		return nil
	}
	cs := resp.Msg.GetContexts()
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].GetCreatedAt().AsTime().Before(cs[j].GetCreatedAt().AsTime()) })
	out := make([]ctxRowVM, 0, len(cs))
	for i, c := range cs {
		turns := h.contextTurns(ctx, c.GetId())
		var next *psmithv1.Context
		if i+1 < len(cs) {
			next = cs[i+1]
		}
		out = append(out, ctxRow(i+1, c, next, c.GetId() == activeID, turns))
	}
	return out
}

// ctxRow builds one row. next is the context that followed this one (its
// creation is when this one was compressed); nil for the newest.
func ctxRow(n int, c, next *psmithv1.Context, active bool, turns int) ctxRowVM {
	label := fmt.Sprintf("Context %d", n)
	row := ctxRowVM{N: n, ID: c.GetId(), Label: label, Title: label, Active: active, Turns: turns, CostUSD: c.GetCumulativeCostUsd(), Tokens: c.GetLastMessageTotalTokens()}
	if t := strings.TrimSpace(c.GetTitle()); t != "" {
		row.Title = t
	}
	var parts []string
	if c.GetParentContextId() != "" {
		parts = append(parts, "From a summary")
	}
	parts = append(parts, plural(turns, "turn"))
	var compressed string
	if next != nil {
		compressed = "compressed " + next.GetCreatedAt().AsTime().Format("Jan 2")
	}
	if active {
		if t := c.GetLastMessageTotalTokens(); t > 0 {
			parts = append(parts, abbrevTokens(int32(t)))
		}
	} else {
		if compressed != "" {
			parts = append(parts, compressed)
		}
		parts = append(parts, fmt.Sprintf("$%.2f", c.GetCumulativeCostUsd()))
	}
	row.Detail = strings.Join(parts, " · ")

	sum := []string{label}
	if active {
		sum = append(sum, "active")
	}
	sum = append(sum, plural(turns, "turn"))
	if compressed != "" {
		sum = append(sum, compressed)
	}
	if !active {
		sum = append(sum, fmt.Sprintf("$%.2f", c.GetCumulativeCostUsd()))
	}
	row.Summary = strings.Join(sum, " · ")
	return row
}

// contextTurns counts the user turns on a context's current chain. The
// structure-only read leaves message bodies behind.
func (h *Handler) contextTurns(ctx context.Context, contextID string) int {
	resp, err := h.convos.ListMessages(ctx, connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: contextID, StructureOnly: true}))
	if err != nil {
		return 0
	}
	n := 0
	for _, m := range resp.Msg.GetMessages() {
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_USER {
			n++
		}
	}
	return n
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

// runningCompaction returns the conversation's in-flight compression run, or
// "". A reload mid-compression lands back on the streaming card.
func (h *Handler) runningCompaction(ctx context.Context, convID string) string {
	if h.queries == nil {
		return ""
	}
	u, ok := auth.FromContext(ctx)
	if !ok {
		return ""
	}
	cid, err := uuid.Parse(convID)
	if err != nil {
		return ""
	}
	runs, err := h.queries.ListActiveStreamRunsByConversation(ctx, store.ListActiveStreamRunsByConversationParams{UserID: u.ID, ConversationID: cid})
	if err != nil {
		return ""
	}
	for _, run := range runs {
		if run.Purpose == string(stream.PurposeCompression) {
			return run.ID.String()
		}
	}
	return ""
}

// fmtWhen renders a timestamp the way the info view lists them: "Today,
// 10:42 AM" for today, else "Oct 22, 2026, 4:12 PM".
func fmtWhen(now, t time.Time) string {
	t = t.In(now.Location())
	if y, m, d := now.Date(); t.Year() == y && t.Month() == m && t.Day() == d {
		return "Today, " + t.Format("3:04 PM")
	}
	return t.Format("Jan 2, 2006, 3:04 PM")
}

// newestFirst orders rows for display: the inspector lists the newest
// context first. Rows keep oldest-first order everywhere else, since a
// context's label is its position.
func newestFirst(rows []ctxRowVM) []ctxRowVM {
	for _, r := range rows {
		if r.N == 0 {
			return rows
		}
	}
	out := append([]ctxRowVM(nil), rows...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].N > out[j].N })
	return out
}

// branchRowVM is one branch point in the inspector: a message with siblings,
// linking to where it sits in the transcript.
type branchRowVM struct {
	Label string // "Your message · And the compression summary card…"
	Pos   string // "2 of 3"
	Href  string
}

func branchRows(items []msgItem) []branchRowVM {
	var out []branchRowVM
	for _, it := range items {
		if it.Branch == nil {
			continue
		}
		who := "Reply"
		if it.Role == "user" {
			who = "Your message"
		}
		out = append(out, branchRowVM{
			Label: who + " · " + firstLine(it.Text),
			Pos:   strconv.Itoa(it.Branch.Index) + " of " + strconv.Itoa(it.Branch.Count),
			Href:  "#m-" + it.ID,
		})
	}
	return out
}

// firstLine is the text's first non-empty line; the row's ellipsis trims it.
func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}
