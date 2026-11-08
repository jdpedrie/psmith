package web

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The list's row actions are plain form posts carrying the page they came
// from in "back". Without JS they redirect there; with htmx they answer
// with the refreshed list column for that page.

// backURL is where an action returns to: the form's back field, then the
// Referer, then /chats. Only same-site paths count.
func backURL(r *http.Request) string {
	for _, cand := range []string{r.FormValue("back"), r.Header.Get("HX-Current-URL"), r.Header.Get("Referer")} {
		if cand == "" {
			continue
		}
		u, err := url.Parse(cand)
		if err != nil {
			continue
		}
		if (u.Scheme != "" || u.Host != "") && u.Host != r.Host {
			continue
		}
		p := u.Path
		if !strings.HasPrefix(p, "/") || strings.HasPrefix(p, "//") {
			continue
		}
		if u.RawQuery != "" {
			p += "?" + u.RawQuery
		}
		return p
	}
	return "/chats"
}

// activeOf reads the open conversation from a page path (/c/{id}).
func activeOf(path string) string {
	if rest, ok := strings.CutPrefix(path, "/c/"); ok {
		id, _, _ := strings.Cut(rest, "/")
		return id
	}
	return ""
}

// listAt builds the list column as it would render on the page at dest,
// dropping one-shot row states so the swapped-in list is at rest.
func (h *Handler) listAt(ctx context.Context, r *http.Request, dest string) listVM {
	u, err := url.Parse(dest)
	if err != nil {
		u = &url.URL{Path: "/chats"}
	}
	q := u.Query()
	q.Del("rename")
	q.Del("confirm")
	u.RawQuery = q.Encode()
	rr := r.Clone(ctx)
	rr.URL = u
	return h.loadList(ctx, rr, activeOf(u.Path), "")
}

// afterAction answers a row action on conversation id. away is true when
// the action leaves that conversation unusable where it was open (delete),
// so a page showing it moves to the list.
func (h *Handler) afterAction(w http.ResponseWriter, r *http.Request, id string, away bool) {
	dest := backURL(r)
	u, _ := url.Parse(dest)
	if away && u != nil && activeOf(u.Path) == id {
		dest = "/chats"
	}
	if r.Header.Get("HX-Request") == "" {
		http.Redirect(w, r, dest, http.StatusSeeOther)
		return
	}
	if u != nil && activeOf(u.Path) == id {
		// The open conversation changed under its page (archived, deleted):
		// the page itself has to reload, not just the list.
		w.Header().Set("HX-Redirect", dest)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	h.render(w, r, http.StatusOK, listColumn(h.listAt(r.Context(), r, dest)))
}

func (h *Handler) actionFailed(w http.ResponseWriter, err error) {
	http.Error(w, friendlyError(err), connectStatus(err))
}

// connectStatus maps a service error onto an HTTP status.
func connectStatus(err error) int {
	switch connect.CodeOf(err) {
	case connect.CodeNotFound:
		return http.StatusNotFound
	case connect.CodeInvalidArgument, connect.CodeFailedPrecondition:
		return http.StatusBadRequest
	case connect.CodePermissionDenied:
		return http.StatusForbidden
	}
	return http.StatusInternalServerError
}

// handlePinToggle pins or unpins based on the conversation's current
// state: one affordance, no client-side state tracking.
func (h *Handler) handlePinToggle(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: id}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	if getResp.Msg.GetConversation().GetPinnedAt() != nil {
		_, err = h.convos.UnpinConversation(r.Context(), connect.NewRequest(&psmithv1.UnpinConversationRequest{Id: id}))
	} else {
		_, err = h.convos.PinConversation(r.Context(), connect.NewRequest(&psmithv1.PinConversationRequest{Id: id}))
	}
	if err != nil {
		h.actionFailed(w, err)
		return
	}
	h.afterAction(w, r, id, false)
}

func (h *Handler) handleArchive(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.convos.ArchiveConversation(r.Context(), connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: id})); err != nil {
		h.actionFailed(w, err)
		return
	}
	h.afterAction(w, r, id, false)
}

func (h *Handler) handleUnarchive(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.convos.UnarchiveConversation(r.Context(), connect.NewRequest(&psmithv1.UnarchiveConversationRequest{Id: id})); err != nil {
		h.actionFailed(w, err)
		return
	}
	if r.Header.Get("HX-Request") == "" && r.FormValue("back") == "" {
		// The archive list's Unarchive is a plain form: open what came back.
		http.Redirect(w, r, "/c/"+id, http.StatusSeeOther)
		return
	}
	h.afterAction(w, r, id, false)
}

