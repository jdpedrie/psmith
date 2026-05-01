package conversations

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
)

// Inserts a context manually with a given activation time and returns it.
func insertContext(t *testing.T, q *store.Queries, convID uuid.UUID, activation time.Time, parent *uuid.UUID) store.Context {
	t.Helper()
	id, _ := uuid.NewV7()
	row, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    id,
		ConversationID:        convID,
		ParentContextID:       parent,
		ContextActivationTime: activation,
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	return row
}

// Inserts a message and returns it.
func insertMessage(t *testing.T, q *store.Queries, contextID uuid.UUID, parent *uuid.UUID, role, content string) store.Message {
	t.Helper()
	id, _ := uuid.NewV7()
	row, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID: id, ContextID: contextID, ParentID: parent, Role: role, Content: content,
	})
	if err != nil {
		t.Fatalf("CreateMessage(%s): %v", role, err)
	}
	// Ensure created_at strictly orders by call sequence — Postgres NOW() has
	// microsecond resolution, but back-to-back inserts can land on the same
	// tick. Sleep a sliver between inserts in tests that care about ordering.
	time.Sleep(2 * time.Millisecond)
	return row
}

// --- SetCurrentLeaf ---

func TestSetCurrentLeaf_UpdatesCursor(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "set-leaf", nil, nil)
	f := seedSendable(t, q, driverType)

	// Add a second message so we can pick a non-default leaf.
	parent := f.systemMsgID
	other := insertMessage(t, q, f.contextID, &parent, "user", "hello")

	resp, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: other.ID.String(),
	}))
	if err != nil {
		t.Fatalf("SetCurrentLeaf: %v", err)
	}
	if resp.Msg.Context == nil || resp.Msg.Context.GetCurrentLeafMessageId() != other.ID.String() {
		t.Errorf("response cursor wrong: %+v", resp.Msg.Context)
	}
	// Sanity: re-read context from DB and confirm the column updated.
	row, _ := q.GetContextByID(context.Background(), f.contextID)
	if row.CurrentLeafMessageID == nil || *row.CurrentLeafMessageID != other.ID {
		t.Errorf("DB cursor not set: %+v", row.CurrentLeafMessageID)
	}
}

func TestSetCurrentLeaf_ClearsCursor(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "clear-leaf", nil, nil)
	f := seedSendable(t, q, driverType)

	// Pre-set the cursor so we can observe it being cleared.
	if _, err := q.UpdateContextCurrentLeaf(context.Background(), store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &f.systemMsgID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}

	resp, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: "",
	}))
	if err != nil {
		t.Fatalf("SetCurrentLeaf: %v", err)
	}
	if resp.Msg.Context.GetCurrentLeafMessageId() != "" {
		t.Errorf("expected cleared cursor, got %q", resp.Msg.Context.GetCurrentLeafMessageId())
	}
	row, _ := q.GetContextByID(context.Background(), f.contextID)
	if row.CurrentLeafMessageID != nil {
		t.Errorf("DB cursor not cleared: %+v", row.CurrentLeafMessageID)
	}
}

func TestSetCurrentLeaf_MessageInDifferentContext(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "leaf-cross-cx", nil, nil)
	f := seedSendable(t, q, driverType)

	// Insert a sibling context with one message; try to point f.context's cursor at that message.
	other := insertContext(t, q, f.conv.ID, time.Now().UTC().Add(-time.Hour), nil)
	stray := insertMessage(t, q, other.ID, nil, "user", "stray")

	_, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: stray.ID.String(),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSetCurrentLeaf_MessageNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "leaf-missing", nil, nil)
	f := seedSendable(t, q, driverType)

	missing := uuid.New().String()
	_, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: missing,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestSetCurrentLeaf_CrossUserContext(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "leaf-cross-user", nil, nil)
	f := seedSendable(t, q, driverType)

	bid, _ := uuid.NewV7()
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: bid, Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	_, err := svc.SetCurrentLeaf(ctxAsUser(bob), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: f.systemMsgID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- SendMessage parent resolution chain ---

func TestSendMessage_HonorsCurrentLeafCursor(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "honor-cursor",
		[]providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	// Build a forked tree: system -> A (older), system -> B (newer/latest).
	// Set the cursor to A — even though B was created later, the next user
	// message must parent off A, not B (cursor wins over fallback).
	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "assistant", "a-branch")
	b := insertMessage(t, q, f.contextID, &parent, "assistant", "b-branch")
	if _, err := q.UpdateContextCurrentLeaf(context.Background(), store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &a.ID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "next",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != a.ID.String() {
		t.Errorf("parent should be cursor (A), got %q (B=%q)", resp.Msg.UserMessage.GetParentId(), b.ID)
	}

	// And the cursor must have advanced to the new user message.
	row, _ := q.GetContextByID(context.Background(), f.contextID)
	if row.CurrentLeafMessageID == nil || row.CurrentLeafMessageID.String() != resp.Msg.UserMessage.Id {
		t.Errorf("cursor not advanced; got %+v want %s", row.CurrentLeafMessageID, resp.Msg.UserMessage.Id)
	}

	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("status %q want completed", final.Status)
	}
	// Cursor advances again to the assistant message after materialization.
	row, _ = q.GetContextByID(context.Background(), f.contextID)
	if row.CurrentLeafMessageID == nil || final.ResultMessageID == nil ||
		*row.CurrentLeafMessageID != *final.ResultMessageID {
		t.Errorf("cursor not advanced to assistant: cursor=%+v result=%+v",
			row.CurrentLeafMessageID, final.ResultMessageID)
	}
}

