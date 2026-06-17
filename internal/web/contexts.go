package web

import (
	"net/http"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
)

type contextRowVM struct {
	ID           string
	Title        string
	MessageCount int32
	Cost         string
	Active       bool
}

func (h *Handler) handleContexts(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	activeID := getResp.Msg.GetActiveContext().GetId()

	listResp, err := h.convos.ListContexts(r.Context(), connect.NewRequest(&spaltv1.ListContextsRequest{ConversationId: convID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var rows []contextRowVM
	for _, c := range listResp.Msg.GetContexts() {
		title := c.GetTitle()
		if title == "" {
			title = "Untitled context"
		}
		rows = append(rows, contextRowVM{
			ID:           c.GetId(),
			Title:        title,
			MessageCount: c.GetMessageCount(),
			Cost:         usd(c.GetCumulativeCostUsd()),
			Active:       c.GetId() == activeID,
		})
	}
	conv := getResp.Msg.GetConversation()
	h.render(w, r, http.StatusOK, contextsPage(convoVM{ID: conv.GetId(), Title: convoTitle(conv)}, rows))
}

// handleContextView renders a single context's messages read-only (used to
// inspect retired contexts after compaction).
func (h *Handler) handleContextView(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	ctxID := r.PathValue("cid")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&spaltv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	msgsResp, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&spaltv1.ListMessagesRequest{ContextId: ctxID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var msgs []msgVM
	for _, m := range msgsResp.Msg.GetMessages() {
		role := roleClass(m.GetRole())
		if role == "system" {
			continue
		}
		content := m.GetContent()
		if dc := m.GetDisplayContent(); dc != "" {
			content = dc
		}
		var images []string
		for _, a := range m.GetAttachments() {
			if a.GetKind() == "image" {
				if url := h.signedImageURL(r.Context(), a.GetFileId()); url != "" {
					images = append(images, url)
				}
			}
		}
		msgs = append(msgs, msgVM{ID: m.GetId(), Role: role, HTML: renderMarkdown(content), Images: images})
	}
	conv := getResp.Msg.GetConversation()
	h.render(w, r, http.StatusOK, contextViewPage(convoVM{ID: conv.GetId(), Title: convoTitle(conv)}, msgs))
}
