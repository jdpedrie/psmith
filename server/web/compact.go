package web

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/providers"
)

// Compression happens in the composer's place: the compress card (prompt and
// model), the streaming card, the review card (with edit), and the failed
// card. Each is a state of the conversation page, so every step is a URL or
// a form post and works without script.

// isTruncatedFinish reports whether a message finish_reason means the
// output was cut at the model's token limit (Anthropic max_tokens,
// OpenAI length, Google MAX_TOKENS). Mirrors PsmithMessage
// .isTruncatedOutput on the Swift side.
func isTruncatedFinish(reason string) bool {
	switch strings.ToLower(reason) {
	case "max_tokens", "length":
		return true
	default:
		return false
	}
}

// handleCompactPage shows the conversation with the compress card in the
// composer's place. With a summary pending or a run in flight, the page
// already shows that card instead.
func (h *Handler) handleCompactPage(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if vm.Inspector.Card == nil || vm.Inspector.Card.Kind == "failed" {
		conv, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		base := slotVM{ConvID: convID, CtxLabel: activeLabel(vm.Inspector.Contexts, conv.Msg.GetActiveContext().GetId()), Tokens: vm.Gauge.Tokens, Turns: vm.Inspector.Turns}
		base.NextLabel = nextLabel(vm.Inspector.Contexts)
		card := h.compressCard(r.Context(), base, conv.Msg.GetConversation(), r.URL.Query().Get("model"), "")
		vm.Inspector.Card, vm.Inspector.Compress = &card, "open"
	}
	h.renderConversation(w, r, vm)
}

func nextLabel(rows []ctxRowVM) string {
	return "Context " + strconv.Itoa(len(rows)+1)
}

// renderConversation draws the conversation screen around an already-loaded
// view model.
func (h *Handler) renderConversation(w http.ResponseWriter, r *http.Request, vm convVM) {
	h.renderConversationStatus(w, r, vm, http.StatusOK)
}

// renderConversationStatus is renderConversation with a status, for a form
// the server refused that answers with the page it came from.
func (h *Handler) renderConversationStatus(w http.ResponseWriter, r *http.Request, vm convVM, status int) {
	if vm.RunID == "" {
		vm.RunID = h.activeRunID(r, vm.ID)
		if vm.RunID != "" && vm.Inspector.Card != nil && vm.Inspector.Card.RunID == vm.RunID {
			vm.RunID = ""
		}
	}
	l := h.loadList(r.Context(), r, vm.ID, "")
	h.render(w, r, status, conversationScreen(l, vm))
}

