package embeddings

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/pgvector/pgvector-go"
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

// SearchOptions narrows the search. UserID is required (every
// search is scoped to one user's history; cross-user results are a
// privacy bug). Limit defaults to defaultLimit.
type SearchOptions struct {
	// UserID scopes the search. Required — there is no
	// cross-user search surface.
	UserID uuid.UUID

	// Limit caps the result count. Default 10, max 50; values
	// above the cap are silently clamped — the model rarely
	// benefits from more than 10-20 historical snippets and
	// asking for hundreds inflates the wire round-trip without
	// helping accuracy.
	Limit int

	// MaxDistance optionally drops hits with cosine distance
	// above the threshold. 0 = no filter (return everything the
	// LIMIT allows). 2.0 = "everything"; 0.4 is a reasonable
	// "definitely relevant" cutoff for nomic-embed-text. Most
	// callers leave this at 0 and apply their own filter on the
	// returned distances.
	MaxDistance float64
}

const (
	defaultLimit = 10
	maxLimit     = 50
)

// Hit is one ranked message result. Distance is cosine — smaller
// is more similar; 0 = identical direction, 2 = opposite. Content
// is the raw message text (no truncation here; the caller decides
// how to summarize).
//
// ContextID + ConversationID travel together because a conversation
// is a sequence of contexts (compression retires an old context and
// opens a new one). The memory plugin uses ContextID to drop hits
// already in the wire prefix; conversation_id is the human-level
// grouping for display.
type Hit struct {
	MessageID         uuid.UUID
	ContextID         uuid.UUID
	ConversationID    uuid.UUID
	ConversationTitle string
	Role              string
	Content           string
	CreatedAt         time.Time
	// Distance is the cosine distance from the query vector.
	// Lower = more similar. Use it to threshold "definitely
	// relevant" (e.g. < 0.4 for nomic-embed-text) or to render a
	// confidence indicator alongside each hit.
	Distance float64
}

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
