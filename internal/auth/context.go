package auth

import (
	"context"
	"time"

	"github.com/google/uuid"
)

// User is the authenticated principal carried through the request context.
// Excludes password material — never leak it past the auth boundary.
type User struct {
	ID          uuid.UUID
	Username    string
	DisplayName *string
	IsAdmin     bool
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type ctxKey struct{}

func contextWithUser(ctx context.Context, u User) context.Context {
	return context.WithValue(ctx, ctxKey{}, u)
}

// ContextWithUser attaches a user to a context. Exported for tests in other
// packages — production code should rely on the auth interceptor to attach
// the user, not call this directly.
func ContextWithUser(ctx context.Context, u User) context.Context {
	return contextWithUser(ctx, u)
}

// FromContext returns the authenticated user attached by the interceptor.
func FromContext(ctx context.Context) (User, bool) {
	u, ok := ctx.Value(ctxKey{}).(User)
	return u, ok
}

// MustFromContext returns the authenticated user or panics. Use only in code
// paths protected by the auth interceptor — a missing user there is a wiring bug.
func MustFromContext(ctx context.Context) User {
	u, ok := FromContext(ctx)
	if !ok {
		panic("auth: no user in context (auth interceptor not registered?)")
	}
	return u
}
