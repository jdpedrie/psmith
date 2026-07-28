package providers

import (
	"context"
	"time"
)

// ExplicitCacheProvider is the optional interface a driver implements
// to opt in to server-managed explicit caching. The conversations
// service orchestrates the lifecycle (lookup → check expiry → check
// prefix-hash match → attach OR create-and-store); drivers provide
// only the three primitives below.
//
// Two distinct mechanisms fit the same interface today:
//
//   - Google Gemini: stateful upstream resource. CreateExplicitCacheRef
//     POSTs to /v1beta/cachedContents and returns the resource name.
//     ApplyExplicitCacheRef stashes the name on
//     SendRequest.Settings.Google.CachedContent so streamGenerateContent
//     references it; trims the request's contents past the cached
//     prefix. DeleteExplicitCacheRef DELETEs the resource.
//
//   - Future Anthropic explicit-cache toggle: stateless cache_control
//     boundary placement. CreateExplicitCacheRef returns a sentinel
//     ref + far-future expiry (Anthropic doesn't have a separate
//     create call); ApplyExplicitCacheRef tells the driver to mark a
//     cache_control breakpoint at the boundary; DeleteExplicitCacheRef
//     is a no-op.
//
// Drivers that don't implement the interface (most OpenAI-compat
// presets) are silently no-op'd by the conversations service when the
// toggle is on.
type ExplicitCacheProvider interface {
	// CreateExplicitCacheRef opens an upstream cache covering `prefix`
	// for `modelID`. Returns an opaque reference (driver-specific
	// shape; the conversations service stores it verbatim) plus the
	// expiry the driver chose. Errors are non-fatal upstream — the
	// conversations service logs and proceeds without caching.
	CreateExplicitCacheRef(ctx context.Context, modelID string, prefix []WireMessage) (ref string, expiresAt time.Time, err error)

	// ApplyExplicitCacheRef mutates a SendRequest in-place to use the
	// cache. The conversations service has already verified the cache
	// is valid (not expired, prefix-hash matches); the driver just
	// wires the reference into its provider-specific request shape and
	// trims req.Messages to the new tail. prefixMessageCount is the
	// number of leading WireMessages the cache covers — the driver
	// uses this to do the trim.
	ApplyExplicitCacheRef(req *SendRequest, ref string, prefixMessageCount int)

	// DeleteExplicitCacheRef cleans up an upstream resource. Called by
	// the conversations service on cache invalidation (TTL expiry,
	// prefix divergence). Idempotent against already-deleted refs.
	DeleteExplicitCacheRef(ctx context.Context, ref string) error
}
