package web

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// --- view models ---

// profileHeadVM is the head every profile tab shares: crumbs, the colored
// name, the parent line and the tab strip.
type profileHeadVM struct {
	ID         string
	Name       string
	Color      int
	ParentID   string
	ParentName string
	Tab        string // general | models | plugins | share
}

type profileListRowVM struct {
	ID        string
	Name      string
	Sub       string
	Model     string
	Color     int
	Depth     int
	IsDefault bool
}

type profileListVM struct {
	Rows     []profileListRowVM
	MenuOpen string // a row whose menu renders open (board fixtures)
	Confirm  string // a row asking to confirm its delete
	Error    string
}

type profileGeneralVM struct {
	Head        profileHeadVM
	New         bool
	Name        string
	Description string
	ParentOpts  []sbOpt
	IsDefault   bool
	DefaultName string // the profile that is the default now, when another one is
	Favorite    bool
	ParentOnly  bool
	System      string
	FirstMsg    string
	Welcome     string
	Dirty       int
	Error       string
}

// --- loading ---

// profileIndex is the caller's profiles, loaded once per request so parent
// names, children and inherited values resolve without more calls.
type profileIndex struct {
	list []*psmithv1.Profile
	byID map[string]*psmithv1.Profile
}

func (h *Handler) loadProfileIndex(ctx context.Context) (profileIndex, error) {
	resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	if err != nil {
		return profileIndex{}, err
	}
	ix := profileIndex{list: resp.Msg.GetProfiles(), byID: map[string]*psmithv1.Profile{}}
	for _, p := range ix.list {
		ix.byID[p.GetId()] = p
	}
	return ix, nil
}

// chain is p then its ancestors, stopping at a cycle or a missing parent.
func (ix profileIndex) chain(p *psmithv1.Profile) []*psmithv1.Profile {
	var out []*psmithv1.Profile
	seen := map[string]bool{}
	for p != nil && !seen[p.GetId()] {
		seen[p.GetId()] = true
		out = append(out, p)
		p = ix.byID[p.GetParentProfileId()]
	}
	return out
}

func (ix profileIndex) children(id string) []*psmithv1.Profile {
	var out []*psmithv1.Profile
	for _, p := range ix.list {
		if p.GetParentProfileId() == id {
			out = append(out, p)
		}
	}
	return out
}

// descendants reports every profile below id, which can't become its parent.
func (ix profileIndex) descendants(id string) map[string]bool {
	out := map[string]bool{}
	var walk func(string)
	walk = func(pid string) {
		for _, c := range ix.children(pid) {
			if !out[c.GetId()] {
				out[c.GetId()] = true
				walk(c.GetId())
			}
		}
	}
	walk(id)
	return out
}

// resolvedDefaultModel walks the chain for the first default model set.
func (ix profileIndex) resolvedDefaultModel(p *psmithv1.Profile) string {
	for _, c := range ix.chain(p) {
		d := c.GetDefaultSettings()
		if d.GetDefaultProviderId() != "" && d.GetDefaultModelId() != "" {
			return modelValue(d.GetDefaultProviderId(), d.GetDefaultModelId())
		}
	}
	return ""
}

func (ix profileIndex) head(p *psmithv1.Profile, tab string) profileHeadVM {
	vm := profileHeadVM{ID: p.GetId(), Name: p.GetName(), Color: profileColor(p.GetId()), Tab: tab}
	if parent := ix.byID[p.GetParentProfileId()]; parent != nil {
		vm.ParentID, vm.ParentName = parent.GetId(), parent.GetName()
	}
	return vm
}

// loadProfilePage fetches the index and the profile named in the path, or
// answers 404.
func (h *Handler) loadProfilePage(w http.ResponseWriter, r *http.Request) (profileIndex, *psmithv1.Profile, bool) {
	ix, err := h.loadProfileIndex(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return ix, nil, false
	}
	p := ix.byID[r.PathValue("id")]
	if p == nil {
		http.Error(w, "profile not found", http.StatusNotFound)
		return ix, nil, false
	}
	return ix, p, true
}

// --- list ---

func (h *Handler) handleProfiles(w http.ResponseWriter, r *http.Request) {
	h.renderProfiles(w, r, "")
}

