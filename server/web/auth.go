package web

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// signInVM is the sign-in page. A failed attempt keeps the username and
// clears the password.
type signInVM struct {
	Server    string
	Username  string
	Password  string // fixtures only: the board draws a filled field
	Error     string
	ShowFocus bool   // draw the password field focused (fixtures)
	Next      string // the page to open after signing in
}

// sessionCookie carries the same opaque session token the RPC clients send as
// a bearer header. The web layer just delivers it via an httpOnly cookie and
// validates it through the identical auth path.
const sessionCookie = "psmith_session"

// currentUser resolves the session cookie to a user, or reports not-authed.
func (h *Handler) currentUser(r *http.Request) (auth.User, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return auth.User{}, false
	}
	u, err := auth.AuthenticateBearer(r.Context(), h.queries, "Bearer "+c.Value)
	if err != nil {
		return auth.User{}, false
	}
	return u, true
}

// requireUser gates a handler behind a valid session, attaching the user to
// the request context so the in-process service calls see it the same way the
// interceptor would.
func (h *Handler) requireUser(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, ok := h.currentUser(r)
		if !ok {
			h.toSignIn(w, r)
			return
		}
		next(w, r.WithContext(auth.ContextWithUser(r.Context(), u)))
	}
}

// toSignIn sends a signed-out request to sign in, remembering the page it
// was for. Only a page load counts (it asks for HTML); the event stream
// and fetches don't, or signing in would land on /events. An htmx request
// names its page in HX-Current-URL and gets an HX-Redirect, so the sign-in
// page loads whole instead of into a fragment.
func (h *Handler) toSignIn(w http.ResponseWriter, r *http.Request) {
	next := ""
	if r.Header.Get("HX-Request") != "" {
		if u, err := url.Parse(r.Header.Get("HX-Current-URL")); err == nil {
			next = u.RequestURI()
		}
	} else if r.Method == http.MethodGet && strings.Contains(r.Header.Get("Accept"), "text/html") {
		next = r.URL.RequestURI()
	}
	dest := "/login"
	if next = safeNext(next); next != "" {
		dest += "?next=" + url.QueryEscape(next)
	}
	if r.Header.Get("HX-Request") != "" {
		w.Header().Set("HX-Redirect", dest)
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	http.Redirect(w, r, dest, http.StatusSeeOther)
}

// safeNext keeps next only when it is a path on this site; anything else
// (another host, a scheme, a protocol-relative or backslashed path) is "".
func safeNext(next string) string {
	if !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") || strings.Contains(next, "\\") {
		return ""
	}
	u, err := url.Parse(next)
	if err != nil || u.Scheme != "" || u.Host != "" || next == "/" {
		return ""
	}
	return next
}

func (h *Handler) handleHome(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.currentUser(r); ok {
		http.Redirect(w, r, "/chats", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (h *Handler) handleLoginForm(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.currentUser(r); ok {
		http.Redirect(w, r, "/chats", http.StatusSeeOther)
		return
	}
	h.render(w, r, http.StatusOK, signInScreen(signInVM{Server: r.Host, Next: safeNext(r.URL.Query().Get("next"))}))
}

func (h *Handler) handleLogin(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.render(w, r, http.StatusBadRequest, signInScreen(signInVM{Server: r.Host, Error: "Bad request."}))
		return
	}
	resp, err := h.auth.Login(r.Context(), connect.NewRequest(&psmithv1.LoginRequest{
		Username: r.PostFormValue("username"),
		Password: r.PostFormValue("password"),
	}))
	if err != nil {
		h.render(w, r, http.StatusUnauthorized, signInScreen(signInVM{Server: r.Host, Username: r.PostFormValue("username"), Error: "Invalid username or password.", Next: safeNext(r.PostFormValue("next"))}))
		return
	}
	exp := time.Now().Add(24 * time.Hour)
	if t := resp.Msg.GetExpiresAt(); t != nil {
		exp = t.AsTime()
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    resp.Msg.GetSessionToken(),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   r.TLS != nil,
		Expires:  exp,
	})
	dest := "/chats"
	if next := safeNext(r.PostFormValue("next")); next != "" {
		dest = next
	}
	http.Redirect(w, r, dest, http.StatusSeeOther)
}

// handleLogout revokes the session on the server, as the apps' Logout does,
// so a copied cookie stops working too, then clears it here.
func (h *Handler) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil && c.Value != "" && h.auth != nil {
		req := connect.NewRequest(&psmithv1.LogoutRequest{})
		req.Header().Set("Authorization", "Bearer "+c.Value)
		if _, err := h.auth.Logout(r.Context(), req); err != nil {
			h.logger.Warn("web: revoke session failed", "err", err)
		}
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}
