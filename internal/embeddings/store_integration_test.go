// Integration tests for the new embedding columns + queries. Exercises
// the migration (extension + columns + CHECK constraint + indexes) end-
// to-end against a real Postgres via pgtestdb. Lives in package
// embeddings_test so the embeddings package itself stays a pure-Go
// dependency-free island; the heavy lifting (internal/store, testutil)
// rides in the external test package.
package embeddings_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
	"github.com/pgvector/pgvector-go"
)

// embedFixture seeds a user, conversation, context and three messages
// so SearchMessagesByEmbedding has something to find. Returns the
// pieces tests need to assert and a closer the test should call when
// done.
type embedFixture struct {
	pool      *pgxpool.Pool
	q         *store.Queries
	userID    uuid.UUID
	convID    uuid.UUID
	contextID uuid.UUID
	// Three messages, none embedded yet. Tests embed and search as
	// they go.
	msgs []store.Message
}

func newEmbedFixture(t *testing.T) *embedFixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	u, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           uuid.New(),
		Username:     "search-test-" + uuid.NewString()[:8],
		PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	p, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID:     uuid.New(),
		UserID: u.ID,
		Name:   "search-test-profile",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	c, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID:        uuid.New(),
		UserID:    u.ID,
		ProfileID: p.ID,
		Title:     strPtr("search smoke"),
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	cx, err := q.CreateContext(ctx, store.CreateContextParams{
		ID:                    uuid.New(),
		ConversationID:        c.ID,
		ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	contents := []string{
		"the quick brown fox jumps over the lazy dog",
		"vector databases enable semantic similarity search",
		"my favorite jazz album is Kind of Blue",
	}
	msgs := make([]store.Message, 0, len(contents))
	var parent *uuid.UUID
	for _, body := range contents {
		m, err := q.CreateMessage(ctx, store.CreateMessageParams{
			ID:        uuid.New(),
			ContextID: cx.ID,
			ParentID:  parent,
			Role:      "user",
			Content:   body,
		})
		if err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		msgs = append(msgs, m)
		id := m.ID
		parent = &id
	}

	return &embedFixture{
		pool: pool, q: q,
		userID: u.ID, convID: c.ID, contextID: cx.ID,
		msgs: msgs,
	}
}

func strPtr(s string) *string { return &s }

// vec3 builds a small test-only 3-component vector right-padded with
// zeros to the column's 768 dim. Real vectors come from an embedder;
// this lets the storage tests compare distances deterministically
// without standing up a real Ollama.
func vec3(a, b, c float32) pgvector.Vector {
	v := make([]float32, 768)
	v[0], v[1], v[2] = a, b, c
	return pgvector.NewVector(v)
}

func TestSetAndSearchEmbedding_RoundTrip(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// Embed each message with a distinct vector so distances are
	// deterministic. Query at (1,0,0) — m0 is identical, m1 is
	// orthogonal, m2 is opposite.
	vectors := []pgvector.Vector{
		vec3(1, 0, 0),
		vec3(0, 1, 0),
		vec3(-1, 0, 0),
	}
	model := "test-embedder-v1"
	now := time.Now().UTC()
	for i, m := range f.msgs {
		v := vectors[i]
		mdl := model
		at := now
		if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
			ID:             m.ID,
			Embedding:      &v,
			EmbeddingModel: &mdl,
			EmbeddingAt:    &at,
		}); err != nil {
			t.Fatalf("SetMessageEmbedding[%d]: %v", i, err)
		}
	}

	// Search.
	query := vec3(1, 0, 0)
	mdl := model
	hits, err := f.q.SearchMessagesByEmbedding(ctx, store.SearchMessagesByEmbeddingParams{
		Embedding:      &query,
		UserID:         f.userID,
		EmbeddingModel: &mdl,
		Limit:          5,
	})
	if err != nil {
		t.Fatalf("SearchMessagesByEmbedding: %v", err)
	}
	if len(hits) != 3 {
		t.Fatalf("got %d hits, want 3", len(hits))
	}
	// Top hit should be the identical-vector message.
	if hits[0].ID != f.msgs[0].ID {
		t.Errorf("top hit id=%s, want %s", hits[0].ID, f.msgs[0].ID)
	}
	// Distance to identical vector should be ~0.
	if hits[0].Distance > 0.001 {
		t.Errorf("top distance=%f, want ~0", hits[0].Distance)
	}
	// Distance ordering: closer ones first.
	if !(hits[0].Distance < hits[1].Distance && hits[1].Distance < hits[2].Distance) {
		t.Errorf("distances not monotonically increasing: %v %v %v",
			hits[0].Distance, hits[1].Distance, hits[2].Distance)
	}
	// Conversation join carries the title through.
	if hits[0].ConversationTitle == nil || *hits[0].ConversationTitle != "search smoke" {
		t.Errorf("conversation_title=%v", hits[0].ConversationTitle)
	}
}

