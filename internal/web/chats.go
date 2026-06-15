package web

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/starfederation/datastar-go/datastar"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/providers"
)

func (h *Handler) handleChats(w http.ResponseWriter, r *http.Request) {
	convos, err := h.listConvos(r.Context(), "")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.render(w, r, http.StatusOK, chatsPage(convos))
}

func (h *Handler) handleConversation(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: id,
	}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	conv := getResp.Msg.GetConversation()
	ctxID := getResp.Msg.GetActiveContext().GetId()

	msgsResp, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId: ctxID,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var msgs []msgVM
	for _, m := range msgsResp.Msg.GetMessages() {
		role := roleClass(m.GetRole())
		if role == "system" {
			continue // don't surface system framing in the transcript
		}
		content := m.GetContent()
		if dc := m.GetDisplayContent(); dc != "" {
			content = dc
		}
		msgs = append(msgs, msgVM{ID: m.GetId(), Role: role, Content: content})
	}

	convos, _ := h.listConvos(r.Context(), id)
	h.render(w, r, http.StatusOK, conversationPage(convos, convoVM{ID: conv.GetId(), Title: convoTitle(conv)}, msgs))
}

// handleSend sends a user turn and, for enhanced (Datastar) requests, returns
// the SSE patches that append the user bubble plus an assistant placeholder
// whose data-on-load opens the live stream. Without JS it falls back to a
// redirect; the run still completes server-side and the reply shows on reload.
func (h *Handler) handleSend(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	enhanced := r.Header.Get("Datastar-Request") != ""

	text := h.readMessage(r, enhanced)
	if text == "" {
		if enhanced {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	sendResp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: convID,
		Content:        text,
	}))
	if err != nil {
		if enhanced {
			sse := datastar.NewSSE(w, r)
			_ = sse.PatchElements(
				`<div class="msg error"><div class="md">`+html.EscapeString(err.Error())+`</div></div>`,
				datastar.WithSelectorID("messages"), datastar.WithModeAppend())
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	runID := sendResp.Msg.GetStreamRun().GetId()
	userMsg := sendResp.Msg.GetUserMessage()

	if !enhanced {
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	sse := datastar.NewSSE(w, r)
	_ = sse.PatchElementTempl(
		messageBubble(msgVM{ID: userMsg.GetId(), Role: "user", Content: userMsg.GetContent()}),
		datastar.WithSelectorID("messages"), datastar.WithModeAppend())
	_ = sse.PatchElementTempl(
		assistantPlaceholder(convID, runID),
		datastar.WithSelectorID("messages"), datastar.WithModeAppend())
	_ = sse.PatchSignals([]byte(`{"message":""}`))
}

// handleStream subscribes to a run and streams its assistant output as live
// DOM patches. Subscribe replays persisted chunks from `from` then live-tails
// to the terminal event, so passing the last seen sequence resumes cleanly.
func (h *Handler) handleStream(w http.ResponseWriter, r *http.Request) {
	runID, err := uuid.Parse(r.URL.Query().Get("run"))
	if err != nil {
		http.Error(w, "bad run id", http.StatusBadRequest)
		return
	}
	var from int64
	if f := r.URL.Query().Get("from"); f != "" {
		_, _ = fmt.Sscan(f, &from)
	}

	events, err := h.supervisor.Subscribe(r.Context(), runID, from)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	sse := datastar.NewSSE(w, r)
	var buf strings.Builder
	for ev := range events {
		if ev.Chunk != nil {
			switch ev.Chunk.Type {
			case providers.ChunkText:
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				buf.WriteString(p.Text)
				_ = sse.PatchElements(streamMD(buf.String()))
			case providers.ChunkError:
				var p struct {
					Message string `json:"message"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				buf.WriteString("\n\n[error: " + p.Message + "]")
				_ = sse.PatchElements(streamMD(buf.String()))
			}
		}
		if ev.Terminal != nil {
			// Finalize: replace #stream with a plain bubble (dropping the
			// streaming id) so the next turn's placeholder can reuse it.
			final := `<div class="msg assistant"><div class="md">` + html.EscapeString(buf.String()) + `</div></div>`
			_ = sse.PatchElements(final, datastar.WithSelectorID("stream"), datastar.WithModeReplace())
			return
		}
	}
}

func (h *Handler) readMessage(r *http.Request, enhanced bool) string {
	if enhanced {
		var sig struct {
			Message string `json:"message"`
		}
		if err := datastar.ReadSignals(r, &sig); err == nil {
			return strings.TrimSpace(sig.Message)
		}
		return ""
	}
	_ = r.ParseForm()
	return strings.TrimSpace(r.PostFormValue("message"))
}

func streamMD(text string) string {
	return `<div id="stream-md" class="md">` + html.EscapeString(text) + `</div>`
}
