package web

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
)

// Row states a message can be drawn in. Each is reachable as a page URL
// (?m=<id>&s=<state>) without script and as a row fragment with it.
var rowStates = map[string]bool{"edit": true, "delete": true, "menu": true, "regen": true}

// applyPageState sets what the page URL asks for: a row in a state, the
// context-start strip open, the header renaming, a composer draft.
func (h *Handler) applyPageState(ctx context.Context, r *http.Request, c *convVM) {
	q := r.URL.Query()
	c.Rename = q.Get("rename") != ""
	if d := q.Get("draft"); d != "" {
		c.Draft = d
	}
	mid, state := q.Get("m"), q.Get("s")
	for i := range c.Items {
		it := &c.Items[i]
		if it.Role == "start" && it.Start != nil {
			it.Start.Open = q.Get("start") != ""
			if state == "edit" && mid != "" && (mid == it.Start.PromptID || mid == it.Start.SummaryID) {
				it.Start.Open, it.Start.Editing = true, mid
				it.Start.EditText = h.messageText(ctx, mid)
			}
		}
		if mid != "" && it.ID == mid {
			h.setRowState(ctx, *c, it, state)
		}
	}
}

func (h *Handler) setRowState(ctx context.Context, c convVM, it *msgItem, state string) {
	if !rowStates[state] {
		return
	}
	if (state == "menu" || state == "regen") && it.Role == "user" {
		return
	}
	it.State = state
	if state == "regen" {
		it.Regen = h.modelPicker(ctx, c.ID, it.ModelValue, capsVM{}, c.Harness).Groups
	}
}

func (h *Handler) messageText(ctx context.Context, id string) string {
	resp, err := h.convos.GetMessage(ctx, connect.NewRequest(&psmithv1.GetMessageRequest{Id: id}))
	if err != nil {
		return ""
	}
	return resp.Msg.GetMessage().GetContent()
}

func enhanced(r *http.Request) bool { return r.Header.Get("HX-Request") != "" }

// backToConv answers a form post: htmx follows the redirect and picks the
// transcript out of the page, a plain form lands on the page.
func backToConv(w http.ResponseWriter, r *http.Request, convID, query string) {
	u := "/c/" + convID
	if query != "" {
		u += "?" + query
	}
	http.Redirect(w, r, u, http.StatusSeeOther)
}

// handleMessageRow draws one transcript row in the state ?s= names. It is
// what the row's own controls swap in.
func (h *Handler) handleMessageRow(w http.ResponseWriter, r *http.Request) {
	convID, mid := r.PathValue("id"), r.PathValue("mid")
	c, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	for i := range c.Items {
		if c.Items[i].ID == mid {
			h.setRowState(r.Context(), c, &c.Items[i], r.URL.Query().Get("s"))
			h.render(w, r, http.StatusOK, msgRow(c.Items[i]))
			return
		}
	}
	http.Error(w, "message not found", http.StatusNotFound)
}

// handleRowStatePage is the scriptless way into a row state: the old
// per-message edit and delete URLs land on the page with the row open.
func (h *Handler) handleRowStatePage(state string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		convID, mid := r.PathValue("id"), r.PathValue("mid")
		if enhanced(r) {
			r.URL.RawQuery = "s=" + state
			h.handleMessageRow(w, r)
			return
		}
		http.Redirect(w, r, "/c/"+convID+"?m="+url.QueryEscape(mid)+"&s="+state+"#m-"+mid, http.StatusSeeOther)
	}
}

// handleHead draws the conversation header, or with ?rename=1 the rename form.
func (h *Handler) handleHead(w http.ResponseWriter, r *http.Request) {
	c, err := h.loadConversation(r.Context(), r, r.PathValue("id"))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	c.Rename = r.URL.Query().Get("rename") != ""
	h.render(w, r, http.StatusOK, convHead(c))
}

func (h *Handler) handleRename(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	title := strings.TrimSpace(r.PostFormValue("title"))
	if title != "" {
		if _, err := h.convos.UpdateConversation(r.Context(), connect.NewRequest(&psmithv1.UpdateConversationRequest{Id: convID, Title: &title})); err != nil {
			http.Error(w, friendlyError(err), http.StatusBadRequest)
			return
		}
	}
	if !enhanced(r) {
		backToConv(w, r, convID, "")
		return
	}
	r.URL.RawQuery = ""
	h.handleHead(w, r)
}

