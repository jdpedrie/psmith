package web

import (
	"net/http"
	"net/url"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// draftVM is a new conversation before its first message: the profiles to
// pick from, the one picked, the model and the text so far.
type draftVM struct {
	Profiles    []profileCardVM
	Current     *profileCardVM
	Model       draftModelVM
	Models      []draftModelVM
	Text        string
	Placeholder string
}

type draftModelVM struct {
	Value, Name, Provider string
}

// handleNewForm renders the draft. ?profile picks a profile (the default
// one otherwise), ?pick or ?model a model (the profile's otherwise), and
// ?message carries text typed before a no-JS profile switch.
func (h *Handler) handleNewForm(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := r.URL.Query()
	order, models := h.enabledModels(ctx)
	d := draftVM{Profiles: h.profileCards(ctx, h.profileIndex(ctx), models), Text: q.Get("message")}
	want := q.Get("profile")
	if want == "" {
		want = q.Get("profile_id")
	}
	for i := range d.Profiles {
		if p := &d.Profiles[i]; p.ID == want || (want == "" && p.Default) {
			d.Current = p
		}
	}
	if d.Current == nil && want == "" && len(d.Profiles) > 0 {
		d.Current = &d.Profiles[0]
	}
	for _, v := range order {
		m := models[v]
		d.Models = append(d.Models, draftModelVM{Value: v, Name: m.Name, Provider: m.Provider})
	}
	// A profile with no model of its own starts on the model the
	// conversation's composer would show and send with, so the draft
	// names it and the first send carries it: without one, SendMessage
	// has nothing to resolve.
	if len(order) > 0 {
		fallback := h.modelPicker(ctx, "", "", capsVM{}, nil).Current.Value
		for i := range d.Profiles {
			if d.Profiles[i].ModelValue == "" {
				d.Profiles[i].ModelValue = fallback
			}
		}
	}
	pick := q.Get("pick")
	if pick == "" {
		pick = q.Get("model")
	}
	if pick == "" && d.Current != nil {
		pick = d.Current.ModelValue
	}
	if m, ok := models[pick]; ok {
		d.Model = draftModelVM{Value: pick, Name: m.Name, Provider: m.Provider}
	}
	d.Placeholder = "Message"
	if d.Current != nil {
		d.Placeholder = "Message " + d.Current.Name
	} else if len(d.Profiles) == 0 {
		d.Placeholder = "Create a profile to start"
	}
	h.render(w, r, http.StatusOK, draftScreen(h.loadList(ctx, r, "", ""), d))
}

// handleNewCreate is the draft's first send: it creates the conversation
// under the chosen profile, sends the message and opens the conversation on
// the streaming reply. A plain form POST so it works without JS. With no
// message it only creates the conversation.
func (h *Handler) handleNewCreate(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	text, modelVal := h.readCompose(r)
	profileID := r.FormValue("profile_id")
	if profileID == "" {
		http.Error(w, "profile_id is required", http.StatusBadRequest)
		return
	}
	resp, err := h.convos.CreateConversation(ctx, connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: profileID,
	}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	id := resp.Msg.GetConversation().GetId()
	h.persistModel(ctx, id, modelVal)

	attachIDs, _ := h.uploadComposeFiles(r)
	if text == "" && len(attachIDs) == 0 {
		http.Redirect(w, r, "/c/"+id, http.StatusSeeOther)
		return
	}
	req := &psmithv1.SendMessageRequest{ConversationId: id, Content: text, AttachmentFileIds: attachIDs}
	if pid, mid, ok := splitModelValue(modelVal); ok {
		req.ProviderId, req.ModelId = &pid, &mid
	}
	sent, err := h.convos.SendMessage(ctx, connect.NewRequest(req))
	if err != nil {
		// The conversation exists; open it with the message back in its
		// composer, so a retry is one click rather than a retype.
		h.logger.Warn("web: first send failed", "err", err)
		http.Redirect(w, r, "/c/"+id+"?failed=1&draft="+url.QueryEscape(text), http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/c/"+id+"?run="+sent.Msg.GetStreamRun().GetId(), http.StatusSeeOther)
}
