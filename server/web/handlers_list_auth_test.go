package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/psmith/server/store"
)

// Sign out ends the session on the server, not just in this browser: the
// old cookie stops working.
func TestSignOut_RevokesTheSession(t *testing.T) {
	e := newListEnv(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("pw"), bcrypt.MinCost)
	if err := e.q.UpdateUserPassword(context.Background(), store.UpdateUserPasswordParams{ID: e.fx.userID, PasswordHash: string(hash)}); err != nil {
		t.Fatal(err)
	}
	user, err := e.q.GetUserByID(context.Background(), e.fx.userID)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	e.h.Mount(mux)

	login := httptest.NewRequest("POST", "/login", strings.NewReader(url.Values{"username": {user.Username}, "password": {"pw"}}.Encode()))
	login.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, login)
	var session *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie {
			session = c
		}
	}
	if session == nil || session.Value == "" {
		t.Fatalf("login set no session cookie (status %d)", rec.Code)
	}

	signedIn := func() bool {
		req := httptest.NewRequest("GET", "/chats", nil)
		req.AddCookie(session)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code == http.StatusOK
	}
	if !signedIn() {
		t.Fatal("the new session doesn't open /chats")
	}

	out := httptest.NewRequest("POST", "/logout", nil)
	out.AddCookie(session)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, out)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/login" {
		t.Fatalf("logout answered %d → %q", rec.Code, rec.Header().Get("Location"))
	}
	if signedIn() {
		t.Error("the session still works after signing out")
	}
}

// A signed-out visit to a page comes back to that page after signing in,
// so a bookmarked conversation opens the conversation.
func TestSignIn_ReturnsToThePageAsked(t *testing.T) {
	e := newListEnv(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("pw"), bcrypt.MinCost)
	if err := e.q.UpdateUserPassword(context.Background(), store.UpdateUserPasswordParams{ID: e.fx.userID, PasswordHash: string(hash)}); err != nil {
		t.Fatal(err)
	}
	user, _ := e.q.GetUserByID(context.Background(), e.fx.userID)
	mux := http.NewServeMux()
	e.h.Mount(mux)
	serve := func(req *http.Request) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}

	page := "/c/" + e.fx.convID.String() + "?tab=info"
	visit := httptest.NewRequest("GET", page, nil)
	visit.Header.Set("Accept", "text/html,application/xhtml+xml")
	rec := serve(visit)
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || loc != "/login?next="+url.QueryEscape(page) {
		t.Fatalf("signed-out visit: %d → %q", rec.Code, loc)
	}
	form := serve(httptest.NewRequest("GET", loc, nil)).Body.String()
	mustContain(t, form, `name="next" value="`+strings.ReplaceAll(page, "&", "&amp;")+`"`)

	login := func(next string) string {
		req := httptest.NewRequest("POST", "/login", strings.NewReader(url.Values{"username": {user.Username}, "password": {"pw"}, "next": {next}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		return serve(req).Header().Get("Location")
	}
	if got := login(page); got != page {
		t.Errorf("after signing in: → %q, want %q", got, page)
	}
	for _, bad := range []string{"//evil.example/x", "https://evil.example/", "/\\evil.example", "javascript:alert(1)"} {
		if got := login(bad); got != "/chats" {
			t.Errorf("next=%q sent the browser to %q", bad, got)
		}
	}

	// The event stream reconnecting signed out isn't a page to return to.
	ev := httptest.NewRequest("GET", "/events", nil)
	ev.Header.Set("Accept", "text/event-stream")
	if got := serve(ev).Header().Get("Location"); got != "/login" {
		t.Errorf("signed-out event stream → %q, want plain /login", got)
	}

	// A failed attempt keeps where it was going.
	req := httptest.NewRequest("POST", "/login", strings.NewReader(url.Values{"username": {user.Username}, "password": {"nope"}, "next": {page}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	mustContain(t, serve(req).Body.String(), `name="next" value="`+strings.ReplaceAll(page, "&", "&amp;")+`"`)

	// An htmx request from a page whose session ended reloads into sign in
	// rather than swapping the sign-in page into a fragment.
	req = httptest.NewRequest("GET", "/partials/list?active="+e.fx.convID.String(), nil)
	req.Header.Set("HX-Request", "true")
	req.Header.Set("HX-Current-URL", "http://example.com"+page)
	rec = serve(req)
	if got := rec.Header().Get("HX-Redirect"); got != "/login?next="+url.QueryEscape(page) {
		t.Errorf("htmx request without a session: HX-Redirect %q (status %d)", got, rec.Code)
	}
}