func TestSearchByEmbedding_FiltersByModel(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// Half on model-A, half on model-B. A query under model-A must
	// only see model-A rows — mixing vector spaces is meaningless.
	now := time.Now().UTC()
	a := "model-A"
	b := "model-B"
	vA := vec3(1, 0, 0)
	vB := vec3(1, 0, 0)
	mustSet := func(id uuid.UUID, v pgvector.Vector, mdl string) {
		if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
			ID: id, Embedding: &v, EmbeddingModel: &mdl, EmbeddingAt: &now,
		}); err != nil {
			t.Fatalf("SetMessageEmbedding(%s, %s): %v", id, mdl, err)
		}
	}
	mustSet(f.msgs[0].ID, vA, a)
	mustSet(f.msgs[1].ID, vB, b)

	q := vec3(1, 0, 0)
	hits, err := f.q.SearchMessagesByEmbedding(ctx, store.SearchMessagesByEmbeddingParams{
		Embedding: &q, UserID: f.userID, EmbeddingModel: &a, Limit: 10,
	})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(hits) != 1 || hits[0].ID != f.msgs[0].ID {
		t.Errorf("hits=%+v; want only model-A row", hits)
	}
}

func TestSearchByEmbedding_FiltersByUser(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// Embed a message under user 1.
	now := time.Now().UTC()
	m := "model-x"
	v := vec3(1, 0, 0)
	if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
		ID: f.msgs[0].ID, Embedding: &v, EmbeddingModel: &m, EmbeddingAt: &now,
	}); err != nil {
		t.Fatalf("SetMessageEmbedding: %v", err)
	}

	// A different user searching with the same model must not see it.
	otherUser, err := f.q.CreateUser(ctx, store.CreateUserParams{
		ID: uuid.New(), Username: "other-" + uuid.NewString()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser other: %v", err)
	}
	q := v
	hits, err := f.q.SearchMessagesByEmbedding(ctx, store.SearchMessagesByEmbeddingParams{
		Embedding: &q, UserID: otherUser.ID, EmbeddingModel: &m, Limit: 10,
	})
	if err != nil {
		t.Fatalf("Search other-user: %v", err)
	}
	if len(hits) != 0 {
		t.Errorf("cross-user leak: got %d hits, want 0", len(hits))
	}
}

func TestClearEmbedding_DropsFromSearch(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	now := time.Now().UTC()
	m := "m"
	v := vec3(1, 0, 0)
	if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
		ID: f.msgs[0].ID, Embedding: &v, EmbeddingModel: &m, EmbeddingAt: &now,
	}); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := f.q.ClearMessageEmbedding(ctx, f.msgs[0].ID); err != nil {
		t.Fatalf("Clear: %v", err)
	}

	q := v
	hits, err := f.q.SearchMessagesByEmbedding(ctx, store.SearchMessagesByEmbeddingParams{
		Embedding: &q, UserID: f.userID, EmbeddingModel: &m, Limit: 10,
	})
	if err != nil {
		t.Fatalf("Search post-clear: %v", err)
	}
	if len(hits) != 0 {
		t.Errorf("Clear left rows behind: %+v", hits)
	}

	// And ListUnembeddedMessages should see it again.
	rows, err := f.q.ListUnembeddedMessages(ctx, 10)
	if err != nil {
		t.Fatalf("ListUnembeddedMessages: %v", err)
	}
	var found bool
	for _, r := range rows {
		if r.ID == f.msgs[0].ID {
			found = true
		}
	}
	if !found {
		t.Errorf("cleared message not surfaced by ListUnembeddedMessages: %+v", rows)
	}
}