// handleConversationDelete permanently deletes a conversation. The list
// asks first, in the row (?confirm=).
func (h *Handler) handleConversationDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.convos.DeleteConversation(r.Context(), connect.NewRequest(&psmithv1.DeleteConversationRequest{Id: id})); err != nil {
		h.actionFailed(w, err)
		return
	}
	h.afterAction(w, r, id, true)
}

// handleListRename saves a new title. An empty one leaves the title alone.
func (h *Handler) handleListRename(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if title := strings.TrimSpace(r.FormValue("title")); title != "" {
		if _, err := h.convos.UpdateConversation(r.Context(), connect.NewRequest(&psmithv1.UpdateConversationRequest{Id: id, Title: &title})); err != nil {
			h.actionFailed(w, err)
			return
		}
	}
	h.afterAction(w, r, id, false)
}

// handleListGenerateTitle asks the profile's title model for a title.
func (h *Handler) handleListGenerateTitle(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.convos.GenerateConversationTitle(r.Context(), connect.NewRequest(&psmithv1.GenerateConversationTitleRequest{Id: id})); err != nil {
		h.actionFailed(w, err)
		return
	}
	h.afterAction(w, r, id, false)
}

// handleRowPartial renders one row in a state: "rename", "confirm", or at
// rest. The row menu swaps it in; Esc and Cancel swap it back.
func (h *Handler) handleRowPartial(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	resp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: id}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	filter, sort, query := listState(r)
	q := r.URL.Query()
	l := listVM{Filter: filter, Sort: sort, Query: query, Archived: q.Get("arch") == "1", ActiveID: q.Get("active")}
	switch q.Get("state") {
	case "rename":
		l.RenameID = id
	case "confirm":
		l.ConfirmID = id
	}
	idx := h.profileIndex(ctx)
	row := newRow(time.Now(), resp.Msg.GetConversation(), idx.names, h.liveConversations(ctx), l.ActiveID, sort)
	if query != "" {
		row.Hits = highlight(row.Title, query)
	}
	h.render(w, r, http.StatusOK, rowItem(l, row))
}

// handleBulk acts on the conversations ticked in select mode: archive,
// delete (after a confirm, in the toolbar), or tick them all.
func (h *Handler) handleBulk(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_ = r.ParseForm()
	ids := r.PostForm["id"]
	back := backURL(r)
	switch r.PostFormValue("action") {
	case "archive":
		for _, id := range ids {
			if _, err := h.convos.ArchiveConversation(ctx, connect.NewRequest(&psmithv1.ArchiveConversationRequest{Id: id})); err != nil {
				h.logger.Warn("web: bulk archive failed", "id", id, "err", err)
			}
		}
		http.Redirect(w, r, back, http.StatusSeeOther)
	case "delete":
		for _, id := range ids {
			if _, err := h.convos.DeleteConversation(ctx, connect.NewRequest(&psmithv1.DeleteConversationRequest{Id: id})); err != nil {
				h.logger.Warn("web: bulk delete failed", "id", id, "err", err)
			}
		}
		http.Redirect(w, r, back, http.StatusSeeOther)
	case "confirm", "all":
		l := h.listAt(ctx, r, selectURL(back))
		l.Selected = map[string]bool{}
		if r.PostFormValue("action") == "all" {
			for _, row := range l.Rows {
				l.Selected[row.ID] = true
			}
		} else {
			for _, id := range ids {
				l.Selected[id] = true
			}
			if len(ids) == 0 {
				http.Redirect(w, r, selectURL(back), http.StatusSeeOther)
				return
			}
			l.ConfirmBulk = true
		}
		h.render(w, r, http.StatusOK, welcomeScreen(l, h.loadWelcome(ctx, l)))
	default:
		http.Redirect(w, r, back, http.StatusSeeOther)
	}
}

// selectURL is /chats in select mode with dest's list state.
func selectURL(dest string) string {
	u, err := url.Parse(dest)
	if err != nil {
		return "/chats?select=1"
	}
	q := u.Query()
	q.Set("select", "1")
	return "/chats?" + q.Encode()
}

// handleArchivedList is the old archive page's address: the list's Archived
// filter replaces it.
func (h *Handler) handleArchivedList(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/chats?f=archived", http.StatusSeeOther)
}