func (h *Handler) renderProfiles(w http.ResponseWriter, r *http.Request, errMsg string) {
	ix, err := h.loadProfileIndex(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	vm := profileListVM{Rows: profileRows(ix, h.modelGroups(r.Context())), Confirm: r.URL.Query().Get("confirm"), Error: errMsg}
	if id := r.URL.Query().Get("fragment"); strings.HasPrefix(id, "prow-") {
		for _, row := range vm.Rows {
			if "prow-"+row.ID == id {
				h.render(w, r, http.StatusOK, profileListRow(vm, row))
				return
			}
		}
		http.NotFound(w, r)
		return
	}
	h.render(w, r, http.StatusOK, profilesScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
}

// profileRows orders profiles as a tree: each root, then its children
// indented under it, in list order.
func profileRows(ix profileIndex, groups []modelGroup) []profileListRowVM {
	var out []profileListRowVM
	placed := map[string]bool{}
	var add func(p *psmithv1.Profile, depth int)
	add = func(p *psmithv1.Profile, depth int) {
		if placed[p.GetId()] {
			return
		}
		placed[p.GetId()] = true
		out = append(out, profileListRowVM{
			ID: p.GetId(), Name: p.GetName(), Sub: profileRowSub(ix, p), Color: profileColor(p.GetId()),
			Model: modelName(groups, ix.resolvedDefaultModel(p)), Depth: depth, IsDefault: p.GetIsDefault(),
		})
		for _, c := range ix.children(p.GetId()) {
			add(c, depth+1)
		}
	}
	for _, p := range ix.list {
		if ix.byID[p.GetParentProfileId()] == nil {
			add(p, 0)
		}
	}
	// Anything left sits in a parent cycle; list it flat rather than lose it.
	for _, p := range ix.list {
		add(p, 0)
	}
	return out
}

// profileRowSub is the description plus where the profile sits in the tree.
func profileRowSub(ix profileIndex, p *psmithv1.Profile) string {
	parts := []string{}
	if d := strings.TrimSpace(p.GetDescription()); d != "" {
		if !strings.HasSuffix(d, ".") {
			d += "."
		}
		parts = append(parts, d)
	}
	if kids := ix.children(p.GetId()); len(kids) > 0 {
		names := make([]string, 0, len(kids))
		for _, k := range kids {
			names = append(names, k.GetName())
		}
		parts = append(parts, "Parent of "+joinAnd(names)+".")
	}
	if parent := ix.byID[p.GetParentProfileId()]; parent != nil {
		parts = append(parts, "Inherits from "+parent.GetName()+".")
	}
	if p.GetParentOnly() {
		parts = append(parts, "Parent only.")
	}
	return strings.Join(parts, " ")
}

func joinAnd(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	default:
		return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
	}
}

func (h *Handler) handleProfileMakeDefault(w http.ResponseWriter, r *http.Request) {
	if _, err := h.profiles.SetDefaultProfile(r.Context(), connect.NewRequest(&psmithv1.SetDefaultProfileRequest{ProfileId: r.PathValue("id")})); err != nil {
		h.renderProfiles(w, r, err.Error())
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}

// --- General tab and new profile ---

func (h *Handler) handleProfileNew(w http.ResponseWriter, r *http.Request) {
	ix, err := h.loadProfileIndex(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	vm := profileGeneralVM{New: true, Head: profileHeadVM{Name: "New profile", Tab: "general"}, ParentOpts: parentOpts(ix, "", r.URL.Query().Get("parent"))}
	for _, p := range ix.list {
		if p.GetIsDefault() {
			vm.DefaultName = p.GetName()
		}
	}
	h.render(w, r, http.StatusOK, profileGeneralScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
}

func (h *Handler) handleProfileEdit(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	h.render(w, r, http.StatusOK, profileGeneralScreen(h.loadSnav(r.Context(), r, "profiles"), buildProfileGeneral(ix, p)))
}

func buildProfileGeneral(ix profileIndex, p *psmithv1.Profile) profileGeneralVM {
	vm := profileGeneralVM{
		Head:        ix.head(p, "general"),
		Name:        p.GetName(),
		Description: p.GetDescription(),
		ParentOpts:  parentOpts(ix, p.GetId(), p.GetParentProfileId()),
		IsDefault:   p.GetIsDefault(),
		Favorite:    p.GetFavorite(),
		ParentOnly:  p.GetParentOnly(),
		System:      p.GetSystemMessage(),
		FirstMsg:    p.GetDefaultUserMessage(),
		Welcome:     p.GetWelcomeMessage(),
	}
	for _, o := range ix.list {
		if o.GetIsDefault() && o.GetId() != p.GetId() {
			vm.DefaultName = o.GetName()
		}
	}
	return vm
}

// parentOpts lists the profiles self may inherit from: everything except
// itself and its descendants, which would make a cycle.
func parentOpts(ix profileIndex, self, current string) []sbOpt {
	opts := []sbOpt{{Value: "", Label: "No parent", Selected: current == ""}}
	below := map[string]bool{}
	if self != "" {
		below = ix.descendants(self)
	}
	for _, p := range ix.list {
		if p.GetId() == self || below[p.GetId()] {
			continue
		}
		opts = append(opts, sbOpt{Value: p.GetId(), Label: p.GetName(), Selected: p.GetId() == current})
	}
	return opts
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
	if r.PostFormValue("default") == "true" && r.PostFormValue("parent_only") == "true" {
		http.Error(w, "A parent-only profile can't be the default.", http.StatusBadRequest)
		return
	}
	req := &psmithv1.CreateProfileRequest{
		Name:        name,
		Description: strings.TrimSpace(r.PostFormValue("description")),
		Favorite:    r.PostFormValue("favorite") == "true",
		ParentOnly:  r.PostFormValue("parent_only") == "true",
	}
	if v := r.PostFormValue("parent"); v != "" {
		req.ParentProfileId = &v
	}
	if v := r.PostFormValue("system_message"); strings.TrimSpace(v) != "" {
		req.SystemMessage = &v
	}
	if v := strings.TrimSpace(r.PostFormValue("first_message")); v != "" {
		req.DefaultUserMessage = &v
	}
	if v := strings.TrimSpace(r.PostFormValue("welcome_message")); v != "" {
		req.WelcomeMessage = &v
	}
	resp, err := h.profiles.CreateProfile(r.Context(), connect.NewRequest(req))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	id := resp.Msg.GetProfile().GetId()
	if r.PostFormValue("default") == "true" {
		if _, err := h.profiles.SetDefaultProfile(r.Context(), connect.NewRequest(&psmithv1.SetDefaultProfileRequest{ProfileId: id})); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	http.Redirect(w, r, "/settings/profiles/"+id, http.StatusSeeOther)
}

func (h *Handler) handleProfileUpdate(w http.ResponseWriter, r *http.Request) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	id := p.GetId()
	name := strings.TrimSpace(r.PostFormValue("name"))
	desc := strings.TrimSpace(r.PostFormValue("description"))
	fav := r.PostFormValue("favorite") == "true"
	only := r.PostFormValue("parent_only") == "true"
	req := &psmithv1.UpdateProfileRequest{Id: id, Name: &name, Description: &desc, Favorite: &fav, ParentOnly: &only}
	var clear []string
	textField := func(form, field string, set **string) {
		if v := r.PostFormValue(form); strings.TrimSpace(v) != "" {
			*set = &v
		} else {
			clear = append(clear, field)
		}
	}
	textField("system_message", "system_message", &req.SystemMessage)
	textField("first_message", "default_user_message", &req.DefaultUserMessage)
	textField("welcome_message", "welcome_message", &req.WelcomeMessage)
	if v := r.PostFormValue("parent"); v != "" {
		req.ParentProfileId = &v
	} else {
		clear = append(clear, "parent_profile_id")
	}
	req.ClearFields = clear

	vm := buildProfileGeneral(ix, p)
	fail := func(msg string) {
		vm.Error, vm.Name, vm.Description = msg, name, desc
		vm.System, vm.FirstMsg, vm.Welcome = r.PostFormValue("system_message"), r.PostFormValue("first_message"), r.PostFormValue("welcome_message")
		h.render(w, r, http.StatusBadRequest, profileGeneralScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
	}
	if name == "" {
		fail("A profile needs a name.")
		return
	}
	if _, err := h.profiles.UpdateProfile(r.Context(), connect.NewRequest(req)); err != nil {
		fail(errMessage(err))
		return
	}
	switch want := r.PostFormValue("default") == "true"; {
	case want && !p.GetIsDefault():
		_, err := h.profiles.SetDefaultProfile(r.Context(), connect.NewRequest(&psmithv1.SetDefaultProfileRequest{ProfileId: id}))
		if err != nil {
			fail(errMessage(err))
			return
		}
	case !want && p.GetIsDefault():
		_, err := h.profiles.SetDefaultProfile(r.Context(), connect.NewRequest(&psmithv1.SetDefaultProfileRequest{}))
		if err != nil {
			fail(errMessage(err))
			return
		}
	}
	http.Redirect(w, r, "/settings/profiles/"+id, http.StatusSeeOther)
}

// errMessage is a connect error's message without its code prefix.
func errMessage(err error) string {
	var ce *connect.Error
	if errors.As(err, &ce) {
		return ce.Message()
	}
	return err.Error()
}

func (h *Handler) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteProfile(r.Context(), connect.NewRequest(&psmithv1.DeleteProfileRequest{Id: id})); err != nil {
		if r.PostFormValue("from") == "list" {
			h.renderProfiles(w, r, errMessage(err))
			return
		}
		h.renderShare(w, r, shareState{Error: errMessage(err)})
		return
	}
	http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
}
