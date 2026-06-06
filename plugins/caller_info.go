package plugins

import (
	"context"

	"github.com/google/uuid"
)

// CallerInfo carries the per-tool-call identity the dispatch site
// knows about so plugins can scope their work without each one re-
// deriving the chain from the SendMessage request. Same context-
// injection pattern as ProviderResolver: conversations service
// attaches an instance right before ExecuteTool; plugins read via
// CallerInfoFrom(ctx).
//
// ActiveContextID is the active context for the conversation — a
// conversation is a sequence of contexts (compression retires an
// old one and opens a new one), and the wire prefix is built only
// from the active context. The memory plugin uses this to filter
// out hits that the model already has in scope.
type CallerInfo struct {
	UserID          uuid.UUID
	ConversationID  uuid.UUID
	ActiveContextID uuid.UUID
}

type callerInfoKey struct{}

// WithCallerInfo attaches the caller identity to ctx. Zero-valued
// CallerInfo passes through as no-op; plugins must treat
// uuid.Nil fields as "unwired" and fail with a clear error rather
// than silently scoping to the wrong user.
func WithCallerInfo(ctx context.Context, info CallerInfo) context.Context {
	return context.WithValue(ctx, callerInfoKey{}, info)
}

// CallerInfoFrom returns the caller identity attached to ctx, or
// the zero value if the runtime didn't wire one.
func CallerInfoFrom(ctx context.Context) CallerInfo {
	v, _ := ctx.Value(callerInfoKey{}).(CallerInfo)
	return v
}
