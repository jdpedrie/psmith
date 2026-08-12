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

// FileUploader is the optional interface a driver implements to accept blob
// uploads and reference them by id instead of resending bytes.
//
// The problem it solves: history assembly inlines every attachment in a
// conversation on every send, so one image is base64'd and pushed upstream
// once per turn for the life of the chat. Providers with a Files API let the
// bytes cross once.
//
// The conversations service owns the lifecycle (look up, upload on miss,
// record the id and expiry, fall back to inline bytes on any failure); drivers
// provide only the upload call and the reference shape. A driver that does not
// implement this keeps sending inline bytes, which is the current behaviour
// and stays correct forever.
type FileUploader interface {
	// UploadFile sends bytes and returns the provider's id for them, plus the
	// expiry the provider chose. A zero expiry means the provider stated none
	// and the reference is treated as durable.
	//
	// Errors are non-fatal upstream: the caller falls back to inlining the
	// bytes, so a Files API outage degrades to today's behaviour rather than
	// failing the turn.
	UploadFile(ctx context.Context, mimeType, filename string, data []byte) (fileID string, expiresAt time.Time, err error)

	// SupportsFileReference reports whether a given mime type can travel as a
	// reference for this provider. Uploading something the request shape
	// cannot then reference would spend a round-trip to learn nothing.
	SupportsFileReference(mimeType string) bool
}
