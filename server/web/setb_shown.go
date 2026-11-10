package web

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/a-h/templ"

	"github.com/jdpedrie/psmith/server/auth"
)

// A refused save or a Test answers a POST, and rendering that answer at
// the POST's URL means a refresh posts again: the browser asks to resend,
// and saying yes saves or tests a second time. Instead the page is rendered
// as it would have been, kept here briefly, and the POST redirects to the
// page's own URL with ?shown=<token>. Loading that URL serves the kept page,
// so what was typed, the error and the save bar all survive, and a refresh
// is a GET.
//
// The kept copy belongs to the user who posted and to the path it was
// rendered for. It is held in memory, so a restart or an expired token
// falls back to the page as stored, which is what a refresh would show
// anyway once the moment has passed.

const (
	shownTTL = 10 * time.Minute
	shownMax = 512
)

type shownPage struct {
	user string
	path string
	body []byte
	at   time.Time
}

var shownPages = struct {
	sync.Mutex
	m map[string]shownPage
}{m: map[string]shownPage{}}

// showAfterPost renders c for the page at `at` (a path, with a query when
// the page needs one) and redirects there to show it.
func (h *Handler) showAfterPost(w http.ResponseWriter, r *http.Request, at string, c templ.Component) {
	u, _ := auth.FromContext(r.Context())
	var buf bytes.Buffer
	if err := c.Render(withPrefs(r.Context(), readPrefs(r)), &buf); err != nil {
		h.logger.Warn("web: render failed", "err", err)
	}
	path, _, _ := strings.Cut(at, "?")
	tok := keepShown(shownPage{user: u.ID.String(), path: path, body: buf.Bytes(), at: time.Now()})
	http.Redirect(w, r, at+sbSep(at)+"shown="+tok, http.StatusSeeOther)
}

// answer renders a page from a handler both GETs and POSTs share: a GET
// gets it directly, a POST through showAfterPost at `at`.
func (h *Handler) answer(w http.ResponseWriter, r *http.Request, at string, status int, c templ.Component) {
	if r.Method == http.MethodPost {
		h.showAfterPost(w, r, at, c)
		return
	}
	h.render(w, r, status, c)
}

func keepShown(p shownPage) string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	tok := hex.EncodeToString(b)
	shownPages.Lock()
	defer shownPages.Unlock()
	for k, v := range shownPages.m {
		if p.at.Sub(v.at) > shownTTL {
			delete(shownPages.m, k)
		}
	}
	if len(shownPages.m) >= shownMax {
		var oldest string
		for k, v := range shownPages.m {
			if oldest == "" || v.at.Before(shownPages.m[oldest].at) {
				oldest = k
			}
		}
		delete(shownPages.m, oldest)
	}
	shownPages.m[tok] = p
	return tok
}

// shownOr serves a kept page when the request names one this user may see
// at this path, and next otherwise.
func (h *Handler) shownOr(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := r.URL.Query().Get("shown")
		if tok == "" || r.URL.Query().Get("fragment") != "" {
			next(w, r)
			return
		}
		u, _ := auth.FromContext(r.Context())
		shownPages.Lock()
		p, ok := shownPages.m[tok]
		shownPages.Unlock()
		if !ok || p.user != u.ID.String() || p.path != r.URL.Path || time.Since(p.at) > shownTTL {
			next(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(p.body)
	}
}
