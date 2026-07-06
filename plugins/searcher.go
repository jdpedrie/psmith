package plugins

import (
	"context"

	"github.com/jdpedrie/psmith/internal/embeddings"
)

// Searcher is the runtime-injected dependency the `memory` plugin
// uses to look up older messages via semantic search. Mirrors the
// shape of ProviderResolver: the conversations service attaches an
// instance to the dispatch context right before ExecuteTool, and the
// plugin reads it via SearcherFrom(ctx).
//
// An interface rather than a concrete `*embeddings.Searcher` so the
// plugin's tests can mock it without standing up Postgres + an
// embedder. `*embeddings.Searcher` satisfies it for free — same
// method signature, same options struct.
type Searcher interface {
	Search(ctx context.Context, query string, opts embeddings.SearchOptions) ([]embeddings.Hit, error)
}

type searcherKey struct{}

// WithSearcher attaches a Searcher to ctx. Called by the dispatch
// site right before invoking the owning plugin's ExecuteTool. A nil
// Searcher is a no-op — the ctx is returned unchanged so plugins
// SearcherFrom() can safely report "no searcher configured."
func WithSearcher(ctx context.Context, s Searcher) context.Context {
	if s == nil {
		return ctx
	}
	return context.WithValue(ctx, searcherKey{}, s)
}

// SearcherFrom returns the Searcher attached to ctx, or nil if the
// runtime didn't wire one (PSMITH_EMBEDDER unset). Plugins should
// treat a nil return as a clean "search is not configured" path and
// surface a friendly tool-error rather than panicking.
func SearcherFrom(ctx context.Context) Searcher {
	v, _ := ctx.Value(searcherKey{}).(Searcher)
	return v
}
