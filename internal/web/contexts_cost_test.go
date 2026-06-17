package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/conversations"
	"github.com/jdpedrie/spalt/internal/crypto"
	"github.com/jdpedrie/spalt/internal/modelmeta"
	"github.com/jdpedrie/spalt/internal/modelproviders"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/stream"
	"github.com/jdpedrie/spalt/internal/testutil"
)

func TestCostPage(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Models: models, Logger: slog.Default()})

	userCtx, _ := seedUserCtx(t, q)
	rec := do(h.handleCost, httptest.NewRequest("GET", "/settings/cost", nil).WithContext(userCtx))
	if rec.Code != http.StatusOK {
		t.Fatalf("cost status=%d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Cost") || !strings.Contains(body, "$0.0000") {
		t.Errorf("cost page missing expected content; body:\n%s", body)
	}
}

func TestContextsView(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	// Contexts list shows the active context.
	listReq := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/contexts", nil).WithContext(userCtx)
	listReq.SetPathValue("id", fx.convID.String())
	listRec := do(h.handleContexts, listReq)
	if listRec.Code != http.StatusOK || !strings.Contains(listRec.Body.String(), "active") {
		t.Fatalf("contexts list bad; code=%d body:\n%s", listRec.Code, listRec.Body.String())
	}

	// Look up the active context id and render its read-only view.
	getResp, err := convos.GetConversation(userCtx, connect.NewRequest(&spaltv1.GetConversationRequest{Id: fx.convID.String()}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	cid := getResp.Msg.GetActiveContext().GetId()
	viewReq := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/context/"+cid, nil).WithContext(userCtx)
	viewReq.SetPathValue("id", fx.convID.String())
	viewReq.SetPathValue("cid", cid)
	viewRec := do(h.handleContextView, viewReq)
	if viewRec.Code != http.StatusOK || !strings.Contains(viewRec.Body.String(), "Contexts") {
		t.Errorf("context view bad; code=%d", viewRec.Code)
	}
}
