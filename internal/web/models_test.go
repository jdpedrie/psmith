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
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/conversations"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/modelproviders"
	_ "github.com/jdpedrie/psmith/internal/providers/anthropic"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
)

func TestAbbrevTokens(t *testing.T) {
	t.Parallel()
	cases := map[int32]string{500: "500", 1000: "1K", 200000: "200K", 1000000: "1M", 1500000: "1.5M"}
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

	// Render the picker (htmx overlay).
	req := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/model", nil).WithContext(userCtx)
	req.Header.Set("HX-Request", "true")
	req.SetPathValue("id", fx.convID.String())
	rec := do(h.handleModelPicker, req)
	body := rec.Body.String()
	if rec.Code != 200 {
		t.Fatalf("status=%d; body:\n%s", rec.Code, body)
	}
	for _, want := range []string{"Claude Fake", "modal-backdrop", "model-row", "/c/" + fx.convID.String() + "/model"} {
		if !strings.Contains(body, want) {
			t.Errorf("picker missing %q", want)
		}
	}

	// Select the model.
	value := modelValue(fx.providerID.String(), fx.modelID)
	form := url.Values{"model": {value}}
	postReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/model", strings.NewReader(form.Encode())).WithContext(userCtx)
	postReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	postReq.Header.Set("HX-Request", "true")
	postReq.SetPathValue("id", fx.convID.String())
	postRec := do(h.handleSetModel, postReq)
	if postRec.Code != 200 {
		t.Fatalf("set model status=%d", postRec.Code)
	}
	if out := postRec.Body.String(); !strings.Contains(out, "composer-model-chip") || !strings.Contains(out, `id="modal"`) {
		t.Errorf("set-model response missing chip/oob-close; body:\n%s", out)
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
}
