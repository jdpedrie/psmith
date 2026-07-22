package web

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
)

func (h *Handler) handleChats(w http.ResponseWriter, r *http.Request) {
	convos, token, err := h.listConvosPage(r.Context(), "", "")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.render(w, r, http.StatusOK, chatsPage(convos, token))
}

// convTranscript is everything the conversation page (or its messages
// partial) needs from one load pass.
type convTranscript struct {
	conv             *psmithv1.Conversation
	msgs             []msgVM
	pendingSummaryID string
	pendingTruncated bool
}

// loadTranscript assembles the transcript view-model for a conversation:
// messages of the active context, plus the pending-compression gate
// state. Shared by the full page render and the SSE-triggered partial.
func (h *Handler) loadTranscript(r *http.Request, id string) (convTranscript, error) {
	var out convTranscript
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{
		Id: id,
	}))
	if err != nil {
		return out, err
	}
	out.conv = getResp.Msg.GetConversation()
	ctxID := getResp.Msg.GetActiveContext().GetId()

	msgsResp, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: ctxID,
	}))
	if err != nil {
		return out, err
	}

	for _, m := range msgsResp.Msg.GetMessages() {
		role := roleClass(m.GetRole())
		if role == "system" {
			continue // don't surface system framing in the transcript
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
		out.msgs = append(out.msgs, msgVM{ID: m.GetId(), ConvID: id, ParentID: m.GetParentId(), Role: role, HTML: renderMarkdown(content), Images: images})
	}

	// A clean (non-errored) compression summary gates the conversation:
	// the server refuses sends and compacts until it's promoted or
	// deleted, so the composer gives way to the review bar. Truncated
	// (output-limit-capped) summaries warn instead of inviting Confirm.
	for _, m := range msgsResp.Msg.GetMessages() {
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY && m.GetErrorText() == "" {
			out.pendingSummaryID = m.GetId()
			out.pendingTruncated = isTruncatedFinish(m.GetFinishReason())
		}
	}
	return out, nil
}

// activeRunID returns a running stream_run for the conversation, or ""
// — the messages partial uses it so a refresh triggered by another
// client's send drops the observer straight into the live stream.
func (h *Handler) activeRunID(r *http.Request, convID string) string {
	u, ok := auth.FromContext(r.Context())
	if !ok || h.queries == nil {
		return ""
	}
	cid, err := uuid.Parse(convID)
	if err != nil {
		return ""
	}
	runs, err := h.queries.ListActiveStreamRunsByConversation(r.Context(), store.ListActiveStreamRunsByConversationParams{
		UserID:         u.ID,
		ConversationID: cid,
	})
	if err != nil || len(runs) == 0 {
		return ""
	}
	return runs[0].ID.String()
}

func (h *Handler) handleConversation(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	t, err := h.loadTranscript(r, id)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	convos, sidebarToken, _ := h.listConvosPage(r.Context(), id, "")
	pick := h.modelPicker(r.Context(), id, currentSettingsModel(t.conv), capsVM{})
	runID := r.URL.Query().Get("run")
	if runID == "" {
		// Entering (or reloading) a conversation with an in-flight run
		// — from this client or any other — renders the live stream
		// instead of a transcript that ends at the question.
		runID = h.activeRunID(r, id)
	}
	h.render(w, r, http.StatusOK, conversationPage(convos, sidebarToken, convoVM{ID: t.conv.GetId(), Title: convoTitle(t.conv)}, t.msgs, pick.Current, runID, t.pendingSummaryID, t.pendingTruncated))
}

// handleMessagesPartial re-renders the #messages region. Triggered by
// the SSE bridge when an account event names this conversation.
func (h *Handler) handleMessagesPartial(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	t, err := h.loadTranscript(r, id)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	h.render(w, r, http.StatusOK, messagesRegion(id, t.msgs, h.activeRunID(r, id)))
}

// handleSidebarPartial re-renders the conversations sidebar. Triggered
// by the SSE bridge on any conversation change.
func (h *Handler) handleSidebarPartial(w http.ResponseWriter, r *http.Request) {
	convos, token, err := h.listConvosPage(r.Context(), r.URL.Query().Get("active"), "")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.render(w, r, http.StatusOK, sidebar(convos, token))
}

