package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/clark/internal/store"
)

// Interceptor authenticates RPCs via Authorization: Bearer <token>.
// Procedures in the unauth allowlist (e.g. AuthService.Login) skip the check.
type Interceptor struct {
	queries   *store.Queries
	allowlist map[string]struct{}
}

// NewInterceptor constructs an interceptor with the given unauthenticated
// procedure paths (use the per-procedure constants from clarkv1connect).
func NewInterceptor(queries *store.Queries, unauthenticated ...string) *Interceptor {
	al := make(map[string]struct{}, len(unauthenticated))
	for _, p := range unauthenticated {
		al[p] = struct{}{}
	}
	return &Interceptor{queries: queries, allowlist: al}
}

func (i *Interceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		if _, ok := i.allowlist[req.Spec().Procedure]; ok {
			return next(ctx, req)
		}
		ctx, err := i.authenticate(ctx, req.Header())
		if err != nil {
			return nil, err
		}
		return next(ctx, req)
	}
}

func (i *Interceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		if _, ok := i.allowlist[conn.Spec().Procedure]; ok {
			return next(ctx, conn)
		}
		ctx, err := i.authenticate(ctx, conn.RequestHeader())
		if err != nil {
			return err
		}
		return next(ctx, conn)
	}
}

func (i *Interceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (i *Interceptor) authenticate(ctx context.Context, header http.Header) (context.Context, error) {
	h := header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ctx, connect.NewError(connect.CodeUnauthenticated, errors.New("missing bearer token"))
	}
	raw := strings.TrimPrefix(h, "Bearer ")
	if raw == "" {
		return ctx, connect.NewError(connect.CodeUnauthenticated, errors.New("empty bearer token"))
	}

	row, err := i.queries.GetSessionWithUser(ctx, hashToken(raw))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ctx, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid or expired session"))
		}
		return ctx, connect.NewError(connect.CodeInternal, err)
	}

	if err := i.queries.TouchSession(ctx, row.TokenHash); err != nil {
		// Non-fatal — log and proceed.
		slog.Warn("touch session failed", "err", err)
	}

	user := User{
		ID:          row.UserIDFull,
		Username:    row.Username,
		DisplayName: row.DisplayName,
		IsAdmin:     row.IsAdmin,
		CreatedAt:   row.UserCreatedAt,
		UpdatedAt:   row.UserUpdatedAt,
	}
	return contextWithUser(ctx, user), nil
}
