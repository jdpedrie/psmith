package embeddersvc

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/pgvector/pgvector-go"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/embeddings"
	"github.com/jdpedrie/psmith/server/store"
)

// embeddedMessage writes one message for user, embedded under model.
func embeddedMessage(t *testing.T, q *store.Queries, userID uuid.UUID, model string) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	p, err := q.CreateProfile(ctx, store.CreateProfileParams{ID: uuid.New(), UserID: userID, Name: "p-" + uuid.NewString()[:6]})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	c, err := q.CreateConversation(ctx, store.CreateConversationParams{ID: uuid.New(), UserID: userID, ProfileID: p.ID})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	cx, err := q.CreateContext(ctx, store.CreateContextParams{ID: uuid.New(), ConversationID: c.ID, ContextActivationTime: time.Now().UTC()})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	m, err := q.CreateMessage(ctx, store.CreateMessageParams{ID: uuid.New(), ContextID: cx.ID, Role: "user", Content: "remember the tides"})
	if err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}
	v := pgvector.NewVector(make([]float32, embeddings.StoredDimensions))
	at := time.Now().UTC()
	if err := q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{ID: m.ID, Embedding: &v, EmbeddingModel: &model, EmbeddingAt: &at}); err != nil {
		t.Fatalf("SetMessageEmbedding: %v", err)
	}
	return m.ID
}

func embeddingModel(t *testing.T, q *store.Queries, id uuid.UUID) *string {
	t.Helper()
	m, err := q.GetMessageByID(context.Background(), id)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	return m.EmbeddingModel
}

func save(t *testing.T, f fixture, model string) {
	t.Helper()
	enabled := true
	if _, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type: strPtr("openai"), BaseUrl: strPtr("http://localhost:11434/v1"), Model: strPtr(model),
		Dimensions: int32Ptr(768), Enabled: &enabled,
	})); err != nil {
		t.Fatalf("Update to %s: %v", model, err)
	}
}

// A new model can't search the old one's vectors, so they go and the
// backfill worker finds every row unembedded again.
func TestUpdateEmbedderConfig_ModelChangeClearsOldVectors(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	save(t, f, "nomic-embed-text")
	mine := embeddedMessage(t, f.queries, f.user.ID, "nomic-embed-text")

	other, err := f.queries.CreateUser(context.Background(), store.CreateUserParams{ID: uuid.New(), Username: "other-" + uuid.NewString()[:8], PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	theirs := embeddedMessage(t, f.queries, other.ID, "nomic-embed-text")

	before, err := f.queries.CountUnembeddedMessages(context.Background(), f.user.ID)
	if err != nil || before != 0 {
		t.Fatalf("unembedded before = %d, %v; want 0", before, err)
	}

	save(t, f, "mxbai-embed-large")

	if m := embeddingModel(t, f.queries, mine); m != nil {
		t.Errorf("my vector survived the model change, still under %q", *m)
	}
	if n, _ := f.queries.CountUnembeddedMessages(context.Background(), f.user.ID); n != 1 {
		t.Errorf("unembedded after = %d, want 1 so the worker re-embeds it", n)
	}
	if m := embeddingModel(t, f.queries, theirs); m == nil || *m != "nomic-embed-text" {
		t.Errorf("another user's vector was touched: %v", m)
	}
}

// Saving without changing the model (a new key, say) keeps the vectors.
func TestUpdateEmbedderConfig_SameModelKeepsVectors(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	save(t, f, "nomic-embed-text")
	id := embeddedMessage(t, f.queries, f.user.ID, "nomic-embed-text")

	key := "new-key"
	if _, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{ApiKey: &key})); err != nil {
		t.Fatalf("Update key: %v", err)
	}
	if m := embeddingModel(t, f.queries, id); m == nil || *m != "nomic-embed-text" {
		t.Errorf("vector lost on a save that kept the model: %v", m)
	}
}

// The column holds 768-dimension vectors; any other size would make every
// write fail, so the config is refused.
func TestUpdateEmbedderConfig_RejectsUnstorableDimensions(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type: strPtr("openai"), BaseUrl: strPtr("https://api.openai.com/v1"), Model: strPtr("text-embedding-3-small"),
		Dimensions: int32Ptr(1536),
	}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("err = %v, want InvalidArgument", err)
	}
	if _, err := f.queries.GetUserEmbedderConfig(context.Background(), f.user.ID); err == nil {
		t.Error("a refused config was saved anyway")
	}
}
