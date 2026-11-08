package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/modelproviders"
	"github.com/jdpedrie/psmith/server/profiles"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/testutil"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// listEnv is a handler with every service the list area calls, a user with
// a profile, a provider and model, and one conversation (seedSendable).
type listEnv struct {
	h      *Handler
	convos *conversations.Service
	models *modelproviders.Service
	q      *store.Queries
	ctx    context.Context
	fx     sendFixture
	fake   *fakellm.Server
}

func newListEnv(t *testing.T) listEnv {
	t.Helper()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Models: models, Profiles: prof, Supervisor: sup, Logger: slog.Default()})
	fx := seedSendable(t, q, fake.URL())
	ctx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "john"})
	return listEnv{h: h, convos: convos, models: models, q: q, ctx: ctx, fx: fx, fake: fake}
}

func (e listEnv) get(fn http.HandlerFunc, target string, path map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", target, nil).WithContext(e.ctx)
	for k, v := range path {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func (e listEnv) post(fn http.HandlerFunc, target string, form url.Values, path map[string]string, htmx bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", target, strings.NewReader(form.Encode())).WithContext(e.ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if htmx {
		req.Header.Set("HX-Request", "true")
	}
	for k, v := range path {
		req.SetPathValue(k, v)
	}
	return do(fn, req)
}

func (e listEnv) newConv(t *testing.T, title string) string {
	t.Helper()
	resp, err := e.convos.CreateConversation(e.ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{ProfileId: e.profileID(t), Title: &title}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	return resp.Msg.GetConversation().GetId()
}

func (e listEnv) profileID(t *testing.T) string {
	t.Helper()
	c, err := e.convos.GetConversation(e.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: e.fx.convID.String()}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	return c.Msg.GetConversation().GetProfileId()
}

func (e listEnv) conv(t *testing.T, id string) *psmithv1.Conversation {
	t.Helper()
	c, err := e.convos.GetConversation(e.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: id}))
	if err != nil {
		t.Fatalf("GetConversation %s: %v", id, err)
	}
	return c.Msg.GetConversation()
}

func mustContain(t *testing.T, body string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(body, w) {
			t.Errorf("body missing %q", w)
		}
	}
}

func TestChats_WelcomeListsProfilesAndRows(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	e.newConv(t, "Weekly planning")
	rec := e.get(e.h.handleChats, "/chats", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d", rec.Code)
	}
	body := rec.Body.String()
	mustContain(t, body, "Start a conversation", "Weekly planning", `href="/new?profile=`+e.profileID(t), "Recent", `id="list"`, "Keyboard shortcuts")
}

func TestChats_NoProviderGoesToSetup(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	models := modelproviders.NewService(q, modelmeta.NewLiveCatalog(nil), crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Models: models, Logger: slog.Default()})
	uid, _ := uuid.NewV7()
	if _, err := q.CreateUser(context.Background(), store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"}); err != nil {
		t.Fatal(err)
	}
	ctx := auth.ContextWithUser(context.Background(), auth.User{ID: uid, Username: "u"})
	rec := do(h.handleChats, httptest.NewRequest("GET", "/chats", nil).WithContext(ctx))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/setup" {
		t.Fatalf("code=%d loc=%q, want 303 /setup", rec.Code, rec.Header().Get("Location"))
	}
}

func TestListEmptyState(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	if _, err := e.convos.DeleteConversation(e.ctx, connect.NewRequest(&psmithv1.DeleteConversationRequest{Id: e.fx.convID.String()})); err != nil {
		t.Fatal(err)
	}
	body := e.get(e.h.handleChats, "/chats", nil).Body.String()
	mustContain(t, body, "No conversations yet", "Start your first conversation", "Manage profiles")
}

