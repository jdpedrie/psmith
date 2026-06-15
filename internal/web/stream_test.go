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

	"github.com/jdpedrie/reeve/fakellm"
	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	_ "github.com/jdpedrie/reeve/internal/providers/anthropic" // register the real driver
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestHandleStream_E2E proves the spike's risky surface: a real assistant run
// (anthropic driver → fakellm → supervisor → durable chunks) is translated by
// the web stream handler into Datastar SSE patches that carry the streamed
// text and a finalizing replace of the placeholder.
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
	h := New(q, auth.NewService(q), convos, models, sup, slog.Default())

	fx := seedSendable(t, q, fake.URL())
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "webtest"})

	// Launch the run with explicit provider/model (the conversation has no
	// default model in this seed; model selection in the composer is a
	// fan-out item).
	pid, mid := fx.providerID.String(), fx.modelID
	sendResp, err := convos.SendMessage(userCtx, connect.NewRequest(&reevev1.SendMessageRequest{
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
	if !strings.Contains(body, "datastar-patch-elements") {
		t.Errorf("stream SSE missing patch-elements events; body:\n%s", body)
	}
	if !strings.Contains(body, `id="stream-md"`) {
		t.Errorf("stream SSE missing #stream-md morph target; body:\n%s", body)
	}
	// The finalize step replaces #stream with a plain bubble (no streaming id).
	if !strings.Contains(body, `class="msg assistant"`) {
		t.Errorf("stream SSE missing finalized assistant bubble; body:\n%s", body)
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
	h := New(q, auth.NewService(q), convos, models, sup, slog.Default())

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
	for _, want := range []string{`id="composer"`, `id="messages"`, "<select", "Claude Fake", `name="model"`} {
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
