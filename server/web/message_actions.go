package web

import (
	"net/http"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// handleEditSave applies an in-place edit: the text, optionally the role,
// and for a user turn optionally a resend, which runs a fresh reply to the
// edited message as a new branch.
func (h *Handler) handleEditSave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	mid := r.PathValue("mid")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	req := &psmithv1.EditMessageRequest{Id: mid, Content: r.PostFormValue("content")}
	switch r.PostFormValue("role") {
	case "user":
		role := psmithv1.MessageRole_MESSAGE_ROLE_USER
		req.Role = &role
	case "assistant":
		role := psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT
		req.Role = &role
	}
	resp, err := h.convos.EditMessage(r.Context(), connect.NewRequest(req))
	if err != nil {
		http.Error(w, friendlyError(err), http.StatusBadRequest)
		return
	}
	if r.PostFormValue("resend") != "" && resp.Msg.GetMessage().GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_USER {
		send, err := h.convos.SendMessage(r.Context(), connect.NewRequest(&psmithv1.SendMessageRequest{
			ConversationId: convID, ParentMessageId: &mid, Regenerate: true,
		}))
		if err != nil {
			http.Error(w, friendlyError(err), http.StatusBadRequest)
			return
		}
		backToConv(w, r, convID, "run="+send.Msg.GetStreamRun().GetId())
		return
	}
	backToConv(w, r, convID, "")
}

// handleRegenerate re-runs the model from an assistant turn's parent,
// creating a new branch, optionally with another model, and lands on the
// conversation streaming the fresh run. Retry on a failed reply is the same.
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
	req := &psmithv1.SendMessageRequest{ConversationId: convID, ParentMessageId: &parentID, Regenerate: true}
	if pid, mid, ok := splitModelValue(r.PostFormValue("model")); ok {
		req.ProviderId, req.ModelId = &pid, &mid
	}
	resp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(req))
	if err != nil {
		http.Error(w, friendlyError(err), http.StatusBadRequest)
		return
	}
	backToConv(w, r, convID, "run="+resp.Msg.GetStreamRun().GetId())
}

// handleMessageDelete removes a message (non-cascading: children stitch to
// the deleted row's parent, mirroring the native clients' default). The
// confirm is the row itself, drawn in its delete state; the compression
// review bar's Discard posts here too.
func (h *Handler) handleMessageDelete(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	mid := r.PathValue("mid")
	if _, err := h.convos.DeleteMessage(r.Context(), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id: mid,
	})); err != nil {
		http.Error(w, friendlyError(err), http.StatusBadRequest)
		return
	}
	backToConv(w, r, convID, "")
}
