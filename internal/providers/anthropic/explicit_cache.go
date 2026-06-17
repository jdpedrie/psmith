package anthropic

import (
	"context"
	"time"

	"github.com/jdpedrie/spalt/internal/providers"
)

// Anthropic's implementation of providers.ExplicitCacheProvider.
//
// Unlike Google's stateful cachedContents API, Anthropic's prompt
// cache is byte-keyed and managed server-side via cache_control
// breakpoints embedded directly in the request. There is no separate
// "create cache" call and no upstream resource to delete.
//
// What "explicit caching toggle ON" means for Anthropic: switch from
// the default 5-minute ephemeral TTL to the 1-hour TTL on the auto
// cache_control marker. The longer TTL doubles the cache-write cost
// up front but pays back faster on conversations that span > 5 minutes
// — which is exactly what the toggle's user is signalling: "I want
// this cache to stay warm beyond the implicit window."
//
// The driver's existing applyAutoCacheControl (send.go) places ONE
// breakpoint at the end of the stable prefix on every send. We don't
// add more breakpoints here — Anthropic's tier limit is 4 total per
// request, and burning more than one for the conversation prefix
// gains little when the assistant + new user content is small.
//
// Compile-time interface check.
var _ providers.ExplicitCacheProvider = (*Driver)(nil)

// anthropicExplicitTTL is the lifetime the toggle requests when
// active. Mirrors the longer of Anthropic's two ephemeral tiers; the
// shorter (5m) is the SDK default applied when no extras are set.
const anthropicExplicitTTL = 1 * time.Hour

// CreateExplicitCacheRef returns a sentinel ref + 1h-from-now expiry.
// No upstream call — Anthropic has no separate cache-create API. The
// orchestration in conversations/explicit_cache.go still writes a row
// to the explicit_caches table so per-message attribution
// (explicit_cache_attached) lights up correctly. The "ref" string is
// opaque to the orchestration; we use a stable label rather than a
// per-call random so duplicate-create attempts (e.g. clock skew) are
// idempotent at the row level.
func (d *Driver) CreateExplicitCacheRef(ctx context.Context, modelID string, prefix []providers.WireMessage) (string, time.Time, error) {
	return "anthropic-ephemeral-1h", time.Now().Add(anthropicExplicitTTL), nil
}

// ApplyExplicitCacheRef tells the driver's send-time auto-cache_control
// placement to use the 1-hour TTL instead of the 5-minute default.
// Doesn't trim req.Messages — Anthropic's cache is byte-keyed; the
// full prefix always travels on the wire and the server matches it
// against its cache. (Compare to Google, where cachedContents holds
// the prefix server-side and the request only carries the new tail.)
func (d *Driver) ApplyExplicitCacheRef(req *providers.SendRequest, ref string, prefixMessageCount int) {
	if req.Settings.Anthropic == nil {
		req.Settings.Anthropic = &providers.AnthropicExtras{}
	}
	req.Settings.Anthropic.CacheTTL = providers.CacheTTL1h
}

// DeleteExplicitCacheRef is a no-op. Anthropic GCs ephemeral caches
// via TTL; there is no DELETE endpoint to call, and the local row's
// removal is handled by the conversations service's storage layer.
func (d *Driver) DeleteExplicitCacheRef(ctx context.Context, ref string) error {
	return nil
}
