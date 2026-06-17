package auth

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/testutil"
)

// --- helpers ---

func newTestSvc(t *testing.T) (*Service, *store.Queries) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	return NewService(q), q
}

func mustHash(t *testing.T, password string) string {
	t.Helper()
	// MinCost — tests don't need real bcrypt strength, and DefaultCost adds ~80ms each.
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("bcrypt: %v", err)
	}
	return string(hash)
}

func mustCreateUser(t *testing.T, q *store.Queries, username, password string, isAdmin bool) store.User {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     username,
		PasswordHash: mustHash(t, password),
		IsAdmin:      isAdmin,
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAs(u store.User) context.Context {
	return contextWithUser(context.Background(), User{
		ID:          u.ID,
		Username:    u.Username,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
		CreatedAt:   u.CreatedAt,
		UpdatedAt:   u.UpdatedAt,
	})
}

func assertCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %v, got nil", want)
	}
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != want {
		t.Errorf("got code %v want %v (%v)", ce.Code(), want, err)
	}
}

// --- Login ---

func TestService_Login_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice", "alicepass", false)

	resp, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "alice", Password: "alicepass",
	}))
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if resp.Msg.SessionToken == "" {
		t.Error("expected non-empty session token")
	}
	if resp.Msg.User.Id != user.ID.String() {
		t.Errorf("user id mismatch: got %s want %s", resp.Msg.User.Id, user.ID)
	}

	// Session row should exist with the hashed token.
	row, err := q.GetSessionWithUser(context.Background(), hashToken(resp.Msg.SessionToken))
	if err != nil {
		t.Fatalf("GetSessionWithUser: %v", err)
	}
	if row.UserIDFull != user.ID {
		t.Errorf("session user_id mismatch: %s vs %s", row.UserIDFull, user.ID)
	}
}

func TestService_Login_WrongPassword(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	mustCreateUser(t, q, "alice", "right", false)

	_, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "alice", Password: "wrong",
	}))
	assertCode(t, err, connect.CodeUnauthenticated)
}

func TestService_Login_UnknownUser(t *testing.T) {
	t.Parallel()
	svc, _ := newTestSvc(t)
	_, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "ghost", Password: "x",
	}))
	assertCode(t, err, connect.CodeUnauthenticated)
}

func TestService_Login_MissingFields(t *testing.T) {
	t.Parallel()
	svc, _ := newTestSvc(t)
	_, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "", Password: "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- Logout ---

func TestService_Logout_DeletesSession(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	mustCreateUser(t, q, "alice", "x", false)

	// Login to get a real token.
	loginResp, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "alice", Password: "x",
	}))
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	token := loginResp.Msg.SessionToken

	req := connect.NewRequest(&spaltv1.LogoutRequest{})
	req.Header().Set("Authorization", "Bearer "+token)
	if _, err := svc.Logout(context.Background(), req); err != nil {
		t.Fatalf("Logout: %v", err)
	}

	if _, err := q.GetSessionWithUser(context.Background(), hashToken(token)); err == nil {
		t.Error("session row should be gone after Logout")
	}
}

func TestService_Logout_MissingHeader(t *testing.T) {
	t.Parallel()
	svc, _ := newTestSvc(t)
	_, err := svc.Logout(context.Background(), connect.NewRequest(&spaltv1.LogoutRequest{}))
	assertCode(t, err, connect.CodeUnauthenticated)
}

// --- WhoAmI ---

func TestService_WhoAmI(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice", "x", false)

	resp, err := svc.WhoAmI(ctxAs(user), connect.NewRequest(&spaltv1.WhoAmIRequest{}))
	if err != nil {
		t.Fatalf("WhoAmI: %v", err)
	}
	if resp.Msg.User.Id != user.ID.String() {
		t.Errorf("got %s want %s", resp.Msg.User.Id, user.ID)
	}
}

// --- ChangePassword ---

func TestService_ChangePassword_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice", "old", false)

	if _, err := svc.ChangePassword(ctxAs(user), connect.NewRequest(&spaltv1.ChangePasswordRequest{
		OldPassword: "old", NewPassword: "new",
	})); err != nil {
		t.Fatalf("ChangePassword: %v", err)
	}

	// Old password should fail, new password should succeed.
	if _, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "alice", Password: "old",
	})); err == nil {
		t.Error("old password should no longer work")
	}
	if _, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "alice", Password: "new",
	})); err != nil {
		t.Errorf("new password should work: %v", err)
	}
}

