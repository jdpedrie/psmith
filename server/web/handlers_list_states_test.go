package web

import (
	"context"
	"bytes"
	"mime/multipart"
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
	"github.com/jdpedrie/psmith/server/store"
)

// A ListConversations that fails says so, with the reason and a way to try
// again (board ListLoadError), instead of an empty column.
func TestListStates_LoadErrorSaysSo(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	body := e.get(e.h.handleChats, "/chats?f=not-a-profile", nil).Body.String()
	mustContain(t, body, `class="empty load-error" role="alert"`, "Couldn’t load conversations", "invalid profile_id", `>Try again`, `href="/chats?f=not-a-profile"`)

	// Searching fails the same way rather than reading "No titles match".
	body = e.get(e.h.handleChats, "/chats?f=not-a-profile&q=x", nil).Body.String()
	mustContain(t, body, "Couldn’t load conversations")
	if strings.Contains(body, "No titles match") {
		t.Error("a failed search reads as no matches")
	}
}

// An account whose conversations are all archived isn't new (board
// ListEmptyArchive): the list says nothing is active and opens the archive,
// and the start page doesn't greet it as a first-timer.
func TestListStates_EverythingArchived(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	b := e.newConv(t, "Second")
	for _, id := range []string{e.fx.convID.String(), b} {
		if _, err := e.convos.ArchiveConversation(e.ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: id})); err != nil {
			t.Fatal(err)
		}
	}
	body := e.get(e.h.handleChats, "/chats", nil).Body.String()
	mustContain(t, body, "No active conversations", `href="/chats?f=archived"`, `Archived<span class="n">2</span>`, "Start a conversation")
	for _, bad := range []string{"No conversations yet", "Start your first conversation"} {
		if strings.Contains(body, bad) {
			t.Errorf("an account with an archive reads %q", bad)
		}
	}
}

// A profile chip with nothing in it says so and offers a conversation with
// that profile (board ListEmptyFilter); the Archived chip with nothing
// archived says that.
func TestListStates_EmptyFilters(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	p, err := e.h.profiles.CreateProfile(e.ctx, connect.NewRequest(&psmithv1.CreateProfileRequest{Name: "Pirate tutor"}))
	if err != nil {
		t.Fatal(err)
	}
	pid := p.Msg.GetProfile().GetId()
	body := e.get(e.h.handleChats, "/chats?f="+pid, nil).Body.String()
	mustContain(t, body, "Nothing in Pirate tutor", `href="/new?profile=`+pid+`"`, "New conversation")

	body = e.get(e.h.handleChats, "/chats?f=archived", nil).Body.String()
	mustContain(t, body, "Nothing archived", "Archived conversations show up here.")
}

// Archived rows offer Delete beside Unarchive, as the Mac's archive does.
// It confirms in place, without the "Archive keeps it" advice that makes
// no sense for an archived conversation, and deletes.
func TestListStates_ArchivedRowsDelete(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	id := e.newConv(t, "Old notes")
	if _, err := e.convos.ArchiveConversation(e.ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: id})); err != nil {
		t.Fatal(err)
	}
	body := e.get(e.h.handleChats, "/chats?f=archived", nil).Body.String()
	mustContain(t, body, `class="rdel"`, `href="/chats?deleting=`+id+`&amp;f=archived"`, `aria-label="Delete Old notes"`)

	body = e.get(e.h.handleChats, "/chats?f=archived&deleting="+id, nil).Body.String()
	mustContain(t, body, "Delete “Old notes”?", "This can’t be undone.")
	if strings.Contains(body, "Archive keeps it out of the list") {
		t.Error("an archived row's confirm suggests archiving it")
	}

	rec := e.post(e.h.handleConversationDelete, "/c/"+id+"/delete", url.Values{"back": {"/chats?f=archived"}}, map[string]string{"id": id}, false)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body.String())
	}
	if _, err := e.convos.GetConversation(e.ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: id})); err == nil {
		t.Error("the archived conversation survived Delete")
	}
}

// Rows carry their newest message's time, which list.js watches to mark a
// reply that landed while its conversation wasn't open, and whether a reply
// is live, which holds the mark back until it's done.
func TestListStates_RowsCarryActivity(t *testing.T) {
	t.Parallel()
	l := listVM{Filter: "all"}
	var b strings.Builder
	if err := rowItem(l, rowVM{ID: "a", Title: "A", Live: true, Activity: 1762700000000}).Render(context.Background(), &b); err != nil {
		t.Fatal(err)
	}
	mustContain(t, b.String(), `data-id="a" data-live data-at="1762700000000"`)
}

// An account with a provider but no model turned on can't chat, so /chats
// resumes setup at that provider's models instead of opening an app with
// nothing to send with.
func TestListStates_NoModelResumesSetup(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	uid, _ := uuid.NewV7()
	if _, err := e.q.CreateUser(context.Background(), store.CreateUserParams{ID: uid, Username: t.Name() + "-nomodel", PasswordHash: "x"}); err != nil {
		t.Fatal(err)
	}
	prid, _ := uuid.NewV7()
	if _, err := e.q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{ID: prid, UserID: uid, Type: "anthropic", Label: "Mine", ConfigEncrypted: []byte(`{"api_key":"x"}`)}); err != nil {
		t.Fatal(err)
	}
	ctx := auth.ContextWithUser(context.Background(), auth.User{ID: uid, Username: "u"})
	rec := do(e.h.handleChats, httptest.NewRequest("GET", "/chats", nil).WithContext(ctx))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/setup/models?p="+prid.String() {
		t.Fatalf("code=%d loc=%q, want 303 /setup/models?p=%s", rec.Code, rec.Header().Get("Location"), prid)
	}

	// The seeded account has an enabled model and stays in the app.
	if rec := e.get(e.h.handleChats, "/chats", nil); rec.Code != http.StatusOK {
		t.Errorf("an account with a model: code=%d", rec.Code)
	}
}

// A profile with no model of its own starts the draft on the model the
// conversation's composer would use, named in the header and carried by
// the send, rather than "Choose model" and a send the server refuses.
func TestListStates_DraftNamesTheModelItWillUse(t *testing.T) {
	t.Parallel()
	e := newListEnv(t)
	body := e.get(e.h.handleNewForm, "/new", nil).Body.String()
	want := modelValue(e.fx.providerID.String(), e.fx.modelID)
	mustContain(t, body, `<span data-model-name>Claude Fake</span>`, `name="model" value="`+want+`" data-draft-model`, `data-model="`+want+`"`)
	if strings.Contains(body, "Choose model") {
		t.Error("the draft says Choose model though it has one to send with")
	}

	// Sending from it starts a run instead of failing.
	e.fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Ahoy", Delay: 10 * time.Millisecond}}})
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range map[string]string{"profile_id": e.profileID(t), "model": want, "message": "Hello"} {
		_ = mw.WriteField(k, v)
	}
	_ = mw.Close()
	req := httptest.NewRequest("POST", "/new", &buf).WithContext(e.ctx)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if loc := do(e.h.handleNewCreate, req).Header().Get("Location"); !strings.Contains(loc, "?run=") {
		t.Fatalf("first send went to %q", loc)
	}
}