func TestRowActions_Rename(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "Old title")
	path := map[string]string{"id": id}

	rec := e.post(e.h.handleListRename, "/chats/"+id+"/rename", url.Values{"title": {"New title"}, "back": {"/chats?f=archived"}}, path, false)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/chats?f=archived" {
		t.Fatalf("plain rename: code=%d loc=%q", rec.Code, rec.Header().Get("Location"))
	}
	if got := e.conv(t, id).GetTitle(); got != "New title" {
		t.Fatalf("title=%q", got)
	}

	// With htmx the answer is the list for the page it came from.
	rec = e.post(e.h.handleListRename, "/chats/"+id+"/rename", url.Values{"title": {"Newer"}, "back": {"/chats"}}, path, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("htmx rename code=%d", rec.Code)
	}
	mustContain(t, rec.Body.String(), `id="list"`, "Newer")

	// An empty title changes nothing; an off-site back is ignored.
	rec = e.post(e.h.handleListRename, "/chats/"+id+"/rename", url.Values{"title": {"  "}, "back": {"https://evil.example/x"}}, path, false)
	if rec.Header().Get("Location") != "/chats" {
		t.Errorf("off-site back honored: %q", rec.Header().Get("Location"))
	}
	if got := e.conv(t, id).GetTitle(); got != "Newer" {
		t.Errorf("empty rename changed title to %q", got)
	}
}

func TestRowActions_PinArchiveUnarchiveDelete(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "Pin me")
	path := map[string]string{"id": id}
	back := url.Values{"back": {"/chats"}}

	e.post(e.h.handlePinToggle, "/c/"+id+"/pin", back, path, false)
	if e.conv(t, id).GetPinnedAt() == nil {
		t.Fatal("not pinned")
	}
	body := e.get(e.h.handleChats, "/chats", nil).Body.String()
	mustContain(t, body, `<div class="group-head">Pinned</div>`, `aria-label="Pinned"`, "Unpin")
	e.post(e.h.handlePinToggle, "/c/"+id+"/pin", back, path, false)
	if e.conv(t, id).GetPinnedAt() != nil {
		t.Fatal("still pinned")
	}

	e.post(e.h.handleArchive, "/c/"+id+"/archive", back, path, false)
	if e.conv(t, id).GetArchivedAt() == nil {
		t.Fatal("not archived")
	}
	arch := e.get(e.h.handleChats, "/chats?f=archived", nil).Body.String()
	mustContain(t, arch, "Pin me", "Unarchive", "Archived conversations are read-only")

	rec := e.post(e.h.handleUnarchive, "/c/"+id+"/unarchive", url.Values{}, path, false)
	if rec.Header().Get("Location") != "/c/"+id {
		t.Errorf("unarchive redirect=%q", rec.Header().Get("Location"))
	}
	if e.conv(t, id).GetArchivedAt() != nil {
		t.Fatal("still archived")
	}

	// Deleting the open conversation from its own page leaves for the list.
	rec = e.post(e.h.handleConversationDelete, "/c/"+id+"/delete", url.Values{"back": {"/c/" + id}}, path, true)
	if rec.Header().Get("HX-Redirect") != "/chats" {
		t.Errorf("HX-Redirect=%q", rec.Header().Get("HX-Redirect"))
	}
	if _, err := e.convos.GetConversation(e.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: id})); err == nil {
		t.Error("conversation survived delete")
	}
}

func TestRowActions_ArchiveOpenConversationReloads(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "Open one")
	rec := e.post(e.h.handleArchive, "/c/"+id+"/archive", url.Values{"back": {"/c/" + id}}, map[string]string{"id": id}, true)
	if rec.Header().Get("HX-Redirect") != "/c/"+id {
		t.Errorf("HX-Redirect=%q want the page itself", rec.Header().Get("HX-Redirect"))
	}
}

func TestRowActions_GenerateTitle(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "")
	rec := e.post(e.h.handleListGenerateTitle, "/chats/"+id+"/title", url.Values{"back": {"/chats"}}, map[string]string{"id": id}, false)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
	if e.conv(t, id).GetTitle() == "" {
		t.Error("no title after generate")
	}
}

