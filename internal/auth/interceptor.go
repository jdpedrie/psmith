package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/internal/store"
)

// Interceptor authenticates RPCs via Authorization: Bearer <token>.
// Procedures in the unauth allowlist (e.g. AuthService.Login) skip the check.
type Interceptor struct {
	queries   *store.Queries
	allowlist map[string]struct{}
}

// NewInterceptor constructs an interceptor with the given unauthenticated
// procedure paths (use the per-procedure constants from psmithv1connect).
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
	user, err := AuthenticateBearer(ctx, i.queries, header.Get("Authorization"))
	if err != nil {
		// ErrUnauthenticated → CodeUnauthenticated; everything else is internal.
		if errors.Is(err, ErrUnauthenticated) {
			return ctx, connect.NewError(connect.CodeUnauthenticated, err)
		}
		return ctx, connect.NewError(connect.CodeInternal, err)
	}
	return contextWithUser(ctx, user), nil
}

// ErrUnauthenticated wraps every "the request lacks a valid session"
// failure AuthenticateBearer can return — bad header, missing token,
// unknown token, expired session. Callers that bridge to a transport-
// specific status (HTTP 401, Connect Unauthenticated) discriminate on
// this with errors.Is.
var ErrUnauthenticated = errors.New("unauthenticated")

// AuthenticateBearer runs the Bearer-token check independently of any
// transport. The Connect interceptor uses it; the MCP HTTP handler
// uses it; future transports can reuse it without lifting the auth
// state into yet another wrapper.
//
// `authHeader` is the raw Authorization header value (e.g.
// "Bearer abc123"). Returns ErrUnauthenticated wrapped with a more
// specific reason on auth failure, or any underlying DB error
// untouched. On success, callers should attach the user to ctx via
// ContextWithUser before invoking the protected handler.
func AuthenticateBearer(ctx context.Context, queries *store.Queries, authHeader string) (User, error) {
	if !strings.HasPrefix(authHeader, "Bearer ") {
		return User{}, fmt.Errorf("%w: missing bearer token", ErrUnauthenticated)
	}
	raw := strings.TrimPrefix(authHeader, "Bearer ")
	if raw == "" {
		return User{}, fmt.Errorf("%w: empty bearer token", ErrUnauthenticated)
	}
	row, err := queries.GetSessionWithUser(ctx, hashToken(raw))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("%w: invalid or expired session", ErrUnauthenticated)
		}
		return User{}, err
	}
	if err := queries.TouchSession(ctx, row.TokenHash); err != nil {
		// Non-fatal — log and proceed.
		slog.Warn("touch session failed", "err", err)
	}
	return User{
		ID:          row.UserIDFull,
		Username:    row.Username,
		DisplayName: row.DisplayName,
		IsAdmin:     row.IsAdmin,
		CreatedAt:   row.UserCreatedAt,
		UpdatedAt:   row.UserUpdatedAt,
	}, nil
}
