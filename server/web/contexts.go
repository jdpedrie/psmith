package web

import (
	"fmt"
	"net/http"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// ctxViewVM is the read-only page for a context that isn't active.
type ctxViewVM struct {
	ID          string
	Label       string // "Context 1"
	ActiveLabel string // "Context 2"
	Range       string // "Context 1 · Oct 22 to Oct 30 · 46 turns"
	Items       []ctxItemVM
	Tokens      int64
	Window      int64
	Percent     float64
	Warn        int64
	WarnPct     float64
	Cost        string
	Turns       int
	Cache       string
	Changes     int
}

// ctxItemVM is one row of the read-only transcript.
type ctxItemVM struct {
	Role    string // user, assistant, summary
	HTML    string
	Images  []attachVM
	Model   string // summary: the model that wrote it
	Started string // summary: "started Context 2"
}

// handleContexts is the old contexts page's URL; the list lives in the
// inspector now.
func (h *Handler) handleContexts(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/c/"+r.PathValue("id")+"?tab=contexts", http.StatusSeeOther)
}

// handleContextView renders a context read-only, with Make active. The
// active context redirects to the conversation itself.
func (h *Handler) handleContextView(w http.ResponseWriter, r *http.Request) {
	convID, ctxID := r.PathValue("id"), r.PathValue("cid")
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	var row *ctxRowVM
	var activeLbl string
	for i := range vm.Inspector.Contexts {
		x := &vm.Inspector.Contexts[i]
		if x.Active {
			activeLbl = x.Label
		}
		if x.ID == ctxID {
			row = x
		}
	}
	if row == nil {
		http.Error(w, "context not found", http.StatusNotFound)
		return
	}
	if row.Active {
		http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
		return
	}
	row.Viewing = true

	msgsResp, err := h.convos.ListMessages(r.Context(), connect.NewRequest(&psmithv1.ListMessagesRequest{ContextId: ctxID}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	msgs := msgsResp.Msg.GetMessages()
	cv := ctxViewVM{ID: ctxID, Label: row.Label, ActiveLabel: activeLbl}
	cv.Items = h.ctxItems(r, msgs, vm.Inspector.Contexts, ctxID)
	cv.Range = ctxRange(row.Label, msgs, row.Turns)
	cv.Turns, cv.Cache, cv.Changes = turnStats(msgs)
	if listResp, err := h.convos.ListContexts(r.Context(), connect.NewRequest(&psmithv1.ListContextsRequest{ConversationId: convID})); err == nil {
		for _, c := range listResp.Msg.GetContexts() {
			if c.GetId() == ctxID {
				cv.Tokens = c.GetLastMessageTotalTokens()
				cv.Cost = fmt.Sprintf("$%.4f", c.GetCumulativeCostUsd())
			}
		}
	}
	cv.Window, cv.Warn = vm.Gauge.Window, vm.Gauge.Warn
	if cv.Window > 0 {
		cv.Percent = min(100, float64(cv.Tokens)*100/float64(cv.Window))
		cv.WarnPct = float64(cv.Warn) * 100 / float64(cv.Window)
	}
	vm.Inspector.Card = &slotVM{Kind: "readonly", ConvID: convID, ContextID: ctxID, CtxLabel: row.Label, ActiveLabel: activeLbl}
	l := h.loadList(r.Context(), r, convID, "")
	h.render(w, r, http.StatusOK, contextViewScreen(l, vm, cv))
}

// ctxItems is the read-only transcript: no actions, summaries as cards.
func (h *Handler) ctxItems(r *http.Request, msgs []*psmithv1.Message, rows []ctxRowVM, ctxID string) []ctxItemVM {
	var out []ctxItemVM
	for _, m := range msgs {
		role := roleClass(m.GetRole())
		if role == "system" || m.GetIsWelcome() && m.GetContent() == "" {
			continue
		}
		content := m.GetContent()
		if dc := m.GetDisplayContent(); dc != "" {
			content = dc
		}
		it := ctxItemVM{Role: role, HTML: renderMarkdown(content)}
		if m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY {
			it.Role = "summary"
			it.Model = h.modelName(r.Context(), m.GetProviderId(), m.GetModelId())
			for i, x := range rows {
				if x.ID == ctxID && i+1 < len(rows) {
					it.Started = "started " + rows[i+1].Label
				}
			}
		}
		for _, a := range m.GetAttachments() {
			if a.GetKind() == "image" {
				it.Images = append(it.Images, attachVM{ID: a.GetFileId(), Name: a.GetOriginalFilename(), URL: h.signedImageURL(r.Context(), a.GetFileId())})
			}
		}
		out = append(out, it)
	}
	return out
}

// ctxRange is the strip above a read-only context: its span and size.
func ctxRange(label string, msgs []*psmithv1.Message, turns int) string {
	parts := []string{label}
	var first, last string
	for _, m := range msgs {
		if m.GetCreatedAt() == nil || m.GetRole() == psmithv1.MessageRole_MESSAGE_ROLE_SYSTEM {
			continue
		}
		d := m.GetCreatedAt().AsTime().Format("Jan 2")
		if first == "" {
			first = d
		}
		last = d
	}
	switch {
	case first != "" && first != last:
		parts = append(parts, first+" to "+last)
	case first != "":
		parts = append(parts, first)
	}
	parts = append(parts, plural(turns, "turn"))
	return strings.Join(parts, " · ")
}

// handleContextActivate makes a context the active one.
func (h *Handler) handleContextActivate(w http.ResponseWriter, r *http.Request) {
	convID, ctxID := r.PathValue("id"), r.PathValue("cid")
	if !h.ownsContext(r, convID, ctxID) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if _, err := h.convos.ActivateContext(r.Context(), connect.NewRequest(&psmithv1.ActivateContextRequest{ContextId: ctxID})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}

// handleContextRename sets (or with an empty title, clears) a context's title.
func (h *Handler) handleContextRename(w http.ResponseWriter, r *http.Request) {
	convID, ctxID := r.PathValue("id"), r.PathValue("cid")
	if !h.ownsContext(r, convID, ctxID) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	_ = r.ParseForm()
	title := strings.TrimSpace(r.PostFormValue("title"))
	if _, err := h.convos.UpdateContext(r.Context(), connect.NewRequest(&psmithv1.UpdateContextRequest{ContextId: ctxID, Title: &title})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=contexts", http.StatusSeeOther)
}

// handleContextDelete deletes a context for good. The confirm happened in
// place, on the row.
func (h *Handler) handleContextDelete(w http.ResponseWriter, r *http.Request) {
	convID, ctxID := r.PathValue("id"), r.PathValue("cid")
	if !h.ownsContext(r, convID, ctxID) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if _, err := h.convos.DeleteContext(r.Context(), connect.NewRequest(&psmithv1.DeleteContextRequest{ContextId: ctxID})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=contexts", http.StatusSeeOther)
}

// ownsContext reports whether ctxID belongs to a conversation the caller can
// read. The context RPCs check the owner too; this also pins the context to
// the conversation in the URL.
func (h *Handler) ownsContext(r *http.Request, convID, ctxID string) bool {
	resp, err := h.convos.ListContexts(r.Context(), connect.NewRequest(&psmithv1.ListContextsRequest{ConversationId: convID}))
	if err != nil {
		return false
	}
	for _, c := range resp.Msg.GetContexts() {
		if c.GetId() == ctxID {
			return true
		}
	}
	return false
}

// contextRowVM and summaryVM feed the legacy pages in views.templ, which the
// inspector replaces; they stay until those templates go.
type contextRowVM struct {
	ID           string
	Title        string
	MessageCount int32
	Cost         string
	Active       bool
}

type summaryVM struct {
	MessageID string
	HTML      string
	Truncated bool
}
