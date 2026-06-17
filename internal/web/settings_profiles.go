package web

import (
	"net/http"
	"strings"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
)

func (h *Handler) handleProfiles(w http.ResponseWriter, r *http.Request) {
	resp, err := h.profiles.ListProfiles(r.Context(), connect.NewRequest(&spaltv1.ListProfilesRequest{}))
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
	req := &spaltv1.CreateProfileRequest{Name: name}
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
	resp, err := h.profiles.GetProfile(r.Context(), connect.NewRequest(&spaltv1.GetProfileRequest{Id: id}))
	if err != nil {
		http.Error(w, "profile not found", http.StatusNotFound)
		return
	}
	p := resp.Msg.GetProfile()
	var defaultModel string
	if d := p.GetDefaultSettings(); d != nil && d.GetDefaultProviderId() != "" && d.GetDefaultModelId() != "" {
		defaultModel = modelValue(d.GetDefaultProviderId(), d.GetDefaultModelId())
	}
	var compModel string
	if p.GetCompressionProviderId() != "" && p.GetCompressionModelId() != "" {
		compModel = modelValue(p.GetCompressionProviderId(), p.GetCompressionModelId())
	}
	var titleModel string
	if p.GetTitleProviderId() != "" && p.GetTitleModelId() != "" {
		titleModel = modelValue(p.GetTitleProviderId(), p.GetTitleModelId())
	}
	mode := ""
	switch p.GetCompressionMode() {
	case spaltv1.CompressionMode_COMPRESSION_MODE_REPLACE:
		mode = "REPLACE"
	case spaltv1.CompressionMode_COMPRESSION_MODE_APPEND:
		mode = "APPEND"
	}
	h.render(w, r, http.StatusOK, profileFormPage("Edit profile", "/settings/profiles/"+id, profileFormVM{
		ID:               id,
		Name:             p.GetName(),
		SystemMessage:    p.GetSystemMessage(),
		Description:      p.GetDescription(),
		DefaultModel:     defaultModel,
		CompressionModel: compModel,
		CompressionGuide: p.GetCompressionGuide(),
		CompressionMode:  mode,
		TitleModel:       titleModel,
		TitleGuide:       p.GetTitleGuide(),
		Models:           h.listModels(r.Context(), ""),
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
	req := &spaltv1.UpdateProfileRequest{
		Id:            id,
		Name:          &name,
		SystemMessage: &sm,
		Description:   &desc,
	}
	var clear []string

	// Default model lives inside default_settings; preserve the rest of that
	// message (include-thinking, call settings) by reading the current value.
	cur, err := h.profiles.GetProfile(r.Context(), connect.NewRequest(&spaltv1.GetProfileRequest{Id: id}))
	if err != nil {
		http.Error(w, "profile not found", http.StatusNotFound)
		return
	}
	defaults := cur.Msg.GetProfile().GetDefaultSettings()
	if defaults == nil {
		defaults = &spaltv1.ProfileDefaults{}
	}
	if pid, mid, ok := splitModelValue(r.PostFormValue("default_model")); ok {
		defaults.DefaultProviderId, defaults.DefaultModelId = &pid, &mid
	} else {
		defaults.DefaultProviderId, defaults.DefaultModelId = nil, nil
	}
	req.DefaultSettings = defaults

	// Compression model + guide + mode.
	if pid, mid, ok := splitModelValue(r.PostFormValue("compression_model")); ok {
		req.CompressionProviderId, req.CompressionModelId = &pid, &mid
	} else {
		clear = append(clear, "compression_provider_id", "compression_model_id")
	}
	if g := strings.TrimSpace(r.PostFormValue("compression_guide")); g != "" {
		req.CompressionGuide = &g
	} else {
		clear = append(clear, "compression_guide")
	}
	switch r.PostFormValue("compression_mode") {
	case "REPLACE":
		m := spaltv1.CompressionMode_COMPRESSION_MODE_REPLACE
		req.CompressionMode = &m
	case "APPEND":
		m := spaltv1.CompressionMode_COMPRESSION_MODE_APPEND
		req.CompressionMode = &m
	default:
		clear = append(clear, "compression_mode")
	}

	// Title model + guide.
	if pid, mid, ok := splitModelValue(r.PostFormValue("title_model")); ok {
		req.TitleProviderId, req.TitleModelId = &pid, &mid
	} else {
		clear = append(clear, "title_provider_id", "title_model_id")
	}
	if g := strings.TrimSpace(r.PostFormValue("title_guide")); g != "" {
		req.TitleGuide = &g
	} else {
		clear = append(clear, "title_guide")
	}

	req.ClearFields = clear
	if _, err := h.profiles.UpdateProfile(r.Context(), connect.NewRequest(req)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}

func (h *Handler) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteProfile(r.Context(), connect.NewRequest(&spaltv1.DeleteProfileRequest{Id: id})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}
