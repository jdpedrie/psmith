package web

import (
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// handleNewForm renders the new-conversation page: pick a profile to start a chat.
func (h *Handler) handleNewForm(w http.ResponseWriter, r *http.Request) {
	convos, sidebarToken, _ := h.listConvosPage(r.Context(), "", "")
	h.render(w, r, http.StatusOK, newConversationPage(convos, sidebarToken, h.listProfiles(r.Context())))
}

// handleNewCreate creates a conversation under the chosen profile and redirects
// to it. A plain form POST so it works without JS.
func (h *Handler) handleNewCreate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	profileID := r.PostFormValue("profile_id")
	if profileID == "" {
		http.Error(w, "profile_id is required", http.StatusBadRequest)
		return
	}
	resp, err := h.convos.CreateConversation(r.Context(), connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: profileID,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+resp.Msg.GetConversation().GetId(), http.StatusSeeOther)
}