// handleGenerateTitle asks the profile's title model for a title, which the
// server stores, and reopens the rename form with it so it can be adjusted.
func (h *Handler) handleGenerateTitle(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	if _, err := h.convos.GenerateConversationTitle(r.Context(), connect.NewRequest(&psmithv1.GenerateConversationTitleRequest{Id: convID})); err != nil {
		http.Error(w, friendlyError(err), http.StatusBadGateway)
		return
	}
	if !enhanced(r) {
		backToConv(w, r, convID, "rename=1")
		return
	}
	r.URL.RawQuery = "rename=1"
	h.handleHead(w, r)
}

// handleStop cancels the conversation's running replies. What streamed so
// far is kept as the reply.
func (h *Handler) handleStop(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	for _, run := range h.activeRunIDs(r, convID) {
		var err error
		if h.streams != nil {
			_, err = h.streams.CancelStream(r.Context(), connect.NewRequest(&psmithv1.CancelStreamRequest{StreamRunId: run}))
		} else if id, perr := uuid.Parse(run); perr == nil {
			err = h.supervisor.Cancel(r.Context(), id)
		}
		if err != nil {
			h.logger.Warn("web: cancel stream failed", "run", run, "err", err)
		}
	}
	if r.Header.Get("Sec-Fetch-Mode") == "navigate" {
		backToConv(w, r, convID, "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// activeRunIDs lists the caller's running stream runs for a conversation.
func (h *Handler) activeRunIDs(r *http.Request, convID string) []string {
	u, ok := auth.FromContext(r.Context())
	if !ok || h.queries == nil {
		return nil
	}
	cid, err := uuid.Parse(convID)
	if err != nil {
		return nil
	}
	runs, err := h.queries.ListActiveStreamRunsByConversation(r.Context(), store.ListActiveStreamRunsByConversationParams{UserID: u.ID, ConversationID: cid})
	if err != nil {
		return nil
	}
	out := make([]string, 0, len(runs))
	for _, run := range runs {
		out = append(out, run.ID.String())
	}
	return out
}

// handleBranch switches to another version of a turn: it moves the active
// context's leaf to the newest descendant of the chosen sibling.
func (h *Handler) handleBranch(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	mid := r.PostFormValue("message_id")
	if mid == "" {
		http.Error(w, "message_id required", http.StatusBadRequest)
		return
	}
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	ctxID := getResp.Msg.GetActiveContext().GetId()
	tree := h.fullTree(r.Context(), ctxID)
	if !inTree(tree, mid) {
		http.Error(w, "message not in this context", http.StatusBadRequest)
		return
	}
	if _, err := h.convos.SetCurrentLeaf(r.Context(), connect.NewRequest(&psmithv1.SetCurrentLeafRequest{ContextId: ctxID, MessageId: newestLeaf(tree, mid)})); err != nil {
		http.Error(w, friendlyError(err), http.StatusBadRequest)
		return
	}
	backToConv(w, r, convID, "")
}

func inTree(tree map[string][]string, id string) bool {
	for _, kids := range tree {
		for _, k := range kids {
			if k == id {
				return true
			}
		}
	}
	return false
}

// handleContinue lets a council run one more hop off the leaf it saw.
func (h *Handler) handleContinue(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	parent := r.PostFormValue("parent_message_id")
	if parent == "" {
		http.Error(w, "parent_message_id required", http.StatusBadRequest)
		return
	}
	resp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: convID, ParentMessageId: &parent, ContinueDiscussion: true,
	}))
	if err != nil {
		http.Error(w, friendlyError(err), http.StatusConflict)
		return
	}
	backToConv(w, r, convID, "run="+resp.Msg.GetStreamRun().GetId())
}

// handleChoice acts on a choice_list button. send: sends the choice as the
// next turn; compose: opens the page with it in the composer (the script
// fills the composer in place instead).
func (h *Handler) handleChoice(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	scheme, payload, _ := strings.Cut(r.PostFormValue("choice"), ":")
	payload = strings.TrimSpace(payload)
	if payload == "" {
		http.Error(w, "choice required", http.StatusBadRequest)
		return
	}
	switch scheme {
	case "send":
		resp, err := h.convos.SendMessage(r.Context(), connect.NewRequest(&psmithv1.SendMessageRequest{ConversationId: convID, Content: payload}))
		if err != nil {
			http.Error(w, friendlyError(err), http.StatusBadRequest)
			return
		}
		backToConv(w, r, convID, "run="+resp.Msg.GetStreamRun().GetId())
	case "compose":
		backToConv(w, r, convID, "draft="+url.QueryEscape(payload))
	default:
		http.Error(w, "unsupported choice action", http.StatusBadRequest)
	}
}

