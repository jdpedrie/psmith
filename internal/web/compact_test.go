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
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/conversations"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	_ "github.com/jdpedrie/psmith/internal/providers/anthropic" // register driver
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/stream"
	"github.com/jdpedrie/psmith/internal/testutil"
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
	cresp, err := convos.Compact(userCtx, connect.NewRequest(&psmithv1.CompactRequest{
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
	ctxs, err := convos.ListContexts(userCtx, connect.NewRequest(&psmithv1.ListContextsRequest{ConversationId: fx.convID.String()}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	if n := len(ctxs.Msg.GetContexts()); n != 2 {
		t.Errorf("contexts=%d want 2 after promote", n)
	}
}

// TestPendingCompression_GatesComposer — while a clean summary awaits
// review, the conversation page swaps the composer for the review bar
// (Delete / Confirm); deleting the summary through the new message-
// delete route restores the composer.
func TestPendingCompression_GatesComposer(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Pending summary."}},
		Usage:  &fakellm.Usage{InputTokens: 20, OutputTokens: 4},
	})

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Supervisor: sup, Logger: slog.Default()})

	fx := seedSendable(t, q, fake.URL())
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: fx.userID, Username: "u"})

	pid, mid, guide := fx.providerID.String(), fx.modelID, "Summarize."
	cresp, err := convos.Compact(userCtx, connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId:        fx.convID.String(),
		CompressionProviderId: &pid,
		CompressionModelId:    &mid,
		CompressionGuide:      &guide,
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	// Wait for the run to materialize the summary.
	runID := cresp.Msg.GetStreamRun().GetId()
	deadline := time.Now().Add(10 * time.Second)
	for {
		rid, perr := uuid.Parse(runID)
		if perr != nil {
			t.Fatalf("parse run id: %v", perr)
		}
		row, err := sup.Get(userCtx, rid)
		if err == nil && row.Status != "running" && row.Status != "pending" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("compaction run never finished")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Conversation page: review bar in, composer out.
	pageReq := httptest.NewRequest("GET", "/c/"+fx.convID.String(), nil).WithContext(userCtx)
	pageReq.SetPathValue("id", fx.convID.String())
	pageRec := do(h.handleConversation, pageReq)
	body := pageRec.Body.String()
	if !strings.Contains(body, "Compression awaiting review") {
		t.Fatalf("pending page missing review bar; body:\n%s", body)
	}
	if strings.Contains(body, `id="composer"`) {
		t.Fatal("pending page still renders the composer")
	}
	m := regexp.MustCompile(`/message/([^/]+)/delete`).FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no delete action in review bar; body:\n%s", body)
	}
	summaryMsgID := m[1]

	// Delete the summary via the new route; the composer returns.
	delReq := httptest.NewRequest("POST", "/c/"+fx.convID.String()+"/message/"+summaryMsgID+"/delete", nil).WithContext(userCtx)
	delReq.SetPathValue("id", fx.convID.String())
	delReq.SetPathValue("mid", summaryMsgID)
	delRec := do(h.handleMessageDelete, delReq)
	if delRec.Code != http.StatusSeeOther {
		t.Fatalf("delete status=%d; body:\n%s", delRec.Code, delRec.Body.String())
	}

	pageReq2 := httptest.NewRequest("GET", "/c/"+fx.convID.String(), nil).WithContext(userCtx)
	pageReq2.SetPathValue("id", fx.convID.String())
	pageRec2 := do(h.handleConversation, pageReq2)
	body2 := pageRec2.Body.String()
	if strings.Contains(body2, "Compression awaiting review") {
		t.Fatal("review bar still present after deleting the summary")
	}
	if !strings.Contains(body2, `id="composer"`) {
		t.Fatal("composer missing after deleting the summary")
	}
}
