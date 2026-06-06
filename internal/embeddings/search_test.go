package embeddings_test

import (
	"context"
	"testing"
	"time"

	"github.com/jdpedrie/reeve/internal/embeddings"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/pgvector/pgvector-go"
)

// directionalStub returns a vector pointed along the +X axis for any
// input containing "fox", along +Y for "vector", and along +Z for
// anything else. Lets search tests assert "the query about foxes
// returned the fox message."
type directionalStub struct{}

func (directionalStub) Model() string   { return "directional-stub" }
func (directionalStub) Dimensions() int { return 768 }

func (directionalStub) Embed(_ context.Context, inputs []string) ([][]float32, error) {
	out := make([][]float32, len(inputs))
	for i, in := range inputs {
		v := make([]float32, 768)
		switch {
		case containsAny(in, "fox", "dog", "lazy"):
			v[0] = 1
		case containsAny(in, "vector", "search", "semantic"):
			v[1] = 1
		default:
			v[2] = 1
		}
		out[i] = v
	}
	return out, nil
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if len(s) >= len(sub) && (indexOf(s, sub) >= 0) {
			return true
		}
	}
	return false
}

func indexOf(s, sub string) int {
	// strings.Contains-equivalent; inlined to avoid importing strings
	// just for one call in a test file.
	n := len(sub)
	if n == 0 {
		return 0
	}
	for i := 0; i+n <= len(s); i++ {
		if s[i:i+n] == sub {
			return i
		}
	}
	return -1
}

func TestSearch_FindsRelevantHits(t *testing.T) {
	t.Parallel()
	f, _, _ := newWorkerFixture(t, []string{
		"the quick brown fox jumps over the lazy dog",
		"vector databases enable semantic similarity search",
		"my favorite jazz album is Kind of Blue",
	})

	// Embed each message directly so the test doesn't depend on the
	// worker loop. Each gets the same axis the search query will hit.
	model := "directional-stub"
	now := time.Now().UTC()
	dirs := []pgvector.Vector{
		dirVec(1, 0, 0), // matches "fox"
		dirVec(0, 1, 0), // matches "vector"
		dirVec(0, 0, 1), // matches "anything else"
	}
	for i, m := range f.msgs {
		mdl := model
		at := now
		v := dirs[i]
		if err := f.q.SetMessageEmbedding(context.Background(), store.SetMessageEmbeddingParams{
			ID: m.ID, Embedding: &v, EmbeddingModel: &mdl, EmbeddingAt: &at,
		}); err != nil {
			t.Fatalf("seed embedding[%d]: %v", i, err)
		}
	}

	s := embeddings.NewSearcher(f.pool, directionalStub{})

	hits, err := s.Search(context.Background(), "tell me about foxes",
		embeddings.SearchOptions{UserID: f.userID, Limit: 5})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(hits) == 0 {
		t.Fatal("expected at least one hit")
	}
	// Top hit should be the fox message (same +X direction as query).
	if hits[0].MessageID != f.msgs[0].ID {
		t.Errorf("top hit id=%s, want fox message %s",
			hits[0].MessageID, f.msgs[0].ID)
	}
	if hits[0].Distance >= hits[len(hits)-1].Distance {
		t.Errorf("distances not ascending: %v", hits)
	}
}

func TestSearch_EmptyQueryReturnsNil(t *testing.T) {
	t.Parallel()
	f, _, _ := newWorkerFixture(t, []string{"x"})
	s := embeddings.NewSearcher(f.pool, directionalStub{})
	got, err := s.Search(context.Background(), "   ",
		embeddings.SearchOptions{UserID: f.userID, Limit: 5})
	if err != nil {
		t.Fatalf("Search empty: %v", err)
	}
	if got != nil {
		t.Errorf("empty query should return nil, got %v", got)
	}
}

func TestSearch_RequiresUserID(t *testing.T) {
	t.Parallel()
	f, _, _ := newWorkerFixture(t, []string{"x"})
	s := embeddings.NewSearcher(f.pool, directionalStub{})
	_, err := s.Search(context.Background(), "anything",
		embeddings.SearchOptions{Limit: 5})
	if err == nil || !contains(err.Error(), "UserID is required") {
		t.Errorf("want UserID error, got %v", err)
	}
}

func TestSearch_MaxDistanceFilters(t *testing.T) {
	t.Parallel()
	f, _, _ := newWorkerFixture(t, []string{
		"the fox", "unrelated content",
	})
	model := "directional-stub"
	now := time.Now().UTC()
	dirs := []pgvector.Vector{
		dirVec(1, 0, 0),  // matches the "fox" query
		dirVec(-1, 0, 0), // opposite direction → distance = 2.0
	}
	for i, m := range f.msgs {
		mdl := model
		at := now
		v := dirs[i]
		if err := f.q.SetMessageEmbedding(context.Background(), store.SetMessageEmbeddingParams{
			ID: m.ID, Embedding: &v, EmbeddingModel: &mdl, EmbeddingAt: &at,
		}); err != nil {
			t.Fatalf("seed [%d]: %v", i, err)
		}
	}
	s := embeddings.NewSearcher(f.pool, directionalStub{})

	hits, err := s.Search(context.Background(), "fox query",
		embeddings.SearchOptions{
			UserID:      f.userID,
			Limit:       10,
			MaxDistance: 0.5,
		})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(hits) != 1 {
		t.Errorf("got %d hits, want 1 (the opposite-direction row should be filtered)", len(hits))
	}
}

func TestSearch_LimitClampedAtMax(t *testing.T) {
	t.Parallel()
	f, _, _ := newWorkerFixture(t, nil)
	s := embeddings.NewSearcher(f.pool, directionalStub{})
	// Request 9999 hits; should not error or hang. Empty result is
	// fine — the assertion is that the clamp doesn't crash the path.
	hits, err := s.Search(context.Background(), "anything",
		embeddings.SearchOptions{UserID: f.userID, Limit: 9999})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(hits) != 0 {
		t.Errorf("empty DB should yield empty hits, got %v", hits)
	}
}

// dirVec builds a small directional vector right-padded to 768 dim.
func dirVec(a, b, c float32) pgvector.Vector {
	v := make([]float32, 768)
	v[0], v[1], v[2] = a, b, c
	return pgvector.NewVector(v)
}

func contains(haystack, needle string) bool {
	return indexOf(haystack, needle) >= 0
}
