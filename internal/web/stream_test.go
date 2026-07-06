package web

import (
	"context"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/conversations"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/modelproviders"
	_ "github.com/jdpedrie/psmith/internal/providers/anthropic" // register the real driver
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// TestHandleStream_E2E proves the spike's risky surface: a real assistant run
// (anthropic driver → fakellm → supervisor → durable chunks) is translated by
// the web stream handler into named SSE events (`message` carrying the rendered
// markdown, `done` closing the stream) for htmx's SSE extension to consume.
func TestHandleStream_E2E(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "Hello, "},
			{Type: fakellm.EventText, Text: "world!"},
		},
		Usage: &fakellm.Usage{InputTokens: 12, OutputTokens: 4},
	})

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Models: models, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, fake.URL())
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "webtest"})

	// Launch the run with explicit provider/model (the conversation has no
	// default model in this seed; model selection in the composer is a
	// fan-out item).
	pid, mid := fx.providerID.String(), fx.modelID
	sendResp, err := convos.SendMessage(userCtx, connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: fx.convID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID := sendResp.Msg.GetStreamRun().GetId()

	// Drive the web stream handler for that run.
	ctx, cancel := context.WithTimeout(userCtx, 10*time.Second)
	defer cancel()
	req := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/stream?run="+runID, nil).WithContext(ctx)
	req.SetPathValue("id", fx.convID.String())
	rec := httptest.NewRecorder()

	h.handleStream(rec, req)

	body := rec.Body.String()
	if !strings.Contains(body, "Hello, world!") {
		t.Fatalf("stream SSE missing assembled text; body:\n%s", body)
	}
	if !strings.Contains(body, "event: message") {
		t.Errorf("stream SSE missing message events; body:\n%s", body)
	}
	// The terminal event closes the htmx SSE connection.
	if !strings.Contains(body, "event: done") {
		t.Errorf("stream SSE missing done event; body:\n%s", body)
	}
}

// TestHandleConversation_RendersComposer proves the conversation page renders
// with the model picker populated from the user's enabled models.
func TestHandleConversation_RendersComposer(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Models: models, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "webtest"})

	req := httptest.NewRequest("GET", "/c/"+fx.convID.String(), nil).WithContext(userCtx)
	req.SetPathValue("id", fx.convID.String())
	rec := httptest.NewRecorder()

	h.handleConversation(rec, req)

	if rec.Code != 200 {
		t.Fatalf("status=%d want 200; body:\n%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	// The composer carries the rich model chip (not a <select>), showing the
	// current model and opening the picker overlay.
	for _, want := range []string{`id="composer"`, `id="messages"`, `id="composer-model-chip"`, "Claude Fake", `/c/` + fx.convID.String() + `/model`} {
		if !strings.Contains(body, want) {
			t.Errorf("conversation page missing %q", want)
		}
	}
}

type sendFixture struct {
	userID     uuid.UUID
	convID     uuid.UUID
	providerID uuid.UUID
	modelID    string
}

// seedSendable creates the minimal user/profile/conversation/context/system
// message + provider/model needed to launch a run, with the provider pointed
// at the fake LLM. Mirrors the conversations package's e2e seed.
func seedSendable(t *testing.T, q *store.Queries, baseURL string) sendFixture {
	t.Helper()
	ctx := context.Background()

	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	pid, _ := uuid.NewV7()
	sys := "You are concise."
	profile, err := q.CreateProfile(ctx, store.CreateProfileParams{ID: pid, UserID: user.ID, Name: "test", SystemMessage: &sys})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	cvid, _ := uuid.NewV7()
	conv, err := q.CreateConversation(ctx, store.CreateConversationParams{ID: cvid, UserID: user.ID, ProfileID: profile.ID})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	cxid, _ := uuid.NewV7()
	ctxRow, err := q.CreateContext(ctx, store.CreateContextParams{ID: cxid, ConversationID: conv.ID, ContextActivationTime: time.Now().UTC()})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	smid, _ := uuid.NewV7()
	if _, err := q.CreateMessage(ctx, store.CreateMessageParams{ID: smid, ContextID: ctxRow.ID, Role: "system", Content: sys}); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}

	prid, _ := uuid.NewV7()
	cfg := []byte(fmt.Sprintf(`{"api_key":"x","base_url":%q}`, baseURL))
	prov, err := q.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{ID: prid, UserID: user.ID, Type: "anthropic", Label: "test", ConfigEncrypted: cfg})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	modelID := "claude-fake"
	inPrice, outPrice := 3.0, 15.0
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID:   prov.ID,
		ModelID:               modelID,
		DisplayName:           "Claude Fake",
		InputPricePerMillion:  &inPrice,
		OutputPricePerMillion: &outPrice,
		MetadataSource:        "manual",
		MetadataSnapshotAt:    time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	return sendFixture{userID: user.ID, convID: conv.ID, providerID: prov.ID, modelID: modelID}
}