// handleCompactRun starts a compression with the posted instructions and
// model. A model whose window can't hold the context fails here, before
// anything runs, with the card saying so.
func (h *Handler) handleCompactRun(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	guide := strings.TrimSpace(r.PostFormValue("guide"))
	model := r.PostFormValue("model")

	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	conv, active := getResp.Msg.GetConversation(), getResp.Msg.GetActiveContext()
	req := &psmithv1.CompactRequest{ConversationId: convID}
	if guide != "" {
		req.CompressionGuide = &guide
	}
	pid, mid, ok := splitModelValue(model)
	if ok {
		req.CompressionProviderId, req.CompressionModelId = &pid, &mid
		if e := h.findModel(r.Context(), pid, mid); e != nil {
			tokens := active.GetLastMessageTotalTokens()
			for _, x := range h.contextRows(r.Context(), convID, active.GetId()) {
				if x.Active {
					tokens = x.Tokens
				}
			}
			if win := int64(e.GetModel().GetContextWindow()); win > 0 && tokens > win {
				name := orName(e.GetModel().GetDisplayName(), mid)
				h.renderCompressFailed(w, r, convID, model, guide,
					name+" can't fit this context. "+"{ctx} is "+commas(tokens)+" tokens and its window holds "+commas(win)+".",
					"{ctx} is unchanged. Choose a model with a larger window, then retry.")
				return
			}
		}
	}
	// Retrying after a failure clears the errored summary first, so the
	// transcript keeps one record of the attempt that counts.
	if failed := r.PostFormValue("failed_id"); failed != "" {
		_, _ = h.convos.DeleteMessage(r.Context(), connect.NewRequest(&psmithv1.DeleteMessageRequest{Id: failed}))
	}
	if req.CompressionGuide == nil {
		g := defaultCompressionGuide
		if pg := h.resolvedProfile(r.Context(), conv.GetProfileId()).GetCompressionGuide(); pg != "" {
			g = pg
		}
		req.CompressionGuide = &g
	}
	if req.CompressionProviderId == nil {
		if p := h.resolvedProfile(r.Context(), conv.GetProfileId()); p.GetCompressionProviderId() == "" {
			if pid, mid, ok := splitModelValue(currentSettingsModel(conv)); ok {
				req.CompressionProviderId, req.CompressionModelId = &pid, &mid
			}
		}
	}
	resp, err := h.convos.Compact(r.Context(), connect.NewRequest(req))
	if err != nil {
		h.renderCompressFailed(w, r, convID, model, guide, sentence(connectMessage(err)), "{ctx} is unchanged. Choose another model, then retry.")
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?compact="+resp.Msg.GetStreamRun().GetId(), http.StatusSeeOther)
}

// connectMessage is an RPC error's message without the code prefix.
func connectMessage(err error) string {
	var ce *connect.Error
	if errors.As(err, &ce) {
		return ce.Message()
	}
	return err.Error()
}

// renderCompressFailed draws the failed card for a compression that never
// started. {ctx} in the copy names the active context.
func (h *Handler) renderCompressFailed(w http.ResponseWriter, r *http.Request, convID, model, guide, msg, hint string) {
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	conv, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	base := slotVM{ConvID: convID, CtxLabel: activeLabel(vm.Inspector.Contexts, conv.Msg.GetActiveContext().GetId()), Tokens: vm.Gauge.Tokens, Turns: vm.Inspector.Turns}
	base.NextLabel = nextLabel(vm.Inspector.Contexts)
	card := h.compressCard(r.Context(), base, conv.Msg.GetConversation(), model, guide)
	card.Kind = "failed"
	card.Error = strings.ReplaceAll(msg, "{ctx}", card.CtxLabel)
	card.ErrorHint = strings.ReplaceAll(hint, "{ctx}", card.CtxLabel)
	if pid, mid, ok := splitModelValue(card.Selected); ok {
		card.ModelMeta = h.modelMeta(r.Context(), pid, mid)
	}
	vm.Inspector.Card, vm.Inspector.Compress = &card, "open"
	h.renderConversation(w, r, vm)
}

// handleCompactStream streams the summary into the compacting card as
// `summary` events. `done` carries the page to load next: the conversation,
// which then shows the review card or the failed card.
func (h *Handler) handleCompactStream(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	runID, err := uuid.Parse(r.URL.Query().Get("run"))
	if err != nil {
		http.Error(w, "bad run id", http.StatusBadRequest)
		return
	}
	if _, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID})); err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	// The conversation check covers ownership; this pins the run to it, so
	// a run id can't stream another conversation's (or account's) output.
	if _, ok := h.compactionRun(r.Context(), convID, runID.String()); !ok {
		http.Error(w, "not found", http.StatusNotFound)
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
		if ev.Chunk != nil {
			switch ev.Chunk.Type {
			case providers.ChunkText:
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(ev.Chunk.Payload, &p)
				buf.WriteString(p.Text)
				sse.event("summary", renderMarkdown(buf.String())+`<span class="caret"></span>`)
			case providers.ChunkContentReset:
				buf.Reset()
			}
		}
		if ev.Terminal != nil {
			sse.event("done", "/c/"+convID)
			return
		}
	}
}

// handleCompactStop cancels a running compression.
func (h *Handler) handleCompactStop(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	runID, err := uuid.Parse(r.PostFormValue("run"))
	if err != nil {
		http.Error(w, "bad run id", http.StatusBadRequest)
		return
	}
	if h.runningCompaction(r.Context(), convID) != runID.String() {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err := h.supervisor.Cancel(r.Context(), runID); err != nil {
		h.logger.Warn("web: cancel compaction failed", "err", err)
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
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
	if !h.summaryInConversation(r, convID, mid) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if _, err := h.convos.PromoteCompactionToNewContext(r.Context(), connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{
		MessageId: mid,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// handleSummarySave writes the edited summary back before it is promoted.
func (h *Handler) handleSummarySave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	mid := r.PostFormValue("message_id")
	if !h.summaryInConversation(r, convID, mid) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	content := r.PostFormValue("content")
	if strings.TrimSpace(content) == "" {
		http.Error(w, "the summary can't be empty", http.StatusBadRequest)
		return
	}
	if _, err := h.convos.EditMessage(r.Context(), connect.NewRequest(&psmithv1.EditMessageRequest{Id: mid, Content: content})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// handleSummaryDiscard deletes a pending (or failed) summary, which gives the
// composer back.
func (h *Handler) handleSummaryDiscard(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	mid := r.PostFormValue("message_id")
	if !h.summaryInConversation(r, convID, mid) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if _, err := h.convos.DeleteMessage(r.Context(), connect.NewRequest(&psmithv1.DeleteMessageRequest{Id: mid})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// summaryInConversation reports whether mid is a compression summary in the
// conversation's active context, so a posted id can't reach another
// conversation's messages.
func (h *Handler) summaryInConversation(r *http.Request, convID, mid string) bool {
	if mid == "" {
		return false
	}
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		return false
	}
	msgs, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: getResp.Msg.GetActiveContext().GetId(), StructureOnly: true}))
	if err != nil {
		return false
	}
	for _, m := range msgs.Msg.GetMessages() {
		if m.GetId() == mid && m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY {
			return true
		}
	}
	return false
}

// sentence capitalizes the first letter and ends with a period, for server
// errors shown as card copy.
func sentence(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return s
	}
	s = strings.ToUpper(s[:1]) + s[1:]
	if !strings.HasSuffix(s, ".") {
		s += "."
	}
	return s
}
