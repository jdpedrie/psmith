package conversations

import (
	"context"
	"sync"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/profiles"
	"github.com/jdpedrie/psmith/server/store"
)

// profileCache memoizes profile resolution for the life of one request.
//
// profiles.Resolve loads a row and then walks the parent chain with a query per
// level. A single SendMessage asks four separate questions of the same profile
// (which model, which plugins, whether to include thinking, which call
// settings), each through a helper that was written to resolve for itself. Each
// helper is correct alone; the cost only exists because they run on one
// request. On a three-deep inheritance chain that is a dozen queries about one
// object that cannot change mid-request.
//
// Memoizing rather than threading a resolved value through five signatures is
// deliberate: the helpers have callers outside the send path (compaction,
// token counting, display conversion) that have no resolved profile to pass,
// and a cache makes "resolve once" structural instead of something every call
// site has to remember.
//
// Request-scoped, never shared. A cache that outlived the request would serve
// a stale profile after an edit, and the whole point of the inheritance chain
// is that edits to a parent take effect immediately.
type profileCache struct {
	q  *store.Queries
	mu sync.Mutex
	// Keyed by the STARTING profile id, not by any ancestor: two children of
	// one parent resolve to different values.
	//
	// Both halves are kept because callers need different ones. Ownership
	// checks read the raw row's user_id and must run BEFORE resolving, so
	// that a caller who does not own a profile never pays for its chain walk.
	raw      map[uuid.UUID]store.Profile
	resolved map[uuid.UUID]store.Profile
}

func newProfileCache(q *store.Queries) *profileCache {
	return &profileCache{
		q:        q,
		raw:      map[uuid.UUID]store.Profile{},
		resolved: map[uuid.UUID]store.Profile{},
	}
}

// resolve returns the profile with its inheritance chain applied.
//
// The lock is held across the DB work on purpose. Concurrent callers within
// one request are rare, and letting two of them race to resolve the same
// profile would spend exactly the queries this exists to avoid.
func (c *profileCache) resolve(ctx context.Context, id uuid.UUID) (store.Profile, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if p, ok := c.resolved[id]; ok {
		return p, nil
	}
	row, err := c.loadLocked(ctx, id)
	if err != nil {
		return store.Profile{}, err
	}
	resolved, err := profiles.Resolve(ctx, c.q, row)
	if err != nil {
		return store.Profile{}, err
	}
	c.resolved[id] = resolved
	return resolved, nil
}

// load returns the unresolved row, for ownership checks.
func (c *profileCache) load(ctx context.Context, id uuid.UUID) (store.Profile, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loadLocked(ctx, id)
}

func (c *profileCache) loadLocked(ctx context.Context, id uuid.UUID) (store.Profile, error) {
	if p, ok := c.raw[id]; ok {
		return p, nil
	}
	row, err := c.q.GetProfileByID(ctx, id)
	if err != nil {
		return store.Profile{}, err
	}
	c.raw[id] = row
	return row, nil
}

// profileCacheKey carries a request-scoped cache on the context.
//
// The context is the honest place for it: it is request-scoped state that
// every layer of one call tree should share and no layer should own. Absent is
// a supported state — helpers fall back to resolving directly, so a caller
// that never installs one behaves exactly as before.
type profileCacheKey struct{}

func withProfileCache(ctx context.Context, c *profileCache) context.Context {
	return context.WithValue(ctx, profileCacheKey{}, c)
}

// resolveProfile resolves through the request's cache when there is one, and
// directly when there is not.
func (s *Service) resolveProfile(ctx context.Context, id uuid.UUID) (store.Profile, error) {
	if c, ok := ctx.Value(profileCacheKey{}).(*profileCache); ok && c != nil {
		return c.resolve(ctx, id)
	}
	row, err := s.queries.GetProfileByID(ctx, id)
	if err != nil {
		return store.Profile{}, err
	}
	return profiles.Resolve(ctx, s.queries, row)
}

// loadProfile returns the unresolved row through the request's cache, for
// ownership checks that must run before any chain walk.
func (s *Service) loadProfile(ctx context.Context, id uuid.UUID) (store.Profile, error) {
	if c, ok := ctx.Value(profileCacheKey{}).(*profileCache); ok && c != nil {
		return c.load(ctx, id)
	}
	return s.queries.GetProfileByID(ctx, id)
}