func TestCheckConstraint_PartialEmbeddingTripleRejected(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// Direct UPDATE that violates the triple-or-none invariant. The
	// CHECK constraint should reject it — the worker's write paths
	// always set all three or none, but a misbehaving migration or a
	// hand-edited row mustn't silently corrupt the search shard.
	_, err := f.pool.Exec(ctx,
		`UPDATE messages SET embedding_model = $1 WHERE id = $2`,
		"orphan", f.msgs[0].ID)
	if err == nil || !strings.Contains(err.Error(), "messages_embedding_triple_invariant") {
		t.Errorf("want CHECK violation, got %v", err)
	}
}

func TestListUnembeddedMessages_SkipsSystemAndEmpty(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// System row + empty-body row should not appear.
	sysID := uuid.New()
	if _, err := f.q.CreateMessage(ctx, store.CreateMessageParams{
		ID: sysID, ContextID: f.contextID, Role: "system", Content: "framing",
	}); err != nil {
		t.Fatalf("Create system: %v", err)
	}
	emptyID := uuid.New()
	if _, err := f.q.CreateMessage(ctx, store.CreateMessageParams{
		ID: emptyID, ContextID: f.contextID, Role: "user", Content: "",
	}); err != nil {
		t.Fatalf("Create empty: %v", err)
	}

	rows, err := f.q.ListUnembeddedMessages(ctx, 100)
	if err != nil {
		t.Fatalf("ListUnembeddedMessages: %v", err)
	}
	for _, r := range rows {
		if r.ID == sysID {
			t.Errorf("system message surfaced: %+v", r)
		}
		if r.ID == emptyID {
			t.Errorf("empty-content message surfaced: %+v", r)
		}
	}

	count, err := f.q.CountUnembeddedMessages(ctx)
	if err != nil {
		t.Fatalf("CountUnembeddedMessages: %v", err)
	}
	if int(count) != len(f.msgs) {
		t.Errorf("count=%d, want %d (the 3 seed rows; system+empty excluded)",
			count, len(f.msgs))
	}
}

func TestListMessagesEmbeddedUnderDifferentModel(t *testing.T) {
	t.Parallel()
	f := newEmbedFixture(t)
	ctx := context.Background()

	// Embed two under old model, one under new.
	old := "old-model"
	new_ := "new-model"
	now := time.Now().UTC()
	v := vec3(1, 0, 0)
	for _, id := range []uuid.UUID{f.msgs[0].ID, f.msgs[1].ID} {
		if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
			ID: id, Embedding: &v, EmbeddingModel: &old, EmbeddingAt: &now,
		}); err != nil {
			t.Fatalf("Set old: %v", err)
		}
	}
	if err := f.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
		ID: f.msgs[2].ID, Embedding: &v, EmbeddingModel: &new_, EmbeddingAt: &now,
	}); err != nil {
		t.Fatalf("Set new: %v", err)
	}

	rows, err := f.q.ListMessagesEmbeddedUnderDifferentModel(ctx,
		store.ListMessagesEmbeddedUnderDifferentModelParams{
			EmbeddingModel: &new_,
			Limit:          10,
		})
	if err != nil {
		t.Fatalf("ListUnderDifferentModel: %v", err)
	}
	if len(rows) != 2 {
		t.Errorf("got %d rows, want 2 (the two embedded under old-model)", len(rows))
	}
}
