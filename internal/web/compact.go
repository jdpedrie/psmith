package web

import (
	"encoding/json"
	"html"
	"io"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/providers"
)

// handleCompactPage shows the compaction screen. If the active context already
// holds an un-promoted summary, it offers to promote that; otherwise it offers
// to run a new compaction.
func (h *Handler) handleCompactPage(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&reevev1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	conv := getResp.Msg.GetConversation()
	ctxID := getResp.Msg.GetActiveContext().GetId()

	msgsResp, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&reevev1.ListMessagesRequest{ContextId: ctxID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var pending *summaryVM
	for _, m := range msgsResp.Msg.GetMessages() {
		if m.GetRole() == reevev1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY {
			pending = &summaryVM{MessageID: m.GetId(), HTML: renderMarkdown(m.GetContent())}
		}
	}
	h.render(w, r, http.StatusOK, compactPage(convoVM{ID: conv.GetId(), Title: convoTitle(conv)}, pending))
}

type summaryVM struct {
	MessageID string
	HTML      string
}

// handleCompactRun starts a compaction run and returns the streaming container
// (an htmx SSE element that opens the summary stream), swapped into #compact-out.
func (h *Handler) handleCompactRun(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	resp, err := h.convos.Compact(r.Context(), connect.NewRequest(&reevev1.CompactRequest{ConversationId: convID}))
	if err != nil {
		_, _ = io.WriteString(w, `<p class="error">`+html.EscapeString(err.Error())+`</p>`)
		return
	}
	runID := resp.Msg.GetStreamRun().GetId()
	_, _ = io.WriteString(w, renderComp(r.Context(), compactStream(convID, runID)))
}

// handleCompactStream streams the summary as named SSE events: `message`
// carries the rendered markdown; `promote` swaps in the Promote form bound to
// the freshly-created summary message; `done` closes the connection.
func (h *Handler) handleCompactStream(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	runID, err := uuid.Parse(r.URL.Query().Get("run"))
	if err != nil {
		http.Error(w, "bad run id", http.StatusBadRequest)
		return
	}
	events, err := h.supervisor.Subscribe(r.Context(), runID, 0)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	sse, ok := newSSE(w)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	var buf strings.Builder
	for ev := range events {
		if ev.Chunk != nil && ev.Chunk.Type == providers.ChunkText {
			var p struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(ev.Chunk.Payload, &p)
			buf.WriteString(p.Text)
			sse.event("message", renderMarkdown(buf.String()))
		}
		if ev.Terminal != nil {
			if ev.Terminal.Status != "completed" || ev.Terminal.ResultMessageID == nil {
				sse.event("promote", `<p class="error">Compaction did not complete.</p>`)
				sse.event("done", "")
				return
			}
			sse.event("promote", renderComp(r.Context(), promoteForm(convID, ev.Terminal.ResultMessageID.String(), renderMarkdown(buf.String()))))
			sse.event("done", "")
			return
		}
	}
}

// handleCompactPromote rolls the reviewed summary into a fresh active context.
func (h *Handler) handleCompactPromote(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	mid := r.PostFormValue("message_id")
	if mid == "" {
		http.Error(w, "message_id required", http.StatusBadRequest)
		return
	}
	if _, err := h.convos.PromoteCompactionToNewContext(r.Context(), connect.NewRequest(&reevev1.PromoteCompactionToNewContextRequest{
		MessageId: mid,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}
