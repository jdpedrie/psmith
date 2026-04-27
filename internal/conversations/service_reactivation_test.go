package conversations

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/fakellm"
	"github.com/jdpedrie/clark/internal/store"
)

// TestReactivation_SendLandsInReactivatedContext — create a new sibling
// context (newer activation), then ActivateContext the original. The next
// SendMessage's user message must land in the reactivated (original)
// context, not the previously-active sibling.
func TestReactivation_SendLandsInReactivatedContext(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	originalCx := f.contextID

	// Create a "newer" sibling context (it's now the active one).
	newer, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID: uuid.New(), ConversationID: f.conv.ID,
		// Just-now activation — reactivation must beat it. Sleep first
		// so created_at and activation_time order deterministically vs
		// the seed-time original context.
		ContextActivationTime: func() time.Time { time.Sleep(5 * time.Millisecond); return time.Now().UTC() }(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	// Sanity: newer is the active one before we reactivate.
	active, _ := q.GetActiveContextByConversation(context.Background(), f.conv.ID)
	if active.ID != newer.ID {
		t.Fatalf("setup: active=%s want newer=%s", active.ID, newer.ID)
	}

	// Reactivate the original.
	if _, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.ActivateContextRequest{
		ContextId: originalCx.String(),
	})); err != nil {
		t.Fatalf("ActivateContext: %v", err)
	}

	// Now send — it should land in originalCx, not newer.
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&clarkv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "after reactivation",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.ContextId != originalCx.String() {
		t.Errorf("user msg landed in context=%s want %s (original)",
			resp.Msg.UserMessage.ContextId, originalCx)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	asst, _ := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if asst.ContextID != originalCx {
		t.Errorf("assistant landed in context=%s want %s", asst.ContextID, originalCx)
	}
}

// TestReactivation_PreservesCursor — set the cursor on the original context,
// then deactivate it (by creating a newer sibling), then reactivate. Cursor
// must survive — that's the "land back where you left off" promise.
//
// (This was also covered by service_branch_test.go; this one additionally
// confirms the next SendMessage *uses* the preserved cursor as the parent.)
func TestReactivation_PreservedCursorDrivesNextSend(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "after-reactivate"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	// One real turn so the cursor lands on a real assistant message.
	_, a1 := runOneTurn(t, svc, sup, q, f, "msg-1")

	// Make a sibling "newer" context to push f.contextID out of active.
	_, _ = q.CreateContext(context.Background(), store.CreateContextParams{
		ID: uuid.New(), ConversationID: f.conv.ID,
		// Just-now activation — reactivation must beat it. Sleep first
		// so created_at and activation_time order deterministically vs
		// the seed-time original context.
		ContextActivationTime: func() time.Time { time.Sleep(5 * time.Millisecond); return time.Now().UTC() }(),
	})

	// Reactivate.
	if _, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.ActivateContextRequest{
		ContextId: f.contextID.String(),
	})); err != nil {
		t.Fatalf("ActivateContext: %v", err)
	}

	// Cursor must be preserved.
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.CurrentLeafMessageID == nil || *cx.CurrentLeafMessageID != a1.ID {
		t.Fatalf("cursor=%+v want %s", cx.CurrentLeafMessageID, a1.ID)
	}

	// Send — parent should be a1 (the preserved cursor target).
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&clarkv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "follow-up",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != a1.ID.String() {
		t.Errorf("user.parent=%q want %q (cursor)", resp.Msg.UserMessage.GetParentId(), a1.ID)
	}
}

// TestReactivation_Idempotent — Activating the already-active context should
// succeed and update the activation_time (no-op semantically beyond
// refreshing the timestamp).
func TestReactivation_Idempotent(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "reactivate-noop", nil, nil)
	f := seedSendable(t, q, driverType)

	before, _ := q.GetContextByID(context.Background(), f.contextID)

	// Sleep so the activation_time can move forward (NOW() resolution).
	time.Sleep(5 * time.Millisecond)
	resp, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.ActivateContextRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ActivateContext: %v", err)
	}
	if !resp.Msg.Context.ActivationTime.AsTime().After(before.ContextActivationTime) {
		t.Errorf("activation_time did not advance: before=%v after=%v",
			before.ContextActivationTime, resp.Msg.Context.ActivationTime.AsTime())
	}
}