// handleSidebarRowsPartial serves the Show-more continuation: the next
// page of rows plus, when more remain, another Show-more button.
func (h *Handler) handleSidebarRowsPartial(w http.ResponseWriter, r *http.Request) {
	convos, token, err := h.listConvosPage(r.Context(), r.URL.Query().Get("active"), r.URL.Query().Get("token"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.render(w, r, http.StatusOK, sidebarRows(convos, token))
}

// handleSend sends a user turn. For htmx requests it returns an HTML fragment
// (the user bubble plus an assistant element that opens the live SSE stream),
// appended to #messages. Without JS it redirects to the conversation with the
// run id so the page renders the same streaming element on load; either way the
// run completes server-side and the reply persists.
func (h *Handler) handleSend(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	enhanced := r.Header.Get("HX-Request") != ""

	text, modelVal := h.readCompose(r)
	attachIDs, attachImages := h.uploadComposeFiles(r)

	if text == "" && len(attachIDs) == 0 {
		if enhanced {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	req := &psmithv1.SendMessageRequest{ConversationId: convID, Content: text, AttachmentFileIds: attachIDs}
	if pid, mid, ok := splitModelValue(modelVal); ok {
		req.ProviderId, req.ModelId = &pid, &mid
	}

	sendResp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(req))
	if err != nil {
		if enhanced {
			// Echo the attempted message so it isn't lost, then the error.
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			if text != "" || len(attachImages) > 0 {
				echo := messageBubble(msgVM{ConvID: convID, Role: "user", HTML: renderMarkdown(text), Images: attachImages}, false)
				_, _ = io.WriteString(w, renderComp(r.Context(), echo))
			}
			_, _ = io.WriteString(w, `<div class="msg error"><div class="md">`+html.EscapeString(friendlyError(err))+`</div></div>`)
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
		http.Redirect(w, r, "/c/"+convID+"?run="+runID, http.StatusSeeOther)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	user := messageBubble(msgVM{ID: userMsg.GetId(), ConvID: convID, Role: "user", HTML: renderMarkdown(userMsg.GetContent()), Images: attachImages}, true)
	_, _ = io.WriteString(w, renderComp(r.Context(), user))
	_, _ = io.WriteString(w, renderComp(r.Context(), assistantStream(convID, runID)))
}

// uploadComposeFiles stores any attached files and returns their ids plus
// signed URLs for immediate rendering. Best-effort: an upload failure is logged
// and skipped rather than failing the whole send.
func (h *Handler) uploadComposeFiles(r *http.Request) (ids, imageURLs []string) {
	if h.files == nil || r.MultipartForm == nil {
		return nil, nil
	}
	user := auth.MustFromContext(r.Context())
	for _, fh := range r.MultipartForm.File["file"] {
		f, err := fh.Open()
		if err != nil {
			continue
		}
		data, err := io.ReadAll(f)
		_ = f.Close()
		if err != nil || len(data) == 0 {
			continue
		}
		mime := fh.Header.Get("Content-Type")
		if mime == "" {
			mime = http.DetectContentType(data)
		}
		id, err := h.files.Store(r.Context(), user.ID, mime, fh.Filename, data)
		if err != nil {
			h.logger.Warn("web: file store failed", "err", err)
			continue
		}
		ids = append(ids, id)
		if strings.HasPrefix(mime, "image/") {
			if url := h.signedImageURL(r.Context(), id); url != "" {
				imageURLs = append(imageURLs, url)
			}
		}
	}
	return ids, imageURLs
}

// persistModel records the chosen model as the conversation's default,
// preserving any other settings. Best-effort.
func (h *Handler) persistModel(ctx context.Context, convID, modelVal string) {
	pid, mid, ok := splitModelValue(modelVal)
	if !ok {
		return
	}
	getResp, err := h.convos.GetConversation(ctx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return
	}
	settings := getResp.Msg.GetConversation().GetSettings()
	if settings == nil {
		settings = &psmithv1.ConversationSettings{}
	}
	if settings.GetDefaultProviderId() == pid && settings.GetDefaultModelId() == mid {
		return // unchanged
	}
	settings.DefaultProviderId = &pid
	settings.DefaultModelId = &mid
	if _, err := h.convos.UpdateConversation(ctx, connect.NewRequest(&psmithv1.UpdateConversationRequest{
		Id:       convID,
		Settings: settings,
	})); err != nil {
		h.logger.Warn("web: persist model failed", "err", err)
	}
}

// handleStream subscribes to a run and streams its assistant output as named
// SSE events for htmx's SSE extension: `message` carries the rendered markdown
// (swapped into the .md element), `elicit` carries an inline prompt, and `done`
// closes the connection. Subscribe replays persisted chunks from `from` then
// live-tails to the terminal event, so passing the last seen sequence resumes.
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

	sse, ok := newSSE(w)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
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
				sse.event("message", renderMarkdown(buf.String()))
			case providers.ChunkError:
				var p struct {
					Message string `json:"message"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				buf.WriteString("\n\n[error: " + p.Message + "]")
				sse.event("message", renderMarkdown(buf.String()))
			case providers.ChunkElicit:
				var p struct {
					ElicitationID   string          `json:"elicitation_id"`
					Message         string          `json:"message"`
					RequestedSchema json.RawMessage `json:"requested_schema"`
				}
				if json.Unmarshal(ev.Chunk.Payload, &p) == nil {
					sse.event("elicit", renderComp(r.Context(), elicitForm(convID, p.ElicitationID, p.Message, parseElicitFields(p.RequestedSchema))))
				}
			}
		}
		if ev.Terminal != nil {
			sse.event("done", "")
			return
		}
	}
}

// readCompose reads the message and selected model from the composer. The
// composer posts as multipart (htmx hx-encoding) so files ride along, which
// means both the enhanced and no-JS paths parse the same way.
func (h *Handler) readCompose(r *http.Request) (text, model string) {
	_ = r.ParseMultipartForm(12 << 20) // 12 MiB in memory; larger spills to temp files
	return strings.TrimSpace(r.FormValue("message")), r.FormValue("model")
}

// friendlyError strips the connect error-code prefix ("invalid_argument: …")
// so the transcript shows just the human-readable message.
func friendlyError(err error) string {
	msg := err.Error()
	if i := strings.Index(msg, ": "); i > 0 && i < 24 && !strings.ContainsAny(msg[:i], " ") {
		msg = msg[i+2:]
	}
	if strings.TrimSpace(msg) == "" {
		return "Something went wrong. Please try again."
	}
	return msg
}
