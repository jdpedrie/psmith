package google

import (
	"context"
	"fmt"
	"time"

	"github.com/jdpedrie/clark/internal/providers"
)

// Google's implementation of providers.ExplicitCacheProvider. Wraps
// the existing CachedContent lifecycle methods (CreateCachedContent,
// DeleteCachedContent — see cached_content.go) so the conversations
// service can drive the lifecycle without knowing about
// provider-specific shapes.
//
// Compile-time interface check.
var _ providers.ExplicitCacheProvider = (*Driver)(nil)

// defaultExplicitCacheTTL is the lifetime requested when creating a
// cache. 1 hour balances "long enough that an active conversation
// gets many hits before we recreate" against "short enough that an
// abandoned conversation doesn't run up storage cost." Gemini's max
// is documented as days; min is 5 minutes.
const defaultExplicitCacheTTL = 1 * time.Hour

// CreateExplicitCacheRef opens a cachedContents resource for the
// given prefix and returns its server name + chosen expiry. Errors
// (most commonly: "prefix too short", below the per-model minimum)
// surface to the caller; the conversations service treats them as
// "skip caching this turn" rather than fatal.
func (d *Driver) CreateExplicitCacheRef(ctx context.Context, modelID string, prefix []providers.WireMessage) (string, time.Time, error) {
	cache, err := d.CreateCachedContent(ctx, CreateCachedContentRequest{
		ModelID:  modelID,
		Messages: prefix,
		TTL:      fmt.Sprintf("%ds", int(defaultExplicitCacheTTL.Seconds())),
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return cache.Name, time.Now().Add(defaultExplicitCacheTTL), nil
}

// ApplyExplicitCacheRef stashes the cache name on the
// Google-specific GoogleExtras.CachedContent runtime field (which the
// driver's send.go reads and emits as the request body's
// `cachedContent` field) and trims req.Messages to the new tail past
// the cached prefix.
func (d *Driver) ApplyExplicitCacheRef(req *providers.SendRequest, ref string, prefixMessageCount int) {
	if prefixMessageCount > 0 && prefixMessageCount <= len(req.Messages) {
		req.Messages = req.Messages[prefixMessageCount:]
	}
	if req.Settings.Google == nil {
		req.Settings.Google = &providers.GoogleExtras{}
	}
	r := ref
	req.Settings.Google.CachedContent = &r
}

// DeleteExplicitCacheRef cleans up an upstream cachedContents
// resource. Idempotent against 404s (already-deleted by Gemini's
// own TTL GC, etc).
func (d *Driver) DeleteExplicitCacheRef(ctx context.Context, ref string) error {
	return d.DeleteCachedContent(ctx, ref)
}
