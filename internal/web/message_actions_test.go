package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/testutil"
)

func newConvosHandler(t *testing.T) (*Handler, *conversations.Service, *store.Queries) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})
	return h, convos, q
}

func activeContextID(t *testing.T, convos *conversations.Service, ctx context.Context, convID string) uuid.UUID {
	t.Helper()
	resp, err := convos.GetConversation(ctx, connect.NewRequest(&reevev1.GetConversationRequest{Id: convID}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	id, _ := uuid.Parse(resp.Msg.GetActiveContext().GetId())
	return id
}

func TestEditMessage(t *testing.T) {
	t.Parallel()
	h, convos, q := newConvosHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	ctxID := activeContextID(t, convos, userCtx, fx.convID.String())
	mid, _ := uuid.NewV7()
	if _, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID: mid, ContextID: ctxID, Role: "user", Content: "original",
	}); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}

	form := url.Values{"content": {"edited text"}}
	req := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/message/"+mid.String()+"/edit", strings.NewReader(form.Encode())).WithContext(userCtx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetPathValue("id", fx.convID.String())
	req.SetPathValue("mid", mid.String())
	if rec := do(h.handleEditSave, req); rec.Code != http.StatusSeeOther {
		t.Fatalf("edit status=%d; body:\n%s", rec.Code, rec.Body.String())
	}

	got, err := convos.GetMessage(userCtx, connect.NewRequest(&reevev1.GetMessageRequest{Id: mid.String()}))
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if got.Msg.GetMessage().GetContent() != "edited text" {
		t.Errorf("content = %q want %q", got.Msg.GetMessage().GetContent(), "edited text")
	}
}

func TestRegenerate(t *testing.T) {
	t.Parallel()
	h, convos, q := newConvosHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	// Give the conversation a default model so regenerate (no per-turn model)
	// can resolve one.
	pid, mid := fx.providerID.String(), fx.modelID
	if _, err := convos.UpdateConversation(userCtx, connect.NewRequest(&reevev1.UpdateConversationRequest{
		Id:       fx.convID.String(),
		Settings: &reevev1.ConversationSettings{DefaultProviderId: &pid, DefaultModelId: &mid},
	})); err != nil {
		t.Fatalf("UpdateConversation: %v", err)
	}

	ctxID := activeContextID(t, convos, userCtx, fx.convID.String())
	userMsgID, _ := uuid.NewV7()
	if _, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID: userMsgID, ContextID: ctxID, Role: "user", Content: "hi",
	}); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}

	form := url.Values{"parent_message_id": {userMsgID.String()}}
	req := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/regenerate", strings.NewReader(form.Encode())).WithContext(userCtx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetPathValue("id", fx.convID.String())
	rec := do(h.handleRegenerate, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("regenerate status=%d; body:\n%s", rec.Code, rec.Body.String())
	}
	if loc := rec.Header().Get("Location"); !strings.HasPrefix(loc, "/c/"+fx.convID.String()+"?run=") {
		t.Errorf("regenerate redirect=%q want /c/<id>?run=<id>", loc)
	}
}