// TestReactivation_CrossUser — a different user attempting to reactivate
// returns NotFound (no leak of context existence).
func TestReactivation_CrossUser(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "reactivate-cross", nil, nil)
	f := seedSendable(t, q, driverType)

	bid, _ := uuid.NewV7()
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: bid, Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	_, err := svc.ActivateContext(ctxAsUser(bob), connect.NewRequest(&clarkv1.ActivateContextRequest{
		ContextId: f.contextID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// TestReactivation_AcrossCompression — drive Compact + Promote through the
// service, then reactivate the source context. Since the source context now
// retains its compression_summary row (audit), SendMessage on the
// reactivated source should be REJECTED (precondition: no pending summary).
// Deleting the summary unblocks it, after which a turn lands cleanly.
func TestReactivation_AcrossCompression(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// One turn before compaction, then the compression call, then one turn
	// after the user resumes the source.
	for _, txt := range []string{"a-pre", "summary", "a-post"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	contextA := f.contextID

	// One turn so the transcript isn't empty.
	_, _ = runOneTurn(t, svc, sup, q, f, "msg-pre")

	// Wire compression knobs onto the profile.
	guide := "Summarize."
	mode := "REPLACE"
	bg := context.Background()
	if err := q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionGuide: %v", err)
	}
	if err := q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionMode: %v", err)
	}
	if err := q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionProviderID: %v", err)
	}
	if err := q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	}); err != nil {
		t.Fatalf("UpdateProfileCompressionModelID: %v", err)
	}

	// Compact: writes a summary in A; doesn't create a new context.
	cresp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&clarkv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	cRunID, _ := uuid.Parse(cresp.Msg.StreamRun.Id)
	cFinal := waitForTerminal(t, sup, cRunID)
	if cFinal.Status != "completed" {
		t.Fatalf("compact status=%q", cFinal.Status)
	}
	if cFinal.ResultMessageID == nil {
		t.Fatal("compact: no result_message_id")
	}
	if cFinal.ResultContextID != nil {
		t.Fatalf("compact: result_context_id should be NULL until promote; got %s", *cFinal.ResultContextID)
	}
	summaryID := *cFinal.ResultMessageID

	// Promote: creates Context B as child of A, activates B.
	pResp, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.PromoteCompactionToNewContextRequest{
		MessageId: summaryID.String(),
	}))
	if err != nil {
		t.Fatalf("Promote: %v", err)
	}
	contextB, _ := uuid.Parse(pResp.Msg.Context.Id)

	// Sanity: B is now active.
	active, _ := q.GetActiveContextByConversation(bg, f.conv.ID)
	if active.ID != contextB {
		t.Fatalf("post-promote active=%s want B=%s", active.ID, contextB)
	}

	// Reactivate A. The summary row is still there, so the next SendMessage
	// on A is rejected with FailedPrecondition.
	if _, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&clarkv1.ActivateContextRequest{
		ContextId: contextA.String(),
	})); err != nil {
		t.Fatalf("ActivateContext A: %v", err)
	}
	pid := f.provider.ID.String()
	mid := f.modelID
	_, err = svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&clarkv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "back in A (blocked)",
		ProviderId:     &pid, ModelId: &mid,
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)

	// Delete the summary to clear the gate. Use cascade=true since some
	// children of the (compaction-time) parent may also need to go; here
	// the summary is a leaf so this is just a single delete.
	if _, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&clarkv1.DeleteMessageRequest{
		Id: summaryID.String(),
	})); err != nil {
		t.Fatalf("DeleteMessage(summary): %v", err)
	}

	// Now SendMessage on A succeeds.
	sresp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&clarkv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "back in A",
		ProviderId:     &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage post-delete-summary: %v", err)
	}
	if sresp.Msg.UserMessage.ContextId != contextA.String() {
		t.Errorf("post-reactivation user msg landed in context=%s want A=%s",
			sresp.Msg.UserMessage.ContextId, contextA)
	}
	srunID, _ := uuid.Parse(sresp.Msg.StreamRun.Id)
	sfinal := waitForTerminal(t, sup, srunID)
	if sfinal.Status != "completed" {
		t.Fatalf("send status=%q err=%s", sfinal.Status, string(sfinal.ErrorPayload))
	}

	// And B is intact, just no longer active.
	bRow, err := q.GetContextByID(bg, contextB)
	if err != nil {
		t.Fatalf("GetContextByID(B): %v", err)
	}
	if bRow.ParentContextID == nil || *bRow.ParentContextID != contextA {
		t.Errorf("B.parent_context_id=%+v want A=%s", bRow.ParentContextID, contextA)
	}
}
