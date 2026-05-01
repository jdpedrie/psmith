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

	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
)

// Provider-agnostic explicit-cache lifecycle. The conversations
// service owns the orchestration (lookup → check expiry → check
// prefix-hash match → attach OR create-and-store); each driver opts in
// by implementing providers.ExplicitCacheProvider.
//
// Today only the Google driver implements the interface (cachedContents
// API). When the Anthropic driver grows an explicit-cache toggle, it
// implements the same interface and the orchestration here works
// unchanged.
//
// Failures are non-fatal: on any error we proceed without caching for
// this turn. Cache machinery never blocks a send.

// cacheRecreateBuffer is how close to expiry we treat a cache as
// stale. Recreating proactively avoids a window where the cache
// expires mid-Send and the upstream returns NotFound.
const cacheRecreateBuffer = 60 * time.Second

// maybeAttachExplicitCache resolves an existing cache for this
// (context, provider_type, model) — creating one if absent and the
// driver permits. Returns whether a cache was attached for this turn
// (for forensic stamping onto the assistant message). The req is
// mutated in-place by the driver's ApplyExplicitCacheRef when a cache
// is attached.
func (s *Service) maybeAttachExplicitCache(
	ctx context.Context,
	driver providers.ExplicitCacheProvider,
	providerType string,
	contextID uuid.UUID,
	modelID string,
	req *providers.SendRequest,
) (attached bool) {
	if driver == nil || len(req.Messages) < 2 {
		return false
	}

	// 1. Look up existing cache for this (context, provider_type, model).
	row, err := s.queries.GetExplicitCache(ctx, store.GetExplicitCacheParams{
		ContextID:    contextID,
		ProviderType: providerType,
		ModelID:      modelID,
	})
	if err == nil {
		if time.Until(row.ExpiresAt) > cacheRecreateBuffer &&
			int(row.PrefixMessageCount) <= len(req.Messages) {
			cachedPrefix := req.Messages[:row.PrefixMessageCount]
			if hashWirePrefix(cachedPrefix) == row.PrefixHash {
				driver.ApplyExplicitCacheRef(req, row.CacheRef, int(row.PrefixMessageCount))
				return true
			}
		}
		// Stale or diverged: drop upstream + DB row. Errors are
		// best-effort; the upsert below would overwrite the row.
		_ = driver.DeleteExplicitCacheRef(ctx, row.CacheRef)
		_ = s.queries.DeleteExplicitCache(ctx, store.DeleteExplicitCacheParams{
			ContextID:    contextID,
			ProviderType: providerType,
			ModelID:      modelID,
		})
	} else if !errors.Is(err, pgx.ErrNoRows) {
		s.logger.Warn("explicit cache lookup failed",
			"err", err, "context_id", contextID, "provider_type", providerType, "model_id", modelID)
		return false
	}

	// 2. Create a fresh cache from everything EXCEPT the just-inserted
	//    user message. Caching the tail user would force a recreate
	//    every turn (the tail moves each turn) — net cost-negative. By
	//    caching messages[:N-1] we get multiple hits as the
	//    conversation grows past the cached point.
	cacheCount := len(req.Messages) - 1
	cachePrefix := req.Messages[:cacheCount]

	ref, expiresAt, err := driver.CreateExplicitCacheRef(ctx, modelID, cachePrefix)
	if err != nil {
		// Most common: prefix-too-short (below per-model minimum).
		// Transient errors fall through here too. Send normally.
		s.logger.Info("explicit cache create skipped",
			"err", err, "context_id", contextID, "provider_type", providerType,
			"model_id", modelID, "message_count", cacheCount)
		return false
	}

	if err := s.queries.UpsertExplicitCache(ctx, store.UpsertExplicitCacheParams{
		ContextID:          contextID,
		ProviderType:       providerType,
		ModelID:            modelID,
		CacheRef:           ref,
		PrefixMessageCount: int32(cacheCount),
		PrefixHash:         hashWirePrefix(cachePrefix),
		ExpiresAt:          expiresAt,
	}); err != nil {
		s.logger.Warn("explicit cache upsert failed (cache created upstream but not tracked locally)",
			"err", err, "cache_ref", ref)
		// Continue — the cache exists upstream and we're attaching it
		// for THIS turn. Worst case we duplicate-create next turn.
	}

	driver.ApplyExplicitCacheRef(req, ref, cacheCount)
	return true
}

// hashWirePrefix produces a stable digest over the wire-bytes-relevant
// fields of a slice of WireMessages. Used to verify a stored cache's
// prefix bytes still match the start of the current request — guards
// against silent edit/regenerate divergence.
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
