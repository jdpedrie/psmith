package web

import (
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// handleEditForm renders a focused editor for a single message's content.
func (h *Handler) handleEditForm(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	mid := r.PathValue("mid")
	resp, err := h.convos.GetMessage(r.Context(), connect.NewRequest(&psmithv1.GetMessageRequest{Id: mid}))
	if err != nil {
		http.Error(w, "message not found", http.StatusNotFound)
		return
	}
	h.render(w, r, http.StatusOK, editMessagePage(convID, mid, resp.Msg.GetMessage().GetContent()))
}

// handleEditSave applies an in-place content edit.
func (h *Handler) handleEditSave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	mid := r.PathValue("mid")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if _, err := h.convos.EditMessage(r.Context(), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      mid,
		Content: r.PostFormValue("content"),
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// handleRegenerate re-runs the model from an assistant turn's parent, creating
// a new branch, and redirects to the conversation streaming the fresh run.
func (h *Handler) handleRegenerate(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	parentID := r.PostFormValue("parent_message_id")
	if parentID == "" {
		http.Error(w, "parent_message_id required", http.StatusBadRequest)
		return
	}
	resp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  convID,
		ParentMessageId: &parentID,
		Regenerate:      true,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?run="+resp.Msg.GetStreamRun().GetId(), http.StatusSeeOther)
}
