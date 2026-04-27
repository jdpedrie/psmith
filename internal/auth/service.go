package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/gen/clark/v1/clarkv1connect"
	"github.com/jdpedrie/clark/internal/store"
)

// SessionTTL is the lifetime of a freshly-issued session.
const SessionTTL = 30 * 24 * time.Hour

// Service implements clarkv1connect.AuthServiceHandler.
type Service struct {
	clarkv1connect.UnimplementedAuthServiceHandler
	queries *store.Queries
}

func NewService(queries *store.Queries) *Service {
	return &Service{queries: queries}
}

// --- Login / Logout / WhoAmI ---

func (s *Service) Login(ctx context.Context, req *connect.Request[clarkv1.LoginRequest]) (*connect.Response[clarkv1.LoginResponse], error) {
	if req.Msg.Username == "" || req.Msg.Password == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("username and password are required"))
	}

	user, err := s.queries.GetUserByUsername(ctx, req.Msg.Username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid credentials"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Msg.Password)); err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid credentials"))
	}

	raw, hash, err := generateToken()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("generate token: %w", err))
	}

	expiresAt := time.Now().Add(SessionTTL)
	if err := s.queries.CreateSession(ctx, store.CreateSessionParams{
		TokenHash:   hash,
		UserID:      user.ID,
		ClientLabel: req.Msg.ClientLabel,
		ExpiresAt:   expiresAt,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	return connect.NewResponse(&clarkv1.LoginResponse{
		SessionToken: raw,
		ExpiresAt:    timestamppb.New(expiresAt),
		User:         storeUserToProto(user),
	}), nil
}

func (s *Service) Logout(ctx context.Context, req *connect.Request[clarkv1.LogoutRequest]) (*connect.Response[clarkv1.LogoutResponse], error) {
	// We don't have the raw token at this point — read it from the request header.
	auth := req.Header().Get("Authorization")
	if len(auth) < len("Bearer ") {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("no session"))
	}
	raw := auth[len("Bearer "):]
	if err := s.queries.DeleteSession(ctx, hashToken(raw)); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.LogoutResponse{}), nil
}

func (s *Service) WhoAmI(ctx context.Context, req *connect.Request[clarkv1.WhoAmIRequest]) (*connect.Response[clarkv1.WhoAmIResponse], error) {
	u := MustFromContext(ctx)
	return connect.NewResponse(&clarkv1.WhoAmIResponse{User: userToProto(u)}), nil
}

func (s *Service) ChangePassword(ctx context.Context, req *connect.Request[clarkv1.ChangePasswordRequest]) (*connect.Response[clarkv1.ChangePasswordResponse], error) {
	if req.Msg.NewPassword == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("new_password is required"))
	}
	u := MustFromContext(ctx)

	full, err := s.queries.GetUserByID(ctx, u.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := bcrypt.CompareHashAndPassword([]byte(full.PasswordHash), []byte(req.Msg.OldPassword)); err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid current password"))
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Msg.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.queries.UpdateUserPassword(ctx, store.UpdateUserPasswordParams{
		ID:           u.ID,
		PasswordHash: string(hash),
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.ChangePasswordResponse{}), nil
}

// --- Admin user management ---

func (s *Service) CreateUser(ctx context.Context, req *connect.Request[clarkv1.CreateUserRequest]) (*connect.Response[clarkv1.CreateUserResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	if req.Msg.Username == "" || req.Msg.Password == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("username and password are required"))
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Msg.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	id, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	user, err := s.queries.CreateUser(ctx, store.CreateUserParams{
		ID:           id,
		Username:     req.Msg.Username,
		DisplayName:  req.Msg.DisplayName,
		PasswordHash: string(hash),
		IsAdmin:      req.Msg.IsAdmin,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.CreateUserResponse{User: storeUserToProto(user)}), nil
}

func (s *Service) ListUsers(ctx context.Context, req *connect.Request[clarkv1.ListUsersRequest]) (*connect.Response[clarkv1.ListUsersResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	users, err := s.queries.ListUsers(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.User, 0, len(users))
	for _, u := range users {
		out = append(out, storeUserToProto(u))
	}
	return connect.NewResponse(&clarkv1.ListUsersResponse{Users: out}), nil
}

func (s *Service) GetUser(ctx context.Context, req *connect.Request[clarkv1.GetUserRequest]) (*connect.Response[clarkv1.GetUserResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	user, err := s.queries.GetUserByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("user not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.GetUserResponse{User: storeUserToProto(user)}), nil
}

func (s *Service) UpdateUser(ctx context.Context, req *connect.Request[clarkv1.UpdateUserRequest]) (*connect.Response[clarkv1.UpdateUserResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	clear := make(map[string]struct{}, len(req.Msg.ClearFields))
	for _, f := range req.Msg.ClearFields {
		clear[f] = struct{}{}
	}

	if _, ok := clear["display_name"]; ok {
		if err := s.queries.UpdateUserDisplayName(ctx, store.UpdateUserDisplayNameParams{ID: id, DisplayName: nil}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	} else if req.Msg.DisplayName != nil {
		if err := s.queries.UpdateUserDisplayName(ctx, store.UpdateUserDisplayNameParams{ID: id, DisplayName: req.Msg.DisplayName}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	if req.Msg.IsAdmin != nil {
		if err := s.queries.UpdateUserIsAdmin(ctx, store.UpdateUserIsAdminParams{ID: id, IsAdmin: *req.Msg.IsAdmin}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	user, err := s.queries.GetUserByID(ctx, id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.UpdateUserResponse{User: storeUserToProto(user)}), nil
}

func (s *Service) DeleteUser(ctx context.Context, req *connect.Request[clarkv1.DeleteUserRequest]) (*connect.Response[clarkv1.DeleteUserResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	caller := MustFromContext(ctx)
	if id == caller.ID {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("cannot delete your own account"))
	}
	if err := s.queries.DeleteUser(ctx, id); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.DeleteUserResponse{}), nil
}

func (s *Service) AdminResetPassword(ctx context.Context, req *connect.Request[clarkv1.AdminResetPasswordRequest]) (*connect.Response[clarkv1.AdminResetPasswordResponse], error) {
	if err := requireAdmin(ctx); err != nil {
		return nil, err
	}
	if req.Msg.NewPassword == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("new_password is required"))
	}
	id, err := uuid.Parse(req.Msg.UserId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid user_id: %w", err))
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Msg.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.queries.UpdateUserPassword(ctx, store.UpdateUserPasswordParams{
		ID:           id,
		PasswordHash: string(hash),
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.AdminResetPasswordResponse{}), nil
}

// --- helpers ---

func requireAdmin(ctx context.Context) error {
	u := MustFromContext(ctx)
	if !u.IsAdmin {
		return connect.NewError(connect.CodePermissionDenied, errors.New("admin required"))
	}
	return nil
}

func storeUserToProto(u store.User) *clarkv1.User {
	return &clarkv1.User{
		Id:          u.ID.String(),
		Username:    u.Username,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
		CreatedAt:   timestamppb.New(u.CreatedAt),
		UpdatedAt:   timestamppb.New(u.UpdatedAt),
	}
}

func userToProto(u User) *clarkv1.User {
	return &clarkv1.User{
		Id:          u.ID.String(),
		Username:    u.Username,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
		CreatedAt:   timestamppb.New(u.CreatedAt),
		UpdatedAt:   timestamppb.New(u.UpdatedAt),
	}
}
