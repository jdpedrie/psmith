package web

import (
	"context"
	"hash/fnv"
	"net/http"
	"slices"
	"strconv"
	"time"
)

// Appearance is per browser, like it is per device on Mac and iOS: a theme id
// and a mode ("auto" follows the system). Both live in cookies so the server
// renders the right colors on the first byte; there is no flash to fix up.

var themeIDs = []string{"system", "sage", "clay", "slate", "aubergine", "nordic"}

var themeNames = map[string]string{
	"system": "System", "sage": "Sage & Graphite", "clay": "Clay & Ink", "slate": "Slate Pro", "aubergine": "Aubergine & Cream", "nordic": "Nordic Mist",
}

const (
	themeCookie = "psmith_theme"
	modeCookie  = "psmith_mode"
)

type uiPrefs struct {
	Theme       string // one of themeIDs
	Mode        string // "auto", "light" or "dark"
	TextSize    int    // percent, 80-160; 100 is the default
	TurnDetails bool   // show every reply's thinking, tool and usage chips
}

func readPrefs(r *http.Request) uiPrefs {
	p := uiPrefs{Theme: "system", Mode: "auto", TextSize: 100}
	if c, err := r.Cookie(themeCookie); err == nil && slices.Contains(themeIDs, c.Value) {
		p.Theme = c.Value
	}
	if c, err := r.Cookie(modeCookie); err == nil && (c.Value == "light" || c.Value == "dark") {
		p.Mode = c.Value
	}
	if c, err := r.Cookie("psmith_text"); err == nil {
		if n, err := strconv.Atoi(c.Value); err == nil && n >= 80 && n <= 160 {
			p.TextSize = n
		}
	}
	if c, err := r.Cookie("psmith_turns"); err == nil && c.Value == "1" {
		p.TurnDetails = true
	}
	return p
}

type prefsKey struct{}

func withPrefs(ctx context.Context, p uiPrefs) context.Context {
	return context.WithValue(ctx, prefsKey{}, p)
}

func prefsOf(ctx context.Context) uiPrefs {
	if p, ok := ctx.Value(prefsKey{}).(uiPrefs); ok {
		return p
	}
	return uiPrefs{Theme: "system", Mode: "auto", TextSize: 100}
}

// handleAppearance stores the theme and mode. Either field may be absent to
// leave it alone. htmx callers get 204 (the page already switched itself);
// plain posts go back where they came from.
func (h *Handler) handleAppearance(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	set := func(name, v string) {
		http.SetCookie(w, &http.Cookie{Name: name, Value: v, Path: "/", MaxAge: int((365 * 24 * time.Hour).Seconds()), SameSite: http.SameSiteLaxMode, HttpOnly: true, Secure: r.TLS != nil})
	}
	if t := r.FormValue("theme"); slices.Contains(themeIDs, t) {
		set(themeCookie, t)
	}
	switch m := r.FormValue("mode"); m {
	case "auto", "light", "dark":
		set(modeCookie, m)
	}
	if r.Header.Get("HX-Request") != "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	back := "/settings/appearance"
	if ref := r.Header.Get("Referer"); ref != "" {
		back = ref
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}

// profileColor is a profile's slot in the six-color palette (1-6), the same
// FNV-1a hash iOS uses, so a profile wears one color on every client.
func profileColor(id string) int {
	if id == "" {
		return 0
	}
	h := fnv.New64a()
	_, _ = h.Write([]byte(id))
	return int(h.Sum64()%6) + 1
}

// zoomStyle scales the page for a text size other than 100%. Rendered on the
// root element so the first paint is already the right size.
func zoomStyle(p uiPrefs) string {
	if p.TextSize == 100 || p.TextSize == 0 {
		return ""
	}
	return "zoom:" + strconv.FormatFloat(float64(p.TextSize)/100, 'f', 2, 64)
}
