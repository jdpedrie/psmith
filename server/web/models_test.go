package web

import (
	"context"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/conversations"
	"github.com/jdpedrie/psmith/server/crypto"
	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/modelproviders"
	_ "github.com/jdpedrie/psmith/server/providers/anthropic"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/stream"
	"github.com/jdpedrie/psmith/server/testutil"
)

func TestAbbrevTokens(t *testing.T) {
	t.Parallel()
	cases := map[int32]string{500: "500", 1000: "1k", 200000: "200k", 1000000: "1M", 1500000: "1.5M"}
	for in, want := range cases {
		if got := abbrevTokens(in); got != want {
			t.Errorf("abbrevTokens(%d) = %q want %q", in, got, want)
		}
	}
}

func TestCostBucket(t *testing.T) {
	t.Parallel()
	bk := func(out float64) string {
		b, _ := costBucket(&psmithv1.ModelPricing{OutputPerMillionTokens: &out})
		return b
	}
	for out, want := range map[float64]string{1: "$", 5: "$$", 15: "$$$", 75: "$$$$"} {
		if got := bk(out); got != want {
			t.Errorf("costBucket(out=%v) = %q want %q", out, got, want)
		}
	}
	if b, _ := costBucket(&psmithv1.ModelPricing{}); b != "" {
		t.Errorf("costBucket(empty) = %q want empty", b)
	}
}

func newModelHandler(t *testing.T) (*Handler, *store.Queries, *conversations.Service) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Models: models, Supervisor: sup, Logger: slog.Default()})
	return h, q, convos
}

// TestModelPicker_RendersGroupedAndSelects proves the rich picker lists the
// enabled model grouped under its provider and that selecting it persists the
// conversation default.
func TestModelPicker_RendersGroupedAndSelects(t *testing.T) {
	t.Parallel()
	h, q, convos := newModelHandler(t)
	fx := seedSendable(t, q, "http://unused")
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	// The picker opens in the inspector.
	req := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/model", nil).WithContext(userCtx)
	req.SetPathValue("id", fx.convID.String())
	rec := do(h.handleModelPicker, req)
	body := rec.Body.String()
	if rec.Code != 200 {
		t.Fatalf("status=%d; body:\n%s", rec.Code, body)
	}
	for _, want := range []string{"Claude Fake", "pick-body", "pick-row", "Use the profile's model", `action="/c/` + fx.convID.String() + `/model"`} {
		if !strings.Contains(body, want) {
			t.Errorf("picker missing %q", want)
		}
	}

	// Select the model.
	value := modelValue(fx.providerID.String(), fx.modelID)
	form := url.Values{"model": {value}}
	postReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/model", strings.NewReader(form.Encode())).WithContext(userCtx)
	postReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	postReq.SetPathValue("id", fx.convID.String())
	postRec := do(h.handleSetModel, postReq)
	if postRec.Code != 303 {
		t.Fatalf("set model status=%d", postRec.Code)
	}

	// The conversation now stores that default.
	got, err := convos.GetConversation(userCtx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: fx.convID.String()}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	s := got.Msg.GetConversation().GetSettings()
	if s.GetDefaultProviderId() != fx.providerID.String() || s.GetDefaultModelId() != fx.modelID {
		t.Errorf("default model = %s|%s want %s|%s", s.GetDefaultProviderId(), s.GetDefaultModelId(), fx.providerID, fx.modelID)
	}

	// An empty pick goes back to the profile's model.
	clearReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/model", strings.NewReader("model=")).WithContext(userCtx)
	clearReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	clearReq.SetPathValue("id", fx.convID.String())
	if rec := do(h.handleSetModel, clearReq); rec.Code != 303 {
		t.Fatalf("clear model status=%d", rec.Code)
	}
	got, _ = convos.GetConversation(userCtx, connect.NewRequest(&psmithv1.GetConversationRequest{Id: fx.convID.String()}))
	if m := currentSettingsModel(got.Msg.GetConversation()); m != "" {
		t.Errorf("model after clearing = %q, want none", m)
	}
}
