package web

import (
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// backTo redirects to the Referer when present (the sidebar action
// forms live on whatever page the user was reading) and /chats
// otherwise.
func backTo(w http.ResponseWriter, r *http.Request) {
	dest := r.Header.Get("Referer")
	if dest == "" {
		dest = "/chats"
	}
	http.Redirect(w, r, dest, http.StatusSeeOther)
}

// handlePinToggle pins or unpins based on the conversation's current
// state — one affordance, no client-side state tracking.
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
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	backTo(w, r)
}

func (h *Handler) handleArchive(w http.ResponseWriter, r *http.Request) {
	if _, err := h.convos.ArchiveConversation(r.Context(), connect.NewRequest(&psmithv1.ArchiveConversationRequest{
		Id: r.PathValue("id"),
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// Archiving the open conversation must not bounce back to its
	// now-read-only page from the sidebar of another page; /chats is
	// the sane landing either way.
	http.Redirect(w, r, "/chats", http.StatusSeeOther)
}

func (h *Handler) handleUnarchive(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.convos.UnarchiveConversation(r.Context(), connect.NewRequest(&psmithv1.UnarchiveConversationRequest{
		Id: id,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+id, http.StatusSeeOther)
}

// handleArchivedList renders the archive browser: archived rows with
// Unarchive + Delete, reachable from the sidebar foot.
func (h *Handler) handleArchivedList(w http.ResponseWriter, r *http.Request) {
	resp, err := h.convos.ListConversations(r.Context(), connect.NewRequest(&psmithv1.ListConversationsRequest{
		PageSize: 100,
		Archived: true,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	rows := make([]convoVM, 0, len(resp.Msg.GetConversations()))
	for _, c := range resp.Msg.GetConversations() {
		rows = append(rows, convoVM{ID: c.GetId(), Title: convoTitle(c)})
	}
	convos, token, _ := h.listConvosPage(r.Context(), "", "")
	h.render(w, r, http.StatusOK, archivedPage(convos, token, rows))
}

// handleConversationDelete permanently deletes a conversation — only
// offered from the archive browser, behind a confirm().
func (h *Handler) handleConversationDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.convos.DeleteConversation(r.Context(), connect.NewRequest(&psmithv1.DeleteConversationRequest{
		Id: r.PathValue("id"),
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/archived", http.StatusSeeOther)
}
