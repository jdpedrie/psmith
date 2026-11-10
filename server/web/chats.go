package web

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
)

// convTranscript is everything the conversation page (or its messages
// partial) needs from one load pass.
type convTranscript struct {
	conv             *psmithv1.Conversation
	msgs             []msgVM
	pendingSummaryID string
	pendingTruncated bool
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
	if err != nil {
		return ""
	}
	// A compression run streams into the composer's slot, not the
	// transcript; only a reply renders as a live row.
	for _, run := range runs {
		if run.Purpose != string(stream.PurposeCompression) {
			return run.ID.String()
		}
	}
	return ""
}

func (h *Handler) handleConversation(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	c, err := h.loadConversation(r.Context(), r, id)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	c.RunID = r.URL.Query().Get("run")
	if c.RunID == "" {
		// Entering (or reloading) a conversation with an in-flight run
		// — from this client or any other — renders the live stream
		// instead of a transcript that ends at the question.
		c.RunID = h.activeRunID(r, id)
	}
	h.applyPageState(r.Context(), r, &c)
	l := h.loadList(r.Context(), r, id, "")
	h.render(w, r, http.StatusOK, conversationScreen(l, c))
}

// handleMessagesPartial re-renders the transcript. Triggered by the SSE
// bridge when an account event names this conversation.
func (h *Handler) handleMessagesPartial(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	c, err := h.loadConversation(r.Context(), r, id)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	c.RunID = h.activeRunID(r, id)
	h.render(w, r, http.StatusOK, transcript(c))
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
	// Files uploaded ahead of the send ride along as stored ids.
	for _, id := range r.Form["attachment"] {
		if id = strings.TrimSpace(id); id != "" {
			attachIDs = append(attachIDs, id)
		}
	}

	if text == "" && len(attachIDs) == 0 {
		if enhanced {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}

	// Remember the model choice on the conversation so the picker, and
	// regenerate, default to it. Before the send: once its run starts, the
	// conversation refuses settings changes until the run ends.
	h.persistModel(r.Context(), convID, modelVal)

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
				echo := userRow(msgItem{ConvID: convID, Role: "user", Text: text, HTML: renderMarkdown(text), Images: imageAttach(attachImages)})
				_, _ = io.WriteString(w, renderComp(r.Context(), echo))
			}
			_, _ = io.WriteString(w, `<p class="reply-error" role="alert">`+html.EscapeString(friendlyError(err))+`</p>`)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	runID := sendResp.Msg.GetStreamRun().GetId()
	userMsg := sendResp.Msg.GetUserMessage()

	if !enhanced {
		http.Redirect(w, r, "/c/"+convID+"?run="+runID, http.StatusSeeOther)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	images, files := h.attachmentsOf(r.Context(), userMsg.GetAttachments())
	if len(images)+len(files) == 0 {
		images = imageAttach(attachImages)
	}
	user := userRow(msgItem{ID: userMsg.GetId(), ConvID: convID, Role: "user", Text: userMsg.GetContent(), HTML: renderMarkdown(userMsg.GetContent()), Images: images, Files: files})
	_, _ = io.WriteString(w, renderComp(r.Context(), user))
	_, _ = io.WriteString(w, renderComp(r.Context(), liveReply(convID, runID, liveInit{})))
}

func imageAttach(urls []string) []attachVM {
	out := make([]attachVM, 0, len(urls))
	for _, u := range urls {
		out = append(out, attachVM{URL: u})
	}
	return out
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
	// The conversation must be the caller's, and the run must be one of its
	// own: the supervisor serves any run id it's given.
	if _, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID})); err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if h.queries != nil {
		run, err := h.queries.GetStreamRunByID(r.Context(), runID)
		if err != nil || run.ConversationID.String() != convID {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
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
	st := &liveState{runID: runID.String()}
	for ev := range events {
		if ev.Chunk != nil {
			switch ev.Chunk.Type {
			case providers.ChunkText:
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				if st.thinkStart != nil && st.thinkDur == 0 {
					st.thinkDur = time.Since(*st.thinkStart)
					sse.event("chips", renderComp(r.Context(), liveChips(st.chips())))
				}
				st.text.WriteString(p.Text)
				sse.event("message", renderMarkdown(st.text.String())+`<span class="caret"></span>`)
			case providers.ChunkThinking:
				if st.thinkStart == nil {
					now := time.Now()
					st.thinkStart = &now
					sse.event("chips", renderComp(r.Context(), liveChips(st.chips())))
				}
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				// The panel stays hidden until the chip opens it, but it
				// keeps up, so opening it mid-thought shows the thought.
				st.think.WriteString(p.Text)
				sse.event("thinking", renderMarkdown(st.think.String()))
			case providers.ChunkContentReset:
				st.text.Reset()
			case providers.ChunkToolUseStart:
				var p struct {
					ID   string `json:"id"`
					Name string `json:"name"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				st.tools = append(st.tools, liveTool{id: p.ID, name: p.Name, started: time.Now()})
				sse.event("chips", renderComp(r.Context(), liveChips(st.chips())))
			case providers.ChunkToolUseDelta:
				var p struct {
					Partial string `json:"partial_json"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				if n := len(st.tools); n > 0 {
					st.tools[n-1].input = append(st.tools[n-1].input, p.Partial...)
				}
			case providers.ChunkToolUseEnd:
				if n := len(st.tools); n > 0 {
					st.tools[n-1].summary = toolSummary(st.tools[n-1].input)
					sse.event("chips", renderComp(r.Context(), liveChips(st.chips())))
				}
			case providers.ChunkToolResult:
				var p struct {
					ID        string `json:"tool_use_id"`
					ElapsedMS int64  `json:"elapsed_ms"`
					Error     string `json:"error"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				for i := range st.tools {
					if st.tools[i].id == p.ID {
						st.tools[i].done, st.tools[i].elapsed, st.tools[i].err = true, time.Duration(p.ElapsedMS)*time.Millisecond, p.Error
					}
				}
				sse.event("chips", renderComp(r.Context(), liveChips(st.chips())))
			case providers.ChunkError:
				var p struct {
					Message string `json:"message"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				sse.event("message", renderMarkdown(st.text.String())+`<p class="reply-error" role="alert">`+html.EscapeString(p.Message)+`</p>`)
			case providers.ChunkElicit:
				// The tool that asked is the one still running.
				tool := ""
				for i := len(st.tools) - 1; i >= 0; i-- {
					if !st.tools[i].done {
						tool = st.tools[i].name
						break
					}
				}
				if card := elicitEvent(r.Context(), convID, ev.Chunk.Payload, tool); card != "" {
					sse.event("elicit", card)
				}
			}
		}
		if ev.Terminal != nil {
			sse.event("done", "")
			return
		}
	}
}

// liveState is what a streaming reply has shown so far.
type liveState struct {
	runID      string // names the live thinking panel the chip discloses
	text       strings.Builder
	think      strings.Builder
	thinkStart *time.Time
	thinkDur   time.Duration
	tools      []liveTool
}

type liveTool struct {
	id, name, err string
	summary       string
	input         []byte
	started       time.Time
	done          bool
	elapsed       time.Duration
}

func livePanelID(runID string) string { return "think-live-" + runID }

// liveChipVM is one chip above a streaming reply.
type liveChipVM struct {
	Name     string // tool name, mono; empty for thinking
	Label    string
	Live     bool
	Thinking bool
	Secs     string // "3.2s" so far; the page keeps it ticking
	Since    string // unix ms the chip's clock started, for the ticker
	Panel    string // thinking: the id of the panel the chip discloses
}

func (s *liveState) chips() []liveChipVM {
	var out []liveChipVM
	if s.thinkStart != nil {
		panel := livePanelID(s.runID)
		if s.thinkDur > 0 {
			out = append(out, liveChipVM{Label: fmt.Sprintf("Thought for %.1fs", s.thinkDur.Seconds()), Thinking: true, Panel: panel})
		} else {
			out = append(out, liveChipVM{Label: "Thinking", Live: true, Thinking: true, Panel: panel,
				Secs: fmt.Sprintf("%.1fs", time.Since(*s.thinkStart).Seconds()), Since: fmt.Sprint(s.thinkStart.UnixMilli())})
		}
	}
	for i := range s.tools {
		t := &s.tools[i]
		label := ""
		if t.summary != "" {
			label = t.summary + " · "
		}
		switch {
		case t.done && t.err != "":
			out = append(out, liveChipVM{Name: t.name, Label: fmt.Sprintf("failed · %.1fs", t.elapsed.Seconds())})
		case t.done:
			out = append(out, liveChipVM{Name: t.name, Label: label + fmt.Sprintf("%.1fs", t.elapsed.Seconds())})
		default:
			out = append(out, liveChipVM{Name: t.name, Label: label + "running", Live: true,
				Secs: fmt.Sprintf("%.1fs", time.Since(t.started).Seconds()), Since: fmt.Sprint(t.started.UnixMilli())})
		}
	}
	return out
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
