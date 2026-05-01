package conversations

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/clark/internal/providers"
	googledriver "github.com/jdpedrie/clark/internal/providers/google"
	"github.com/jdpedrie/clark/internal/store"
)

// Server-managed Gemini cachedContents lifecycle. Opt-in per
// conversation via call_settings.google.explicit_cache. When enabled:
//
//   - On the first eligible turn (≥ Gemini's per-model minimum), we
//     create a cache containing the full wire prefix EXCEPT the just-
//     inserted user message. Subsequent turns reference the cache and
//     send only the trailing content beyond what was cached.
//   - Cache lookup is keyed by (context_id, model_id). A new context
//     (post-Compact) gets its own cache; switching models mid-
//     conversation also invalidates because cachedContents are model-
//     scoped server-side.
//   - On expiry or prefix divergence (an edit/regenerate that mutates
//     a previously-cached message), we drop the stale cache and try
//     to create a fresh one from the current prefix.
//
// Failures are non-fatal: if cache creation errors (most commonly
// "prefix too short"), the send proceeds without a cache reference
// and the user pays full price for that turn. We never block the user
// on cache machinery.

const (
	// defaultCacheTTL is the lifetime requested when creating a cache.
	// 1 hour balances "long enough that an active conversation gets
	// many hits before we recreate" against "short enough that an
	// abandoned conversation doesn't run up storage cost." Override
	// per-call via setExplicitCacheTTL if needed.
	defaultCacheTTL = 1 * time.Hour

	// cacheRecreateBuffer is how close to expiry we treat the cache as
	// stale. Recreating proactively avoids a window where the cache
	// expires mid-Send and Gemini returns a NotFound.
	cacheRecreateBuffer = 60 * time.Second
)

// maybeAttachGeminiCache resolves the existing cache for this
// (context, model) — creating one if absent and prefix is large
// enough. Returns the (possibly attached) cache resource name and the
// (possibly trimmed) wire messages. nil cacheName means "no cache
// attached, send wireMessages as-is."
//
// The driver pointer is the typed *google.Driver, not the generic
// providers.Provider, so we can call CreateCachedContent /
// DeleteCachedContent directly. Caller must pass nil when the
// in-flight provider isn't google.
func (s *Service) maybeAttachGeminiCache(
	ctx context.Context,
	driver *googledriver.Driver,
	contextID uuid.UUID,
	modelID string,
	wireMessages []providers.WireMessage,
) (cacheName *string, trimmedMessages []providers.WireMessage) {
	if driver == nil || len(wireMessages) < 2 {
		return nil, wireMessages
	}

	// 1. Look up existing cache for this (context, model).
	row, err := s.queries.GetGeminiCache(ctx, store.GetGeminiCacheParams{
		ContextID: contextID,
		ModelID:   modelID,
	})
	if err == nil {
		// Cache row exists — validate before attaching.
		if time.Until(row.ExpiresAt) > cacheRecreateBuffer &&
			int(row.PrefixMessageCount) <= len(wireMessages) {
			cachedPrefix := wireMessages[:row.PrefixMessageCount]
			if hashWirePrefix(cachedPrefix) == row.PrefixHash {
				// Hit: existing cache covers a prefix of the current
				// wire bytes verbatim. Reference + trim.
				name := row.CacheName
				return &name, wireMessages[row.PrefixMessageCount:]
			}
		}
		// Stale (expired soon) or diverged (edit/regenerate). Drop
		// the upstream resource + DB row before falling through to
		// create-fresh. Errors here are best-effort — Gemini GCs
		// expired caches on its own; the DB row gets overwritten by
		// the Upsert below.
		_ = driver.DeleteCachedContent(ctx, row.CacheName)
		_ = s.queries.DeleteGeminiCache(ctx, store.DeleteGeminiCacheParams{
			ContextID: contextID,
			ModelID:   modelID,
		})
	} else if !errors.Is(err, pgx.ErrNoRows) {
		// Unexpected DB error — log via the service's logger and bail
		// without caching. We never want cache machinery to block a
		// send.
		s.logger.Warn("gemini cache lookup failed", "err", err, "context_id", contextID, "model_id", modelID)
		return nil, wireMessages
	}

	// 2. Create a fresh cache from everything EXCEPT the just-inserted
	//    user message at the tail. Caching the tail user would force
	//    a recreate on every single turn (since the tail moves each
	//    turn) — net cost-negative. By caching wire[:N-1] we get
	//    multiple hits as the conversation grows beyond it.
	cacheCount := len(wireMessages) - 1
	cacheMessages := wireMessages[:cacheCount]

	cache, err := driver.CreateCachedContent(ctx, googledriver.CreateCachedContentRequest{
		ModelID:           modelID,
		DisplayName:       fmt.Sprintf("clark-context-%s", contextID.String()[:8]),
		Messages:          cacheMessages,
		TTL:               formatTTL(defaultCacheTTL),
	})
	if err != nil {
		// Most common: "prefix too short" (below the model's
		// per-tier minimum). Other failures: transient API errors,
		// rate limits. Either way, send normally.
		s.logger.Info("gemini cache create skipped",
			"err", err, "context_id", contextID, "model_id", modelID,
			"message_count", cacheCount)
		return nil, wireMessages
	}

	expiresAt := time.Now().Add(defaultCacheTTL)
	if err := s.queries.UpsertGeminiCache(ctx, store.UpsertGeminiCacheParams{
		ContextID:          contextID,
		ModelID:            modelID,
		CacheName:          cache.Name,
		PrefixMessageCount: int32(cacheCount),
		PrefixHash:         hashWirePrefix(cacheMessages),
		ExpiresAt:          expiresAt,
	}); err != nil {
		s.logger.Warn("gemini cache upsert failed (cache created upstream but not tracked locally)",
			"err", err, "cache_name", cache.Name)
		// Continue — the cache exists upstream and we're attaching
		// it for THIS turn. Worst case we'll create a duplicate on
		// the next turn since we won't find the row.
	}

	name := cache.Name
	return &name, wireMessages[cacheCount:]
}

// hashWirePrefix produces a stable digest over the wire-bytes-relevant
// fields of a slice of WireMessages. Used to verify a stored cache
// still represents the start of the current request's wire prefix —
// guards against silent edit/regenerate divergence where the
// PrefixMessageCount would still match but the bytes wouldn't.
func hashWirePrefix(msgs []providers.WireMessage) string {
	h := sha256.New()
	for _, m := range msgs {
		// Length-prefixed encoding so 'role:user content:hi' and
		// 'role:userc content:hi' don't collide.
		_, _ = fmt.Fprintf(h, "%d:%s\n%d:%s\n%d:", len(m.Role), m.Role, len(m.Content), m.Content, len(m.Thinking))
		_, _ = h.Write(m.Thinking)
		_, _ = h.Write([]byte("\n"))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// formatTTL renders a Go duration as the "<seconds>s" string Gemini's
// API expects (e.g. "3600s" for one hour).
func formatTTL(d time.Duration) string {
	return fmt.Sprintf("%ds", int(d.Seconds()))
}
