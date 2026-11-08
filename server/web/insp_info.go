package web

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// infoVM is the inspector's Conversation view: title, details, and the
// actions that act on the whole conversation.
type infoVM struct {
	ConvID     string
	Title      string
	ProfileID  string
	Profile    string
	Color      int
	Model      string
	ModelSub   string
	Created    string
	Last       string
	Contexts   string // "2 · 64 turns"
	Cost       string
	Pinned     bool
	Archived   bool
	Confirm    bool
	DeleteNote string
}

func (h *Handler) fillInfo(ctx context.Context, vm *convVM, conv *psmithv1.Conversation, confirm bool) {
	now := time.Now()
	in := &infoVM{ConvID: vm.ID, Title: strings.TrimSpace(conv.GetTitle()), ProfileID: conv.GetProfileId(), Profile: vm.Profile, Color: vm.Color,
		Model: vm.Model.Name, Pinned: conv.GetPinnedAt() != nil, Archived: conv.GetArchivedAt() != nil, Confirm: confirm}
	if currentSettingsModel(conv) == "" {
		in.ModelSub = joinDot(vm.Model.Provider, "from the profile")
	} else {
		in.ModelSub = joinDot(vm.Model.Provider, "set here")
	}
	if c := conv.GetCreatedAt(); c != nil {
		in.Created = fmtWhen(now, c.AsTime())
	}
	last := conv.GetLastActivityAt()
	if last == nil {
		last = conv.GetUpdatedAt()
	}
	if last != nil {
		in.Last = fmtWhen(now, last.AsTime())
	}
	turns, cost := 0, 0.0
	for _, c := range vm.Inspector.Contexts {
		turns += c.Turns
		cost += c.CostUSD
	}
	n := len(vm.Inspector.Contexts)
	in.Contexts = fmt.Sprintf("%d · %s", n, plural(turns, "turn"))
	in.Cost = fmt.Sprintf("$%.2f", cost)
	which := "Its context"
	switch {
	case n == 2:
		which = "Both contexts"
	case n > 2:
		which = fmt.Sprintf("All %d contexts", n)
	}
	in.DeleteNote = fmt.Sprintf("%s and all %s are deleted for good. Archive keeps them instead.", which, plural(turns, "turn"))
	if turns == 1 {
		in.DeleteNote = which + " and its one turn are deleted for good. Archive keeps them instead."
	}
	vm.Inspector.Info = in
}

// handleTitleSave renames the conversation.
func (h *Handler) handleTitleSave(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	_ = r.ParseForm()
	title := strings.TrimSpace(r.PostFormValue("title"))
	if _, err := h.convos.UpdateConversation(r.Context(), connect.NewRequest(&psmithv1.UpdateConversationRequest{Id: convID, Title: &title})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=info", http.StatusSeeOther)
}

// handleTitleGenerate asks the server to title the conversation.
func (h *Handler) handleTitleGenerate(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	if _, err := h.convos.GenerateConversationTitle(r.Context(), connect.NewRequest(&psmithv1.GenerateConversationTitleRequest{Id: convID})); err != nil {
		http.Error(w, sentence(connectMessage(err)), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=info", http.StatusSeeOther)
}

// handleInfoDelete deletes the conversation after the in-place confirm and
// lands on the list.
func (h *Handler) handleInfoDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.convos.DeleteConversation(r.Context(), connect.NewRequest(&psmithv1.DeleteConversationRequest{Id: r.PathValue("id")})); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/chats", http.StatusSeeOther)
}
