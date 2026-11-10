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
	// TitleError says why the title didn't save or generate; Title then
	// holds what was typed.
	TitleError string
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
	switch {
	case turns == 0 && n == 1:
		in.DeleteNote = "Its context is deleted for good. Archive keeps it instead."
	case turns == 0:
		in.DeleteNote = which + " are deleted for good. Archive keeps them instead."
	case turns == 1:
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
		h.renderTitleError(w, r, convID, title, "Couldn’t save the title. "+sentence(connectMessage(err)))
		return
	}
	http.Redirect(w, r, "/c/"+convID+"?tab=info", http.StatusSeeOther)
}

// handleTitleGenerate asks the server to title the conversation.
func (h *Handler) handleTitleGenerate(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	if _, err := h.convos.GenerateConversationTitle(r.Context(), connect.NewRequest(&psmithv1.GenerateConversationTitleRequest{Id: convID})); err != nil {
		h.renderTitleError(w, r, convID, "", "Couldn’t generate a title. "+sentence(connectMessage(err)))
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

// renderTitleError draws the info view with the title's failure under the
// field. typed is what the reader typed, kept so a retry doesn't retype it;
// "" keeps the stored title. The page answers at the POST's URL, as a
// refused form does, rather than a bare error page.
func (h *Handler) renderTitleError(w http.ResponseWriter, r *http.Request, convID, typed, msg string) {
	vm, err := h.loadConversation(r.Context(), r, convID)
	if err != nil {
		http.Error(w, msg, http.StatusBadRequest)
		return
	}
	got, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID}))
	if err != nil {
		http.Error(w, msg, http.StatusBadRequest)
		return
	}
	vm.Inspector.View, vm.ShowInsp, vm.Inspector.Page = "info", true, true
	h.fillInfo(r.Context(), &vm, got.Msg.GetConversation(), false)
	if typed != "" {
		vm.Inspector.Info.Title = typed
	}
	vm.Inspector.Info.TitleError = msg
	h.renderConversationStatus(w, r, vm, http.StatusUnprocessableEntity)
}
