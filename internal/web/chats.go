package web

import (
	"context"
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
		msgs = append(msgs, msgVM{ID: m.GetId(), Role: role, HTML: renderMarkdown(content)})
	}

	convos, _ := h.listConvos(r.Context(), id)
	models := h.listModels(r.Context(), "")
	current := currentModelValue(conv, models)
	for i := range models {
		models[i].Selected = models[i].Value == current
	}
	h.render(w, r, http.StatusOK, conversationPage(convos, convoVM{ID: conv.GetId(), Title: convoTitle(conv)}, msgs, models, current))
}

// handleSend sends a user turn and, for enhanced (Datastar) requests, returns
// the SSE patches that append the user bubble plus an assistant placeholder
// whose data-on-load opens the live stream. Without JS it falls back to a
// redirect; the run still completes server-side and the reply shows on reload.
func (h *Handler) handleSend(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	enhanced := r.Header.Get("Datastar-Request") != ""

	text, modelVal := h.readCompose(r, enhanced)
	if text == "" {
		if enhanced {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	req := &reevev1.SendMessageRequest{ConversationId: convID, Content: text}
	if pid, mid, ok := splitModelValue(modelVal); ok {
		req.ProviderId, req.ModelId = &pid, &mid
	}

	sendResp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(req))
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

	// Remember the model choice on the conversation so the picker defaults to
	// it next time. Best-effort; never blocks the turn.
	h.persistModel(r.Context(), convID, modelVal)

	runID := sendResp.Msg.GetStreamRun().GetId()
	userMsg := sendResp.Msg.GetUserMessage()

	if !enhanced {
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	sse := datastar.NewSSE(w, r)
	_ = sse.PatchElementTempl(
		messageBubble(msgVM{ID: userMsg.GetId(), Role: "user", HTML: renderMarkdown(userMsg.GetContent())}),
		datastar.WithSelectorID("messages"), datastar.WithModeAppend())
	_ = sse.PatchElementTempl(
		assistantPlaceholder(convID, runID),
		datastar.WithSelectorID("messages"), datastar.WithModeAppend())
	_ = sse.PatchSignals([]byte(`{"message":""}`))
}

// persistModel records the chosen model as the conversation's default,
// preserving any other settings. Best-effort.
func (h *Handler) persistModel(ctx context.Context, convID, modelVal string) {
	pid, mid, ok := splitModelValue(modelVal)
	if !ok {
		return
	}
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&reevev1.GetConversationRequest{Id: convID}))
	if err != nil {
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &reevev1.ConversationSettings{}
	}
	if settings.GetDefaultProviderId() == pid && settings.GetDefaultModelId() == mid {
		return // unchanged
	}
	settings.DefaultProviderId = &pid
	settings.DefaultModelId = &mid
	if _, err := h.convos.UpdateConversation(ctx, connect.NewRequest(&reevev1.UpdateConversationRequest{
		Id:       convID,
		Settings: settings,
	})); err != nil {
		h.logger.Warn("web: persist model failed", "err", err)
	}
}

// handleStream subscribes to a run and streams its assistant output as live
// DOM patches. Subscribe replays persisted chunks from `from` then live-tails
// to the terminal event, so passing the last seen sequence resumes cleanly.
func (h *Handler) handleStream(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
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
			case providers.ChunkElicit:
				var p struct {
					ElicitationID   string          `json:"elicitation_id"`
					Message         string          `json:"message"`
					RequestedSchema json.RawMessage `json:"requested_schema"`
				}
				if json.Unmarshal(ev.Chunk.Payload, &p) == nil {
					_ = sse.PatchElementTempl(
						elicitForm(convID, p.ElicitationID, p.Message, parseElicitFields(p.RequestedSchema)),
						datastar.WithSelectorID("elicit"), datastar.WithModeInner())
				}
			}
		}
		if ev.Terminal != nil {
			// Finalize: replace #stream with a plain bubble (dropping the
			// streaming id) so the next turn's placeholder can reuse it.
			final := `<div class="msg assistant"><div class="md">` + renderMarkdown(buf.String()) + `</div></div>`
			_ = sse.PatchElements(final, datastar.WithSelectorID("stream"), datastar.WithModeReplace())
			return
		}
	}
}

// readCompose pulls the message text and selected model from the request,
// from Datastar signals on enhanced requests and from form fields otherwise.
func (h *Handler) readCompose(r *http.Request, enhanced bool) (text, model string) {
	if enhanced {
		var sig struct {
			Message string `json:"message"`
			Model   string `json:"model"`
		}
		if err := datastar.ReadSignals(r, &sig); err == nil {
			return strings.TrimSpace(sig.Message), sig.Model
		}
		return "", ""
	}
	_ = r.ParseForm()
	return strings.TrimSpace(r.PostFormValue("message")), r.PostFormValue("model")
}

func streamMD(text string) string {
	return `<div id="stream-md" class="md">` + renderMarkdown(text) + `</div>`
}