func TestService_ChangePassword_WrongOld(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice", "right", false)

	_, err := svc.ChangePassword(ctxAs(user), connect.NewRequest(&spaltv1.ChangePasswordRequest{
		OldPassword: "wrong", NewPassword: "new",
	}))
	assertCode(t, err, connect.CodeUnauthenticated)
}

func TestService_ChangePassword_MissingNew(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice", "old", false)

	_, err := svc.ChangePassword(ctxAs(user), connect.NewRequest(&spaltv1.ChangePasswordRequest{
		OldPassword: "old", NewPassword: "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- CreateUser (admin) ---

func TestService_CreateUser_AdminCanCreate(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	dn := "Bob B"

	resp, err := svc.CreateUser(ctxAs(admin), connect.NewRequest(&spaltv1.CreateUserRequest{
		Username:    "bob",
		DisplayName: &dn,
		Password:    "bobpass",
		IsAdmin:     false,
	}))
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if resp.Msg.User.Username != "bob" {
		t.Errorf("got username %q want bob", resp.Msg.User.Username)
	}
	if resp.Msg.User.DisplayName == nil || *resp.Msg.User.DisplayName != "Bob B" {
		t.Errorf("display name not preserved: %+v", resp.Msg.User.DisplayName)
	}
	if resp.Msg.User.IsAdmin {
		t.Error("user should not be admin")
	}

	// Verify Bob can log in.
	if _, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "bob", Password: "bobpass",
	})); err != nil {
		t.Errorf("Bob login failed: %v", err)
	}
}

func TestService_CreateUser_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)

	_, err := svc.CreateUser(ctxAs(regular), connect.NewRequest(&spaltv1.CreateUserRequest{
		Username: "bob", Password: "bobpass",
	}))
	assertCode(t, err, connect.CodePermissionDenied)
}

func TestService_CreateUser_MissingFields(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	_, err := svc.CreateUser(ctxAs(admin), connect.NewRequest(&spaltv1.CreateUserRequest{
		Username: "", Password: "x",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListUsers (admin) ---

func TestService_ListUsers_AdminSeesAll(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	mustCreateUser(t, q, "alice", "x", false)
	mustCreateUser(t, q, "bob", "x", false)

	resp, err := svc.ListUsers(ctxAs(admin), connect.NewRequest(&spaltv1.ListUsersRequest{}))
	if err != nil {
		t.Fatalf("ListUsers: %v", err)
	}
	if len(resp.Msg.Users) != 3 {
		t.Errorf("got %d users want 3", len(resp.Msg.Users))
	}
}

func TestService_ListUsers_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)

	_, err := svc.ListUsers(ctxAs(regular), connect.NewRequest(&spaltv1.ListUsersRequest{}))
	assertCode(t, err, connect.CodePermissionDenied)
}

// --- GetUser (admin) ---

func TestService_GetUser_Found(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	resp, err := svc.GetUser(ctxAs(admin), connect.NewRequest(&spaltv1.GetUserRequest{
		Id: target.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetUser: %v", err)
	}
	if resp.Msg.User.Id != target.ID.String() {
		t.Errorf("got %s want %s", resp.Msg.User.Id, target.ID)
	}
}

func TestService_GetUser_NotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	missing, _ := uuid.NewV7()
	_, err := svc.GetUser(ctxAs(admin), connect.NewRequest(&spaltv1.GetUserRequest{
		Id: missing.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetUser_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	_, err := svc.GetUser(ctxAs(admin), connect.NewRequest(&spaltv1.GetUserRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_GetUser_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)
	target := mustCreateUser(t, q, "bob", "x", false)

	_, err := svc.GetUser(ctxAs(regular), connect.NewRequest(&spaltv1.GetUserRequest{
		Id: target.ID.String(),
	}))
	assertCode(t, err, connect.CodePermissionDenied)
}

// --- UpdateUser (admin) ---

func TestService_UpdateUser_SetDisplayName(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	dn := "Bobby"
	resp, err := svc.UpdateUser(ctxAs(admin), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id:          target.ID.String(),
		DisplayName: &dn,
	}))
	if err != nil {
		t.Fatalf("UpdateUser: %v", err)
	}
	if resp.Msg.User.DisplayName == nil || *resp.Msg.User.DisplayName != "Bobby" {
		t.Errorf("display name not set: %+v", resp.Msg.User.DisplayName)
	}
}

func TestService_UpdateUser_ClearDisplayName(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	// Seed a display name first.
	dn := "Bobby"
	if _, err := svc.UpdateUser(ctxAs(admin), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id: target.ID.String(), DisplayName: &dn,
	})); err != nil {
		t.Fatalf("seed update: %v", err)
	}

	// Clear it.
	resp, err := svc.UpdateUser(ctxAs(admin), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id:          target.ID.String(),
		ClearFields: []string{"display_name"},
	}))
	if err != nil {
		t.Fatalf("UpdateUser clear: %v", err)
	}
	if resp.Msg.User.DisplayName != nil {
		t.Errorf("display name should be nil, got %+v", resp.Msg.User.DisplayName)
	}
}

func TestService_UpdateUser_PromoteToAdmin(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	yes := true
	resp, err := svc.UpdateUser(ctxAs(admin), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id: target.ID.String(), IsAdmin: &yes,
	}))
	if err != nil {
		t.Fatalf("UpdateUser: %v", err)
	}
	if !resp.Msg.User.IsAdmin {
		t.Error("user should be admin")
	}
}