func TestRowPartial_States(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "Council: pricing debate")
	path := map[string]string{"id": id}

	body := e.get(e.h.handleRowPartial, "/partials/list/row/"+id+"?state=rename&active="+id, path).Body.String()
	mustContain(t, body, `class="ritem rename"`, `name="title"`, `value="Council: pricing debate"`, `name="back" value="/c/`+id+`"`)

	body = e.get(e.h.handleRowPartial, "/partials/list/row/"+id+"?state=confirm", path).Body.String()
	mustContain(t, body, "Delete “Council: pricing debate”?", `action="/c/`+id+`/delete"`, "Cancel")

	body = e.get(e.h.handleRowPartial, "/partials/list/row/"+id, path).Body.String()
	mustContain(t, body, `class="ritem"`, "Rename", "Generate title", "Archive", "Delete")

	// The no-JS form of the same states: a query on the page.
	page := e.get(e.h.handleChats, "/chats?confirm="+id, nil).Body.String()
	mustContain(t, page, "Delete “Council: pricing debate”?")
}

func TestSearch_TitlesWithArchived(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	e.newConv(t, "Tax documents checklist")
	old := e.newConv(t, "Property tax appeal")
	e.newConv(t, "Unrelated")
	if _, err := e.convos.ArchiveConversation(e.ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: old})); err != nil {
		t.Fatal(err)
	}

	body := e.get(e.h.handleChats, "/chats?q=tax", nil).Body.String()
	mustContain(t, body, "1 result · titles only", "<mark>Tax</mark> documents checklist", `aria-checked="false"`)
	if strings.Contains(body, "Property") || strings.Contains(body, ">Unrelated<") {
		t.Error("search without archived shows archived or unmatched rows")
	}

	body = e.get(e.h.handleChats, "/chats?q=tax&arch=1", nil).Body.String()
	mustContain(t, body, "2 results · titles only", "Property <mark>tax</mark> appeal", `<span class="tag">Archived</span>`, `aria-checked="true"`)
}

func TestSelectAndBulk(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	a, b := e.newConv(t, "Alpha"), e.newConv(t, "Bravo")

	body := e.get(e.h.handleChats, "/chats?select=1", nil).Body.String()
	mustContain(t, body, "0 selected", `name="id" value="`+a+`"`, `action="/chats/bulk"`, "Select all")

	// Select all ticks every row.
	rec := e.post(e.h.handleBulk, "/chats/bulk", url.Values{"action": {"all"}, "back": {"/chats"}}, nil, false)
	mustContain(t, rec.Body.String(), "3 selected")

	// Delete asks first, in the toolbar.
	rec = e.post(e.h.handleBulk, "/chats/bulk", url.Values{"action": {"confirm"}, "id": {a, b}, "back": {"/chats"}}, nil, false)
	mustContain(t, rec.Body.String(), "Delete 2?", `value="delete"`)

	rec = e.post(e.h.handleBulk, "/chats/bulk", url.Values{"action": {"archive"}, "id": {a}, "back": {"/chats"}}, nil, false)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/chats" {
		t.Fatalf("archive: code=%d loc=%q", rec.Code, rec.Header().Get("Location"))
	}
	if e.conv(t, a).GetArchivedAt() == nil {
		t.Error("a not archived")
	}
	e.post(e.h.handleBulk, "/chats/bulk", url.Values{"action": {"delete"}, "id": {b}, "back": {"/chats"}}, nil, false)
	if _, err := e.convos.GetConversation(e.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: b})); err == nil {
		t.Error("b survived bulk delete")
	}
}

