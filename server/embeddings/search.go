package embeddings

import (
	"context"
	"fmt"
	"strings"

	"github.com/jdpedrie/psmith/pluginapi/host"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/pgvector/pgvector-go"
)

// SearchOptions and Hit are defined in pluginapi/host and aliased here.
//
// They are the search vocabulary a plugin speaks, so they belong with the
// plugin contract; defining them here instead would drag this package — and
// through it server/store and the whole database layer — into anything that
// imports the contract.
type (
	SearchOptions = host.SearchOptions
	Hit           = host.Hit
)

// Searcher embeds a query text and runs cosine-distance vector
// search against `messages`. The embedder is chosen per-call via the
// configured Resolver (so two users on the same instance with
// different configured embedders both work); the pool is the DB
// handle.
type Searcher struct {
	q        *store.Queries
	resolver Resolver
}

// NewSearcher wires the deps. The Resolver's Build is responsible
// for matching the dimension to `messages.embedding` (768 today); a
// mismatch surfaces at Search time as an `embedder dim mismatch`
// error.
func NewSearcher(pool *pgxpool.Pool, resolver Resolver) *Searcher {
	return &Searcher{q: store.New(pool), resolver: resolver}
}

const (
	defaultLimit = 10
	maxLimit     = 50
)

// Search runs the end-to-end embed + query path. Empty query
// returns (nil, nil) — the embedder would otherwise produce an
// arbitrary vector for whitespace and surface garbage results.
func (s *Searcher) Search(ctx context.Context, query string, opts SearchOptions) ([]Hit, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, nil
	}
	if opts.UserID == uuid.Nil {
		return nil, fmt.Errorf("search: UserID is required")
	}
	limit := opts.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}

	embedder, err := s.resolver.Resolve(ctx, opts.UserID)
	if err != nil {
		return nil, fmt.Errorf("search: resolve embedder: %w", err)
	}
	vecs, err := embedder.Embed(ctx, []string{query})
	if err != nil {
		return nil, fmt.Errorf("search: embed query: %w", err)
	}
	if len(vecs) != 1 {
		return nil, fmt.Errorf("search: embedder returned %d vectors", len(vecs))
	}
	v := pgvector.NewVector(vecs[0])
	model := embedder.Model()
	rows, err := s.q.SearchMessagesByEmbedding(ctx, store.SearchMessagesByEmbeddingParams{
		Embedding:      &v,
		UserID:         opts.UserID,
		EmbeddingModel: &model,
		Limit:          int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}

	out := make([]Hit, 0, len(rows))
	for _, r := range rows {
		if opts.MaxDistance > 0 && r.Distance > opts.MaxDistance {
			// Rows arrive sorted by distance ascending, so once we
			// pass the threshold every remaining row is also past
			// it. Bail early.
			break
		}
		title := ""
		if r.ConversationTitle != nil {
			title = *r.ConversationTitle
		}
		out = append(out, Hit{
			MessageID:         r.ID,
			ContextID:         r.ContextID,
			ConversationID:    r.ConversationID,
			ConversationTitle: title,
			Role:              r.Role,
			Content:           r.Content,
			CreatedAt:         r.CreatedAt,
			Distance:          r.Distance,
		})
	}
	return out, nil
}
