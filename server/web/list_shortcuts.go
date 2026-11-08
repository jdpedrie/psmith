package web

import "net/http"

// handleShortcuts opens the keyboard shortcuts beside the conversation named
// by ?c, or beside the start page.
func (h *Handler) handleShortcuts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.URL.Query().Get("c")
	l := h.loadList(ctx, r, id, "")
	if id != "" {
		c, err := h.loadConversation(ctx, r, id)
		if err == nil {
			c.RunID = h.activeRunID(r, id)
			h.render(w, r, http.StatusOK, shortcutsScreen(l, &c, welcomeVM{}))
			return
		}
		l.ActiveID = ""
	}
	h.render(w, r, http.StatusOK, shortcutsScreen(l, nil, h.loadWelcome(ctx, l)))
}