func TestCommand_CommandsConversationsSettings(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	e.newConv(t, "Compression summary card")
	conv := e.fx.convID.String()

	body := e.get(e.h.handleCommand, "/partials/command?q=comp&conv="+conv, nil).Body.String()
	mustContain(t, body, `role="listbox"`, "<b>Comp</b>ress this context", "/c/"+conv+"/compact",
		"<b>Comp</b>ression summary card", "<b>Comp</b>action model", "test profile")
	if !strings.Contains(body, `aria-selected="true"`) {
		t.Error("no option highlighted for Enter")
	}

	body = e.get(e.h.handleCommand, "/partials/command?q=zzzz", nil).Body.String()
	mustContain(t, body, "Nothing matches “zzzz”.")

	body = e.get(e.h.handleCommand, "/partials/command?q=", nil).Body.String()
	if strings.Contains(body, "cmd-group") {
		t.Error("empty query returned results")
	}
}

func TestCommandMatching(t *testing.T) {
	got := matchCmds("set", []cmdVM{{Label: "Reset"}, {Label: "Settings"}, {Label: "Other"}}, 5)
	if len(got) != 2 || got[0].Label != "Settings" {
		t.Fatalf("got %+v; want prefix match first, non-matches dropped", got)
	}
	parts := firstHit("comp a comp", "comp")
	if len(parts) != 2 || !parts[0].Hit || parts[1].Hit || parts[1].Text != " a comp" {
		t.Errorf("firstHit=%+v", parts)
	}
}

func TestHighlight(t *testing.T) {
	got := highlight("Sales tax and TAX", "tax")
	want := []hlPart{{"Sales ", false}, {"tax", true}, {" and ", false}, {"TAX", true}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("part %d = %+v want %+v", i, got[i], want[i])
		}
	}
	if highlight("x", "") != nil {
		t.Error("empty query should not highlight")
	}
}

func TestMonthRows(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	at := func(m time.Month, d, y int) *psmithv1.Conversation {
		ts := time.Date(y, m, d, 9, 0, 0, 0, time.UTC)
		return &psmithv1.Conversation{Id: ts.String(), LastActivityAt: timestamppb.New(ts), CreatedAt: timestamppb.New(ts)}
	}
	rows := monthRows(now, []*psmithv1.Conversation{at(11, 2, 2026), at(10, 24, 2026), at(10, 21, 2026), at(8, 4, 2025)}, nil, "", "used")
	groups := []string{rows[0].Group, rows[1].Group, rows[2].Group, rows[3].Group}
	want := []string{"November", "October", "", "August 2025"}
	for i := range want {
		if groups[i] != want[i] {
			t.Errorf("groups=%q want %q", groups, want)
			break
		}
	}
}

func TestDraft_FormAndFirstSend(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	e.fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Hi."}}, Usage: &fakellm.Usage{InputTokens: 5, OutputTokens: 2}})
	pid := e.profileID(t)
	model := modelValue(e.fx.providerID.String(), e.fx.modelID)

	body := e.get(e.h.handleNewForm, "/new?profile="+pid+"&pick="+url.QueryEscape(model)+"&message=Hello", nil).Body.String()
	mustContain(t, body, "Who are you talking to?", `aria-pressed="true"`, `name="profile_id" value="`+pid+`"`,
		"Claude Fake", ">Hello</textarea>", `id="composer"`, `action="/new"`)

	// Sending creates the conversation and opens it on the streaming reply.
	rec := e.post(e.h.handleNewCreate, "/new", url.Values{"profile_id": {pid}, "model": {model}, "message": {"Hello"}}, nil, false)
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(loc, "/c/") || !strings.Contains(loc, "?run=") {
		t.Fatalf("code=%d loc=%q body=%s", rec.Code, loc, rec.Body.String())
	}
	id := strings.TrimPrefix(loc[:strings.Index(loc, "?")], "/c/")
	if s := e.conv(t, id).GetSettings(); s.GetDefaultModelId() != e.fx.modelID {
		t.Errorf("model not remembered on the conversation: %+v", s)
	}

	// No profile id is a bad request.
	if rec := e.post(e.h.handleNewCreate, "/new", url.Values{"message": {"x"}}, nil, false); rec.Code != http.StatusBadRequest {
		t.Errorf("no profile: code=%d", rec.Code)
	}
}