// handleUpload stores files picked or dropped in the composer before the
// send, and answers with their pending chips, each carrying the stored id.
func (h *Handler) handleUpload(w http.ResponseWriter, r *http.Request) {
	if h.files == nil {
		http.Error(w, "uploads are not configured", http.StatusServiceUnavailable)
		return
	}
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, "bad upload", http.StatusBadRequest)
		return
	}
	user := auth.MustFromContext(r.Context())
	var chips []attachVM
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
		if mime == "" || mime == "application/octet-stream" {
			mime = http.DetectContentType(data)
		}
		id, err := h.files.Store(r.Context(), user.ID, mime, fh.Filename, data)
		if err != nil {
			h.logger.Warn("web: file store failed", "err", err)
			http.Error(w, "could not store "+fh.Filename, http.StatusInternalServerError)
			return
		}
		chips = append(chips, attachVM{ID: id, Name: fh.Filename, Size: humanBytes(int64(len(data))), Kind: uploadKind(mime, fh.Filename)})
	}
	if len(chips) == 0 {
		http.Error(w, "no file", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	for _, a := range chips {
		_, _ = io.WriteString(w, renderComp(r.Context(), pendChip(a)))
	}
}

func uploadKind(mime, name string) string {
	if strings.HasPrefix(mime, "image/") {
		return ""
	}
	return kindLabel(mime, name)
}

// handleFilePage shows an attached image on its own page. Other files
// download straight from their signed URL.
func (h *Handler) handleFilePage(w http.ResponseWriter, r *http.Request) {
	convID, fid := r.PathValue("id"), r.PathValue("fid")
	getResp, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	msgs, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: getResp.Msg.GetActiveContext().GetId()}))
	if err != nil {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}
	for _, m := range msgs.Msg.GetMessages() {
		for _, a := range m.GetAttachments() {
			if a.GetFileId() != fid {
				continue
			}
			signed := h.signedImageURL(r.Context(), fid)
			if a.GetKind() != "image" {
				if signed == "" {
					http.Error(w, "file unavailable", http.StatusNotFound)
					return
				}
				http.Redirect(w, r, signed, http.StatusSeeOther)
				return
			}
			v := imagePageVM{ConvID: convID, ConvTitle: convoTitle(getResp.Msg.GetConversation()), MsgID: m.GetId(), Name: a.GetOriginalFilename(), URL: signed}
			if v.Name == "" {
				v.Name = "Image"
			}
			v.Meta = fileSentMeta(a, m)
			h.render(w, r, http.StatusOK, imagePage(v))
			return
		}
	}
	http.Error(w, "file not found", http.StatusNotFound)
}

func fileSentMeta(a *psmithv1.MessageAttachment, m *psmithv1.Message) string {
	parts := []string{kindLabel(a.GetMimeType(), a.GetOriginalFilename())}
	if s := humanBytes(a.GetSizeBytes()); s != "" {
		parts = append(parts, s)
	}
	if ts := m.GetCreatedAt(); ts != nil {
		who := "sent by you"
		if m.GetRole() != psmithv1.MessageRole_MESSAGE_ROLE_USER {
			who = "from the reply"
		}
		parts = append(parts, who+" "+sentWhen(ts.AsTime()))
	}
	return strings.Join(parts, " · ")
}

// sentWhen says when, relative to today: "today at 10:31", "on Nov 3 at 9:05".
func sentWhen(t time.Time) string {
	t = t.Local()
	now := time.Now()
	y1, m1, d1 := now.Date()
	y2, m2, d2 := t.Date()
	clock := t.Format("15:04")
	switch {
	case y1 == y2 && m1 == m2 && d1 == d2:
		return "today at " + clock
	case now.AddDate(0, 0, -1).Format("2006-01-02") == t.Format("2006-01-02"):
		return "yesterday at " + clock
	}
	return fmt.Sprintf("on %s at %s", t.Format("Jan 2"), clock)
}
