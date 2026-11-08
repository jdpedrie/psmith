package web

import (
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
)

// saRequireAdmin wraps an already user-gated handler: everyone else gets 404,
// the same as a page that isn't there.
func saRequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !saIsAdmin(r) {
			http.NotFound(w, r)
			return
		}
		next(w, r)
	}
}

func (h *Handler) handleUsers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	h.renderUsers(w, r, http.StatusOK, usersState{New: q.Get("new") != "", Reset: q.Get("reset"), Confirm: q.Get("delete")}, nil)
}

type usersState struct {
	New            bool
	Reset, Confirm string
	NewLogin       string
	NewName        string
	NewAdmin       bool
}

func (h *Handler) renderUsers(w http.ResponseWriter, r *http.Request, status int, st usersState, res *testVM) {
	ctx := r.Context()
	resp, err := h.auth.ListUsers(ctx, connect.NewRequest(&psmithv1.ListUsersRequest{}))
	if err != nil {
		http.Error(w, saErrMsg(err), http.StatusInternalServerError)
		return
	}
	me, _ := auth.FromContext(ctx)
	u := usersVM{Server: r.Host, NewOpen: st.New, Result: res}
	u.NewUser.Login, u.NewUser.Name, u.NewUser.Admin = st.NewLogin, st.NewName, st.NewAdmin
	for _, p := range resp.Msg.GetUsers() {
		name := p.GetUsername()
		if p.GetDisplayName() != "" {
			name = p.GetDisplayName()
		}
		row := userRowVM{ID: p.GetId(), Name: name, Login: p.GetUsername(), Initial: saInitial(name), Admin: p.GetIsAdmin(), Self: p.GetId() == me.ID.String()}
		if p.GetCreatedAt() != nil {
			row.Added = p.GetCreatedAt().AsTime().Local().Format("Jan 2, 2006")
		}
		if !row.Self {
			switch row.ID {
			case st.Reset:
				row.Mode = "reset"
			case st.Confirm:
				row.Mode = "confirm"
			}
		}
		u.Rows = append(u.Rows, row)
	}
	// You first, then by when they joined.
	sort.SliceStable(u.Rows, func(i, j int) bool { return u.Rows[i].Self && !u.Rows[j].Self })
	h.render(w, r, status, usersScreen(h.loadSnav(ctx, r, "users"), u))
}

func (h *Handler) handleUserCreate(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	login := strings.TrimSpace(r.PostFormValue("username"))
	name := strings.TrimSpace(r.PostFormValue("display_name"))
	admin := r.PostFormValue("admin") != ""
	req := &psmithv1.CreateUserRequest{Username: login, Password: r.PostFormValue("password"), IsAdmin: admin}
	if name != "" {
		req.DisplayName = &name
	}
	if _, err := h.auth.CreateUser(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderUsers(w, r, http.StatusUnprocessableEntity, usersState{New: true, NewLogin: login, NewName: name, NewAdmin: admin},
			&testVM{Message: "Couldn’t create " + orDefault(login, "the user") + ": " + saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/users", http.StatusSeeOther)
}

func (h *Handler) handleUserRole(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	admin := r.PostFormValue("role") == "admin"
	if _, err := h.auth.UpdateUser(r.Context(), connect.NewRequest(&psmithv1.UpdateUserRequest{Id: r.PathValue("uid"), IsAdmin: &admin})); err != nil {
		h.renderUsers(w, r, http.StatusUnprocessableEntity, usersState{}, &testVM{Message: saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/users", http.StatusSeeOther)
}

func (h *Handler) handleUserPassword(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	uid := r.PathValue("uid")
	if _, err := h.auth.AdminResetPassword(r.Context(), connect.NewRequest(&psmithv1.AdminResetPasswordRequest{UserId: uid, NewPassword: r.PostFormValue("password")})); err != nil {
		h.renderUsers(w, r, http.StatusUnprocessableEntity, usersState{Reset: uid}, &testVM{Message: saErrMsg(err)})
		return
	}
	h.renderUsers(w, r, http.StatusOK, usersState{}, &testVM{OK: true, Message: "Password set. Tell them the new one yourself; nothing is emailed."})
}

func (h *Handler) handleUserDelete(w http.ResponseWriter, r *http.Request) {
	uid := r.PathValue("uid")
	if _, err := h.auth.DeleteUser(r.Context(), connect.NewRequest(&psmithv1.DeleteUserRequest{Id: uid})); err != nil {
		h.renderUsers(w, r, http.StatusUnprocessableEntity, usersState{}, &testVM{Message: saErrMsg(err)})
		return
	}
	http.Redirect(w, r, "/settings/users", http.StatusSeeOther)
}
