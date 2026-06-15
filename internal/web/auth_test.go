package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestCookieAuth proves the cookie session round-trip: a form login sets the
// session cookie, requireUser admits a request carrying it, and rejects one
// without it. The streaming/page tests set the user in context directly; this
// covers the cookie path that wires them together in production.
func TestCookieAuth(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	h := New(q, auth.NewService(q), nil, nil, nil, slog.Default())

	hash, err := bcrypt.GenerateFromPassword([]byte("s3cret"), bcrypt.DefaultCost)
	if err != nil {
		t.Fatalf("bcrypt: %v", err)
	}
	uid, _ := uuid.NewV7()
	if _, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uid, Username: t.Name(), PasswordHash: string(hash),
	}); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	// Log in.
	form := url.Values{"username": {t.Name()}, "password": {"s3cret"}}
	loginReq := httptest.NewRequest("POST", "/login", strings.NewReader(form.Encode()))
	loginReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	loginRec := httptest.NewRecorder()
	h.handleLogin(loginRec, loginReq)

	if loginRec.Code != http.StatusSeeOther {
		t.Fatalf("login status=%d want 303; body:\n%s", loginRec.Code, loginRec.Body.String())
	}
	var sess *http.Cookie
	for _, c := range loginRec.Result().Cookies() {
		if c.Name == sessionCookie {
			sess = c
		}
	}
	if sess == nil || sess.Value == "" {
		t.Fatal("login did not set a session cookie")
	}
	if !sess.HttpOnly {
		t.Error("session cookie should be HttpOnly")
	}

	// A request with the cookie is admitted.
	admitted := false
	protected := h.requireUser(func(w http.ResponseWriter, r *http.Request) {
		admitted = true
		if _, ok := h.currentUser(r); !ok {
			t.Error("requireUser admitted but no user resolvable")
		}
		w.WriteHeader(http.StatusOK)
	})

	okReq := httptest.NewRequest("GET", "/chats", nil)
	okReq.AddCookie(sess)
	okRec := httptest.NewRecorder()
	protected(okRec, okReq)
	if !admitted || okRec.Code != http.StatusOK {
		t.Fatalf("authed request rejected: admitted=%v code=%d", admitted, okRec.Code)
	}

	// A request without the cookie is redirected to login.
	noReq := httptest.NewRequest("GET", "/chats", nil)
	noRec := httptest.NewRecorder()
	protected(noRec, noReq)
	if noRec.Code != http.StatusSeeOther || noRec.Header().Get("Location") != "/login" {
		t.Errorf("unauthed request: code=%d location=%q want 303 -> /login", noRec.Code, noRec.Header().Get("Location"))
	}
}
