package web

import (
	"net/http"
	"strings"

	"connectrpc.com/connect"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
)

func (h *Handler) handleProfiles(w http.ResponseWriter, r *http.Request) {
	resp, err := h.profiles.ListProfiles(r.Context(), connect.NewRequest(&reevev1.ListProfilesRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var rows []profileRowVM
	for _, p := range resp.Msg.GetProfiles() {
		rows = append(rows, profileRowVM{
			ID:          p.GetId(),
			Name:        p.GetName(),
			Description: p.GetDescription(),
			Template:    p.GetParentOnly(),
		})
	}
	h.render(w, r, http.StatusOK, profilesPage(rows))
}

func (h *Handler) handleProfileNew(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, profileFormPage("New profile", "/settings/profiles", profileFormVM{}, true))
}

func (h *Handler) handleProfileCreate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(r.PostFormValue("name"))
	if name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}
	req := &reevev1.CreateProfileRequest{Name: name}
	if sm := r.PostFormValue("system_message"); strings.TrimSpace(sm) != "" {
		req.SystemMessage = &sm
	}
	req.Description = strings.TrimSpace(r.PostFormValue("description"))
	resp, err := h.profiles.CreateProfile(r.Context(), connect.NewRequest(req))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles/"+resp.Msg.GetProfile().GetId(), http.StatusSeeOther)
}

func (h *Handler) handleProfileEdit(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	resp, err := h.profiles.GetProfile(r.Context(), connect.NewRequest(&reevev1.GetProfileRequest{Id: id}))
	if err != nil {
		http.Error(w, "profile not found", http.StatusNotFound)
		return
	}
	p := resp.Msg.GetProfile()
	h.render(w, r, http.StatusOK, profileFormPage("Edit profile", "/settings/profiles/"+id, profileFormVM{
		ID:            id,
		Name:          p.GetName(),
		SystemMessage: p.GetSystemMessage(),
		Description:   p.GetDescription(),
	}, false))
}

func (h *Handler) handleProfileUpdate(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(r.PostFormValue("name"))
	if name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}
	sm := r.PostFormValue("system_message")
	desc := r.PostFormValue("description")
	if _, err := h.profiles.UpdateProfile(r.Context(), connect.NewRequest(&reevev1.UpdateProfileRequest{
		Id:            id,
		Name:          &name,
		SystemMessage: &sm,
		Description:   &desc,
	})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}

func (h *Handler) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteProfile(r.Context(), connect.NewRequest(&reevev1.DeleteProfileRequest{Id: id})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}