func TestSendMessage_FallbackWhenNoCursor(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "fallback",
		[]providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	// No cursor set; the only message is the system seed. Parent should fall
	// back to that system message via the latest-by-created_at rule.
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != f.systemMsgID.String() {
		t.Errorf("parent should be system msg, got %q", resp.Msg.UserMessage.GetParentId())
	}
}

func TestSendMessage_ExplicitParentBeatsCursor(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "explicit-parent",
		[]providers.Chunk{textChunk("ok"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "assistant", "a-branch")
	b := insertMessage(t, q, f.contextID, &parent, "assistant", "b-branch")
	// Cursor on A, but explicit request uses B. Explicit wins.
	if _, err := q.UpdateContextCurrentLeaf(context.Background(), store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &a.ID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	bID := b.ID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &bID,
		Content:         "fork to B",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != b.ID.String() {
		t.Errorf("parent should be explicit (B), got %q", resp.Msg.UserMessage.GetParentId())
	}
}

// --- SetCurrentLeaf input validation ---

func TestSetCurrentLeaf_InvalidContextID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "leaf-bad-cx", nil, nil)
	f := seedSendable(t, q, driverType)

	_, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: "not-a-uuid",
		MessageId: f.systemMsgID.String(),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestSetCurrentLeaf_InvalidMessageID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "leaf-bad-mid", nil, nil)
	f := seedSendable(t, q, driverType)

	_, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&reevev1.SetCurrentLeafRequest{
		ContextId: f.contextID.String(),
		MessageId: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ActivateContext preserves the cursor ---

func TestActivateContext_PreservesCurrentLeaf(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "activate-preserves", nil, nil)
	f := seedSendable(t, q, driverType)

	// Set the cursor, then "deactivate" by creating a newer-activation sibling
	// context, then re-activate the original — the cursor must survive.
	if _, err := q.UpdateContextCurrentLeaf(context.Background(), store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &f.systemMsgID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}
	_ = insertContext(t, q, f.conv.ID, time.Now().UTC().Add(time.Hour), nil)

	resp, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&reevev1.ActivateContextRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ActivateContext: %v", err)
	}
	if resp.Msg.Context.GetCurrentLeafMessageId() != f.systemMsgID.String() {
		t.Errorf("ActivateContext lost cursor: got %q want %q",
			resp.Msg.Context.GetCurrentLeafMessageId(), f.systemMsgID)
	}
}

// --- ListMessages sibling_count ---

func TestListMessages_SiblingCountPopulated(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "sibling-count", nil, nil)
	f := seedSendable(t, q, driverType)

	// Build:
	//   system
	//     ├── A (assistant)
	//     │     └── A1 (user)
	//     ├── B (assistant)         <-- sibling of A
	//     └── C (assistant)         <-- sibling of A
	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "assistant", "a")
	_ = insertMessage(t, q, f.contextID, &parent, "assistant", "b")
	_ = insertMessage(t, q, f.contextID, &parent, "assistant", "c")
	a1 := insertMessage(t, q, f.contextID, &a.ID, "user", "a1")

	leaf := a1.ID.String()
	resp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}

	// Returned root-first: system, A, A1.
	got := map[string]int32{}
	for _, m := range resp.Msg.Messages {
		got[m.Id] = m.SiblingCount
	}
	// system message: it's the only root (parent_id NULL) in the context, so 0 siblings.
	if got[f.systemMsgID.String()] != 0 {
		t.Errorf("system sibling_count: got %d want 0", got[f.systemMsgID.String()])
	}
	// A: B and C share its parent → 2 siblings.
	if got[a.ID.String()] != 2 {
		t.Errorf("A sibling_count: got %d want 2", got[a.ID.String()])
	}
	// A1: only child of A → 0 siblings.
	if got[a1.ID.String()] != 0 {
		t.Errorf("A1 sibling_count: got %d want 0", got[a1.ID.String()])
	}
}

// When no leaf_message_id is given, ListMessages resolves the natural leaf of
// the context tree and walks the ancestor chain from it, exactly as if the
// caller had passed that leaf explicitly. For a linear chain the result is
// root-first with sibling_count = 0 on every row.
func TestListMessages_NoLeafWalksAncestorChain(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "no-leaf-chain", nil, nil)
	f := seedSendable(t, q, driverType)

	// Build a linear chain: system → a → b → c (no branches).
	a := insertMessage(t, q, f.contextID, &f.systemMsgID, "assistant", "a")
	b := insertMessage(t, q, f.contextID, &a.ID, "user", "b")
	c := insertMessage(t, q, f.contextID, &b.ID, "assistant", "c")

	// No leaf supplied — service must find "c" as the natural leaf and return
	// the full chain root-first.
	resp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	want := []string{f.systemMsgID.String(), a.ID.String(), b.ID.String(), c.ID.String()}
	if len(resp.Msg.Messages) != len(want) {
		t.Fatalf("expected %d messages, got %d", len(want), len(resp.Msg.Messages))
	}
	for i, m := range resp.Msg.Messages {
		if m.Id != want[i] {
			t.Errorf("messages[%d]: got id %s, want %s", i, m.Id, want[i])
		}
		if m.SiblingCount != 0 {
			t.Errorf("messages[%d] sibling_count = %d, want 0 (linear chain)", i, m.SiblingCount)
		}
	}
}