func TestDraft_NoProfiles(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(Deps{Queries: q, Profiles: prof, Logger: slog.Default()})
	uid, _ := uuid.NewV7()
	if _, err := q.CreateUser(context.Background(), store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"}); err != nil {
		t.Fatal(err)
	}
	ctx := auth.ContextWithUser(context.Background(), auth.User{ID: uid, Username: "u"})
	body := do(h.handleNewForm, httptest.NewRequest("GET", "/new", nil).WithContext(ctx)).Body.String()
	mustContain(t, body, "No profiles yet", "Create a profile to start", "Choose model", "disabled")
}

func TestShortcuts(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	conv := e.fx.convID.String()
	body := e.get(e.h.handleShortcuts, "/shortcuts?c="+conv, nil).Body.String()
	mustContain(t, body, "Keyboard shortcuts", "Select conversations", `href="/c/`+conv+`"`, `data-conv="`+conv+`"`)
	body = e.get(e.h.handleShortcuts, "/shortcuts", nil).Body.String()
	mustContain(t, body, "Start a conversation", `href="/chats" aria-label="Close shortcuts (Esc)"`)
}

func TestAccountMenu(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	req := httptest.NewRequest("GET", "/chats", nil).WithContext(e.ctx)
	req.AddCookie(&http.Cookie{Name: modeCookie, Value: "light"})
	body := do(e.h.handleChats, req).Body.String()
	mustContain(t, body, `aria-label="Account: john"`, `action="/prefs/appearance"`, `value="light" role="radio" aria-checked="true"`,
		`action="/logout"`, `data-key="?"`, "Member · ")
}

func TestSignInPage(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Logger: slog.Default()})
	body := do(h.handleLoginForm, httptest.NewRequest("GET", "/login", nil)).Body.String()
	mustContain(t, body, "Sign in to Psmith", `action="/login"`, "Accounts on this server are made by an admin.")

	form := url.Values{"username": {"nobody"}, "password": {"wrong"}}
	req := httptest.NewRequest("POST", "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := do(h.handleLogin, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code=%d", rec.Code)
	}
	mustContain(t, rec.Body.String(), "Invalid username or password.", `value="nobody"`, `aria-invalid="true"`)
}

func TestSetup_Flow(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)

	body := e.get(e.h.handleSetup, "/setup", nil).Body.String()
	mustContain(t, body, "Welcome to Psmith", `value="anthropic" checked`, "Google Gemini", "Any OpenAI-compatible URL", "Step 1 of 3")

	body = e.get(e.h.handleSetupKeyForm, "/setup/key?t=anthropic", nil).Body.String()
	mustContain(t, body, "Native driver · api.anthropic.com", `name="api_key"`, "Test connection", "Step 2 of 3")

	// Continue creates the provider and moves on to its models.
	rec := e.post(e.h.handleSetupKey, "/setup/key", url.Values{"t": {"anthropic"}, "label": {"Mine"}, "api_key": {"sk-x"}, "base_url": {e.fake.URL()}, "action": {"continue"}}, nil, false)
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(loc, "/setup/models?p=") {
		t.Fatalf("code=%d loc=%q body=%s", rec.Code, loc, rec.Body.String())
	}
	u, _ := url.Parse(loc)
	pid := u.Query().Get("p")
	got, err := e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: pid}))
	if err != nil || got.Msg.GetProvider().GetLabel() != "Mine" {
		t.Fatalf("provider not saved: %v", err)
	}

	// A second pass updates the same provider instead of making another.
	rec = e.post(e.h.handleSetupKey, "/setup/key", url.Values{"t": {"anthropic"}, "p": {pid}, "label": {"Renamed"}, "action": {"continue"}}, nil, false)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("update code=%d", rec.Code)
	}
	got, _ = e.models.GetUserModelProvider(e.ctx, connect.NewRequest(&psmithv1.GetUserModelProviderRequest{Id: pid}))
	if got.Msg.GetProvider().GetLabel() != "Renamed" {
		t.Errorf("label=%q", got.Msg.GetProvider().GetLabel())
	}

	// Testing renders the result in place.
	rec = e.post(e.h.handleSetupKey, "/setup/key", url.Values{"t": {"anthropic"}, "p": {pid}, "label": {"Renamed"}, "action": {"test"}}, nil, false)
	mustContain(t, rec.Body.String(), `role="status" class="result`, `name="p" value="`+pid+`"`)

	// Finishing with nothing on asks for a model.
	rec = e.post(e.h.handleSetupModels, "/setup/models", url.Values{"p": {pid}, "t": {"anthropic"}}, nil, false)
	mustContain(t, rec.Body.String(), "Turn on at least one model")

	rec = e.post(e.h.handleSetupModels, "/setup/models", url.Values{"p": {pid}, "model_ids": {"claude-opus-4-7"}}, nil, false)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/chats" {
		t.Fatalf("finish code=%d loc=%q body=%s", rec.Code, rec.Header().Get("Location"), rec.Body.String())
	}
	ms, err := e.models.ListUserModels(e.ctx, connect.NewRequest(&psmithv1.ListUserModelsRequest{UserModelProviderId: pid}))
	if err != nil || len(ms.Msg.GetModels()) != 1 || ms.Msg.GetModels()[0].GetModelId() != "claude-opus-4-7" {
		t.Errorf("enabled models wrong: %v %+v", err, ms)
	}
}

