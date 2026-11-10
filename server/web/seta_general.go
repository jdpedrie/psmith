package web

import (
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// --- General ---

// pwFlashCookie carries "Password changed" across the redirect after a
// change, once: a query string would say it again on every reload.
const pwFlashCookie = "psmith_pw_changed"

func (h *Handler) handleGeneral(w http.ResponseWriter, r *http.Request) {
	st := generalState{Warn: r.URL.Query().Get("warn")}
	if c, err := r.Cookie(pwFlashCookie); err == nil && c.Value == "1" {
		st.Pw = &testVM{OK: true, Message: "Password changed just now"}
		http.SetCookie(w, &http.Cookie{Name: pwFlashCookie, Value: "", Path: "/settings/general", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: r.TLS != nil})
	}
	h.renderGeneral(w, r, http.StatusOK, st)
}

// generalState is what a General render carries beyond the stored values:
// the warning choice and the number typed for Custom, a refused warning,
// and the password form's outcome.
type generalState struct {
	Index      bool
	Warn       string
	WarnCustom string
	WarnError  string
	Pw         *testVM
}

func (h *Handler) renderGeneral(w http.ResponseWriter, r *http.Request, status int, st generalState) {
	ctx := r.Context()
	g := generalVM{Index: st.Index, Server: r.Host, Version: auth.BuildVersion(), PwResult: st.Pw, WarnSel: "0"}
	if u, ok := auth.FromContext(ctx); ok {
		g.Login, g.UserName, g.Admin = u.Username, u.Username, u.IsAdmin
		if u.DisplayName != nil && *u.DisplayName != "" {
			g.UserName = *u.DisplayName
		}
	}
	if g.UserName != "" {
		g.Initial = strings.ToUpper(g.UserName[:1])
	}
	if h.prefs != nil {
		if resp, err := h.prefs.GetPreferences(ctx, connect.NewRequest(&psmithv1.GetPreferencesRequest{})); err == nil {
			g.WarnSel, g.WarnCustom = saWarnChoice(resp.Msg.GetPreferences().GetContextWarningTokens())
		}
	}
	if st.Warn == "custom" {
		g.WarnSel = "custom"
	}
	if st.WarnError != "" {
		g.WarnCustom, g.WarnError = st.WarnCustom, st.WarnError
	}
	h.render(w, r, status, generalScreen(h.loadSnav(ctx, r, "general"), g))
}

// saWarnChoice maps a stored threshold to the select's option, falling back to
// Custom for values the list doesn't carry.
func saWarnChoice(tokens int32) (sel, custom string) {
	v := strconv.Itoa(int(tokens))
	if slices.ContainsFunc(saWarnOpts, func(o saOpt) bool { return o.Value == v }) {
		return v, ""
	}
	return "custom", saGroupInt(int64(tokens))
}

func (h *Handler) handleWarningSave(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	sel := r.PostFormValue("warn")
	var tokens int32
	if sel == "custom" {
		raw := r.PostFormValue("custom")
		if strings.TrimSpace(raw) == "" {
			// Custom chosen with no number yet: show the field and wait.
			http.Redirect(w, r, "/settings/general?warn=custom", http.StatusSeeOther)
			return
		}
		n, err := saParseInt("The warning", raw)
		if err == nil && *n < 0 {
			err = errors.New("The warning can’t be below zero")
		}
		if err != nil {
			h.renderGeneral(w, r, http.StatusUnprocessableEntity, generalState{Warn: "custom", WarnCustom: raw, WarnError: err.Error()})
			return
		}
		tokens = *n
	} else {
		n, err := strconv.Atoi(sel)
		if err != nil || n < 0 {
			http.Error(w, "bad warning", http.StatusBadRequest)
			return
		}
		tokens = int32(n)
	}
	if _, err := h.prefs.UpdatePreferences(r.Context(), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: &tokens})); err != nil {
		http.Error(w, saErrMsg(err), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/general", http.StatusSeeOther)
}

func (h *Handler) handlePasswordChange(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	cur, nw, conf := r.PostFormValue("current"), r.PostFormValue("new"), r.PostFormValue("confirm")
	fail := func(msg string) {
		h.renderGeneral(w, r, http.StatusUnprocessableEntity, generalState{Pw: &testVM{Message: msg}})
	}
	switch {
	case nw == "":
		fail("Enter a new password")
		return
	case nw != conf:
		fail("The new passwords don’t match")
		return
	}
	if _, err := h.auth.ChangePassword(r.Context(), connect.NewRequest(&psmithv1.ChangePasswordRequest{OldPassword: cur, NewPassword: nw})); err != nil {
		if connect.CodeOf(err) == connect.CodeUnauthenticated {
			fail("The current password is wrong")
			return
		}
		fail(saErrMsg(err))
		return
	}
	http.SetCookie(w, &http.Cookie{Name: pwFlashCookie, Value: "1", Path: "/settings/general", MaxAge: 60, HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: r.TLS != nil})
	http.Redirect(w, r, "/settings/general", http.StatusSeeOther)
}

// --- Appearance ---

// Text size and turn details are per browser, like theme and mode, and live
// in cookies beside them.
const (
	textSizeCookie = "psmith_text"
	turnsCookie    = "psmith_turns"
)

type saDisplayPrefs struct {
	TextSize int  // percent, 80 to 160
	Turns    bool // show turn details on every reply
}

func saReadDisplayPrefs(r *http.Request) saDisplayPrefs {
	p := saDisplayPrefs{TextSize: 100}
	if c, err := r.Cookie(textSizeCookie); err == nil {
		if n, err := strconv.Atoi(c.Value); err == nil && n >= 80 && n <= 160 {
			p.TextSize = n
		}
	}
	if c, err := r.Cookie(turnsCookie); err == nil {
		p.Turns = c.Value == "1"
	}
	return p
}

func (h *Handler) handleAppearancePage(w http.ResponseWriter, r *http.Request) {
	ui, dp := readPrefs(r), saReadDisplayPrefs(r)
	a := appearanceVM{Mode: ui.Mode, TextSize: dp.TextSize, Turns: dp.Turns}
	for _, id := range themeIDs {
		a.Themes = append(a.Themes, themeCardVM{ID: id, Name: themeNames[id], Blurb: saThemeBlurbs[id], On: id == ui.Theme})
	}
	h.render(w, r, http.StatusOK, appearanceScreen(h.loadSnav(r.Context(), r, "appearance"), a))
}

// handleDisplayPrefs stores text size and turn details. Either may be absent
// to leave it alone. Script readers aren't kept out: the client applies the
// text size before first paint from this cookie.
func (h *Handler) handleDisplayPrefs(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	set := func(name, v string) {
		http.SetCookie(w, &http.Cookie{Name: name, Value: v, Path: "/", MaxAge: int((365 * 24 * time.Hour).Seconds()), SameSite: http.SameSiteLaxMode, Secure: r.TLS != nil})
	}
	if v := r.PostFormValue("text_size"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 80 || n > 160 {
			http.Error(w, "text size must be 80 to 160", http.StatusBadRequest)
			return
		}
		set(textSizeCookie, strconv.Itoa(n))
	}
	switch r.PostFormValue("turn_details") {
	case "true":
		set(turnsCookie, "1")
	case "false":
		set(turnsCookie, "0")
	}
	if r.Header.Get("HX-Request") != "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/settings/appearance", http.StatusSeeOther)
}
