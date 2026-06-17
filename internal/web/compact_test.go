package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/jdpedrie/spalt/fakellm"
	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/conversations"
	"github.com/jdpedrie/spalt/internal/crypto"
	"github.com/jdpedrie/spalt/internal/modelmeta"
	_ "github.com/jdpedrie/spalt/internal/providers/anthropic" // register driver
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/stream"
	"github.com/jdpedrie/spalt/internal/testutil"
)

// TestCompactFlow_E2E proves the two-stage compaction: a real compression run
// streams a summary, the stream handler swaps in a promote form, and promoting
// rolls the summary into a fresh active context.
func TestCompactFlow_E2E(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Summary of the chat so far."}},
		Usage:  &fakellm.Usage{InputTokens: 20, OutputTokens: 6},
	})

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, fake.URL())
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	// Start a compaction run with explicit compression model (the seed profile
	// has none); this is the override path Compact supports.
	pid, mid, guide := fx.providerID.String(), fx.modelID, "Summarize."
	cresp, err := convos.Compact(userCtx, connect.NewRequest(&spaltv1.CompactRequest{
		ConversationId:        fx.convID.String(),
		CompressionProviderId: &pid,
		CompressionModelId:    &mid,
		CompressionGuide:      &guide,
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID := cresp.Msg.GetStreamRun().GetId()

	// Drive the compaction stream handler.
	ctx, cancel := context.WithTimeout(userCtx, 10*time.Second)
	defer cancel()
	streamReq := httptest.NewRequest("GET", "/c/"+fx.convID.String()+"/compact/stream?run="+runID, nil).WithContext(ctx)
	streamReq.SetPathValue("id", fx.convID.String())
	streamRec := do(h.handleCompactStream, streamReq)

	body := streamRec.Body.String()
	if !strings.Contains(body, "Summary of the chat so far.") {
		t.Fatalf("compaction stream missing summary text; body:\n%s", body)
	}
	if !strings.Contains(body, "/c/"+fx.convID.String()+"/promote") {
		t.Fatalf("compaction stream missing promote form; body:\n%s", body)
	}
	m := regexp.MustCompile(`name="message_id" value="([^"]+)"`).FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no message_id in promote form; body:\n%s", body)
	}
	summaryMsgID := m[1]

	// Promote rolls into a new context.
	form := url.Values{"message_id": {summaryMsgID}}
	promReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/promote", strings.NewReader(form.Encode())).WithContext(userCtx)
	promReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	promReq.SetPathValue("id", fx.convID.String())
	promRec := do(h.handleCompactPromote, promReq)
	if promRec.Code != http.StatusSeeOther {
		t.Fatalf("promote status=%d; body:\n%s", promRec.Code, promRec.Body.String())
	}

	// There should now be two contexts (original + promoted).
	ctxs, err := convos.ListContexts(userCtx, connect.NewRequest(&spaltv1.ListContextsRequest{ConversationId: fx.convID.String()}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	if n := len(ctxs.Msg.GetContexts()); n != 2 {
		t.Errorf("contexts=%d want 2 after promote", n)
	}
}