func TestTemplates(t *testing.T) {
	v := tplFrom(&psmithv1.ProviderTemplate{CatalogProviderId: "ollama", Name: "Ollama (local)", DriverType: "openai-compatible", ApiBase: ptr("http://localhost:11434/v1"), PresetId: ptr("ollama")})
	if v.Name != "Ollama" || v.Kind != "Local, OpenAI-compatible" || !v.NeedsURL {
		t.Errorf("ollama template=%+v", v)
	}
	if v := tplFrom(&psmithv1.ProviderTemplate{CatalogProviderId: "openrouter", Name: "OpenRouter", DriverType: "openai-compatible"}); v.Mono != "R" {
		t.Errorf("openrouter mono=%q", v.Mono)
	}
	if got := hostSuffix("https://api.anthropic.com"); got != " · api.anthropic.com" {
		t.Errorf("hostSuffix=%q", got)
	}
	all := []tplVM{{ID: "anthropic", Driver: "anthropic"}, {ID: "groq", Driver: "openai-compatible", Preset: "groq"}, {ID: customTemplate, Driver: "openai-compatible"}}
	if got := templateFor(all, &psmithv1.UserModelProvider{Type: "openai-compatible", Config: []byte(`{"preset_id":"groq"}`)}); got.ID != "groq" {
		t.Errorf("templateFor groq=%q", got.ID)
	}
	if got := templateFor(all, &psmithv1.UserModelProvider{Type: "openai-compatible", Config: []byte(`{}`)}); got.ID != customTemplate {
		t.Errorf("templateFor custom=%q", got.ID)
	}
}

func TestBackURL(t *testing.T) {
	for _, c := range []struct{ back, ref, want string }{
		{"/c/1?f=archived", "", "/c/1?f=archived"},
		{"//evil.example", "/chats?q=x", "/chats?q=x"},
		{"", "", "/chats"},
	} {
		req := httptest.NewRequest("POST", "/x", strings.NewReader(url.Values{"back": {c.back}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if c.ref != "" {
			req.Header.Set("Referer", c.ref)
		}
		if got := backURL(req); got != c.want {
			t.Errorf("backURL(%q, %q)=%q want %q", c.back, c.ref, got, c.want)
		}
	}
	if activeOf("/c/abc/model") != "abc" || activeOf("/chats") != "" {
		t.Error("activeOf")
	}
}