// --- ON DELETE SET NULL behavior ---

func TestCurrentLeaf_NulledOnReferencedMessageDelete(t *testing.T) {
	t.Parallel()
	_, q, _, pool := newFullSvcWithPool(t)
	driverType := registerFakeDriver(t, "leaf-on-delete", nil, nil)
	f := seedSendable(t, q, driverType)

	// Insert a child of system so we can delete it without nuking the seed.
	parent := f.systemMsgID
	target := insertMessage(t, q, f.contextID, &parent, "assistant", "to-be-deleted")

	// Point the cursor at the soon-to-be-deleted message.
	if _, err := q.UpdateContextCurrentLeaf(context.Background(), store.UpdateContextCurrentLeafParams{
		ID:                   f.contextID,
		CurrentLeafMessageID: &target.ID,
	}); err != nil {
		t.Fatalf("UpdateContextCurrentLeaf: %v", err)
	}

	// Direct DELETE — the store layer doesn't expose DeleteMessage and we
	// don't want to add a production query just to exercise the constraint.
	if _, err := pool.Exec(context.Background(), "DELETE FROM messages WHERE id = $1", target.ID); err != nil {
		t.Fatalf("DELETE: %v", err)
	}
	row, err := q.GetContextByID(context.Background(), f.contextID)
	if err != nil {
		t.Fatalf("GetContextByID: %v", err)
	}
	if row.CurrentLeafMessageID != nil {
		t.Errorf("ON DELETE SET NULL didn't clear cursor: %+v", row.CurrentLeafMessageID)
	}
}

// --- Compression invariants ---

// Compact end-to-end (post two-stage reshape): drive the supervisor through
// a compression run and confirm:
//   - result_message_id points at a compression_summary in the source context
//   - result_context_id is NULL (no new context until promote)
//   - the source context now contains a compression_summary row
//   - SendMessage on that context is REJECTED until the summary is dealt with
func TestCompact_StageOnlyMaterializesSummary(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "compact-stage-only",
		[]providers.Chunk{textChunk("compressed summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

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

	// Add a user turn so the transcript isn't empty.
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "tell me a story")

	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&reevev1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("compaction status %q want completed; err=%s", final.Status, string(final.ErrorPayload))
	}
	if final.ResultMessageID == nil {
		t.Fatal("expected result_message_id (compression_summary)")
	}
	if final.ResultContextID != nil {
		t.Errorf("result_context_id should be NULL until promote; got %s", *final.ResultContextID)
	}

	summary, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID(summary): %v", err)
	}
	if summary.Role != "compression_summary" {
		t.Errorf("summary role=%q want compression_summary", summary.Role)
	}
	if summary.ContextID != f.contextID {
		t.Errorf("summary should live in the SOURCE context (%s); got %s", f.contextID, summary.ContextID)
	}

	// SendMessage on the source context should now be rejected until the
	// summary is promoted or deleted.
	pid := f.provider.ID.String()
	mid := f.modelID
	_, err = svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "next",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// Compression creates a new Context with current_leaf_message_id = null.
// Architecturally specified — the seeded role=context message in the new
// context isn't a turn the user is "viewing from," so the cursor stays clear
// until the first SendMessage advances it. Queries-level verification that
// CreateContext defaults the column to null even when callers don't pass it.
func TestCreateContext_DefaultsCurrentLeafNull(t *testing.T) {
	t.Parallel()
	_, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "ctx-default-leaf", nil, nil)
	f := seedSendable(t, q, driverType)

	// Mimic what materializeCompression does: CreateContext without passing
	// current_leaf, then CreateMessage with role=context.
	cxid, _ := uuid.NewV7()
	parent := f.contextID
	newCx, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    cxid,
		ConversationID:        f.conv.ID,
		ParentContextID:       &parent,
		ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	if newCx.CurrentLeafMessageID != nil {
		t.Errorf("new context should default to null cursor; got %+v", newCx.CurrentLeafMessageID)
	}

	// And inserting a role=context message inside doesn't auto-set the cursor.
	_ = insertMessage(t, q, newCx.ID, nil, "context", "summary")
	row, err := q.GetContextByID(context.Background(), newCx.ID)
	if err != nil {
		t.Fatalf("GetContextByID: %v", err)
	}
	if row.CurrentLeafMessageID != nil {
		t.Errorf("inserting role=context shouldn't advance cursor; got %+v", row.CurrentLeafMessageID)
	}
}