func TestService_UpdateUser_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)
	target := mustCreateUser(t, q, "bob", "x", false)

	dn := "x"
	_, err := svc.UpdateUser(ctxAs(regular), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id: target.ID.String(), DisplayName: &dn,
	}))
	assertCode(t, err, connect.CodePermissionDenied)
}

func TestService_UpdateUser_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	_, err := svc.UpdateUser(ctxAs(admin), connect.NewRequest(&spaltv1.UpdateUserRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- DeleteUser (admin) ---

func TestService_DeleteUser_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	if _, err := svc.DeleteUser(ctxAs(admin), connect.NewRequest(&spaltv1.DeleteUserRequest{
		Id: target.ID.String(),
	})); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}

	users, err := q.ListUsers(context.Background())
	if err != nil {
		t.Fatalf("ListUsers: %v", err)
	}
	for _, u := range users {
		if u.ID == target.ID {
			t.Error("target should be gone")
		}
	}
}

func TestService_DeleteUser_CannotDeleteSelf(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	_, err := svc.DeleteUser(ctxAs(admin), connect.NewRequest(&spaltv1.DeleteUserRequest{
		Id: admin.ID.String(),
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

func TestService_DeleteUser_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)
	target := mustCreateUser(t, q, "bob", "x", false)

	_, err := svc.DeleteUser(ctxAs(regular), connect.NewRequest(&spaltv1.DeleteUserRequest{
		Id: target.ID.String(),
	}))
	assertCode(t, err, connect.CodePermissionDenied)
}

// --- AdminResetPassword ---

func TestService_AdminResetPassword_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "old", false)

	if _, err := svc.AdminResetPassword(ctxAs(admin), connect.NewRequest(&spaltv1.AdminResetPasswordRequest{
		UserId: target.ID.String(), NewPassword: "newpass",
	})); err != nil {
		t.Fatalf("AdminResetPassword: %v", err)
	}

	if _, err := svc.Login(context.Background(), connect.NewRequest(&spaltv1.LoginRequest{
		Username: "bob", Password: "newpass",
	})); err != nil {
		t.Errorf("login with new password failed: %v", err)
	}
}

func TestService_AdminResetPassword_NonAdminDenied(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	regular := mustCreateUser(t, q, "alice", "x", false)
	target := mustCreateUser(t, q, "bob", "x", false)

	_, err := svc.AdminResetPassword(ctxAs(regular), connect.NewRequest(&spaltv1.AdminResetPasswordRequest{
		UserId: target.ID.String(), NewPassword: "x",
	}))
	assertCode(t, err, connect.CodePermissionDenied)
}

func TestService_AdminResetPassword_MissingNew(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)
	target := mustCreateUser(t, q, "bob", "x", false)

	_, err := svc.AdminResetPassword(ctxAs(admin), connect.NewRequest(&spaltv1.AdminResetPasswordRequest{
		UserId: target.ID.String(), NewPassword: "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_AdminResetPassword_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	admin := mustCreateUser(t, q, "admin", "x", true)

	_, err := svc.AdminResetPassword(ctxAs(admin), connect.NewRequest(&spaltv1.AdminResetPasswordRequest{
		UserId: "not-a-uuid", NewPassword: "x",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}
