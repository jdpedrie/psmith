package web

import (
	"net/http"
	"time"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
)

// sessionCookie carries the same opaque session token the RPC clients send as
// a bearer header. The web layer just delivers it via an httpOnly cookie and
// validates it through the identical auth path.
const sessionCookie = "reeve_session"

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
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next(w, r.WithContext(auth.ContextWithUser(r.Context(), u)))
	}
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
	h.render(w, r, http.StatusOK, loginPage(""))
}

func (h *Handler) handleLogin(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.render(w, r, http.StatusBadRequest, loginPage("Bad request."))
		return
	}
	resp, err := h.auth.Login(r.Context(), connect.NewRequest(&reevev1.LoginRequest{
		Username: r.PostFormValue("username"),
		Password: r.PostFormValue("password"),
	}))
	if err != nil {
		h.render(w, r, http.StatusUnauthorized, loginPage("Invalid username or password."))
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
	http.Redirect(w, r, "/chats", http.StatusSeeOther)
}

func (h *Handler) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}
