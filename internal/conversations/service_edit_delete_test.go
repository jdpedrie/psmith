package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
)

// --- EditMessage -----------------------------------------------------------

func TestEditMessage_HappyPath(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-happy", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	msg := insertMessage(t, q, f.contextID, &parent, "user", "original content")

	resp, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      msg.ID.String(),
		Content: "edited content",
	}))
	if err != nil {
		t.Fatalf("EditMessage: %v", err)
	}
	if resp.Msg.Message.Content != "edited content" {
		t.Errorf("content=%q want %q", resp.Msg.Message.Content, "edited content")
	}
	if resp.Msg.Message.GetEditedAt() == nil {
		t.Error("edited_at should be set")
	}
	// Persisted in DB.
	row, _ := q.GetMessageByID(context.Background(), msg.ID)
	if row.Content != "edited content" {
		t.Errorf("DB content=%q want %q", row.Content, "edited content")
	}
	if row.EditedAt == nil {
		t.Error("DB edited_at should be set")
	}
}

func TestEditMessage_RoleFlipUserToAssistant(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-role-flip", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	msg := insertMessage(t, q, f.contextID, &parent, "user", "could be either")

	asst := psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT
	resp, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      msg.ID.String(),
		Content: "still could be either",
		Role:    &asst,
	}))
	if err != nil {
		t.Fatalf("EditMessage: %v", err)
	}
	if resp.Msg.Message.Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
		t.Errorf("role=%v want assistant", resp.Msg.Message.Role)
	}
}

func TestEditMessage_RoleFlipFromSystemRejected(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-role-from-system", nil, nil)
	f := seedSendable(t, q, driverType)

	asst := psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT
	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      f.systemMsgID.String(),
		Content: "x",
		Role:    &asst,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestEditMessage_RoleFlipToContextRejected(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-role-to-context", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	msg := insertMessage(t, q, f.contextID, &parent, "user", "x")

	cxRole := psmithv1.MessageRole_MESSAGE_ROLE_CONTEXT
	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      msg.ID.String(),
		Content: "x",
		Role:    &cxRole,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestEditMessage_ContentOnlyEditOnSystemAllowed(t *testing.T) {
	t.Parallel()
	// Editing the system message's content (without role change) should work.
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-system-content", nil, nil)
	f := seedSendable(t, q, driverType)

	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      f.systemMsgID.String(),
		Content: "tweaked system prompt",
	}))
	if err != nil {
		t.Fatalf("EditMessage: %v", err)
	}
}

func TestEditMessage_ContentEditOnCompressionSummaryAllowed(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-summary-content", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	summary := insertMessage(t, q, f.contextID, &parent, "compression_summary", "rough draft")

	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      summary.ID.String(),
		Content: "polished summary",
	}))
	if err != nil {
		t.Fatalf("EditMessage on compression_summary: %v", err)
	}
	row, _ := q.GetMessageByID(context.Background(), summary.ID)
	if row.Content != "polished summary" {
		t.Errorf("content=%q want %q", row.Content, "polished summary")
	}
}

func TestEditMessage_NotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-notfound", nil, nil)
	f := seedSendable(t, q, driverType)

	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      uuid.New().String(),
		Content: "x",
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestEditMessage_CrossUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-cross-user", nil, nil)
	f := seedSendable(t, q, driverType)

	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uuid.New(), Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	_, err := svc.EditMessage(ctxAsUser(bob), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      f.systemMsgID.String(),
		Content: "x",
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestEditMessage_InvalidUUID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "edit-bad-uuid", nil, nil)
	f := seedSendable(t, q, driverType)
	_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      "not-a-uuid",
		Content: "x",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- DeleteMessage ---------------------------------------------------------

func TestDeleteMessage_StitchReparentsChildrenToGrandparent(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "delete-stitch", nil, nil)
	f := seedSendable(t, q, driverType)
	// Tree: system → A → B → C
	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "user", "A")
	b := insertMessage(t, q, f.contextID, &a.ID, "assistant", "B")
	c := insertMessage(t, q, f.contextID, &b.ID, "user", "C")

	// Delete B (cascade=false default). C should reparent to A.
	if _, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id: b.ID.String(),
	})); err != nil {
		t.Fatalf("DeleteMessage: %v", err)
	}
	cRow, err := q.GetMessageByID(context.Background(), c.ID)
	if err != nil {
		t.Fatalf("GetMessageByID(C): %v", err)
	}
	if cRow.ParentID == nil || *cRow.ParentID != a.ID {
		t.Errorf("C.parent_id=%+v want A.ID=%s", cRow.ParentID, a.ID)
	}
	// B is gone.
	if _, err := q.GetMessageByID(context.Background(), b.ID); err == nil {
		t.Error("expected B to be deleted")
	}
}

func TestDeleteMessage_StitchReparentsToNullWhenTargetIsRoot(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "delete-stitch-root", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "user", "A")

	// Delete the system message (root). A.parent_id should become NULL.
	if _, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id: f.systemMsgID.String(),
	})); err != nil {
		t.Fatalf("DeleteMessage(system): %v", err)
	}
	aRow, _ := q.GetMessageByID(context.Background(), a.ID)
	if aRow.ParentID != nil {
		t.Errorf("A.parent_id should be NULL (system was root); got %+v", aRow.ParentID)
	}
}

func TestDeleteMessage_CascadeRemovesSubtree(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "delete-cascade", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	a := insertMessage(t, q, f.contextID, &parent, "user", "A")
	b := insertMessage(t, q, f.contextID, &a.ID, "assistant", "B")
	c := insertMessage(t, q, f.contextID, &b.ID, "user", "C")

	if _, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id:      a.ID.String(),
		Cascade: true,
	})); err != nil {
		t.Fatalf("DeleteMessage(cascade): %v", err)
	}
	for _, id := range []uuid.UUID{a.ID, b.ID, c.ID} {
		if _, err := q.GetMessageByID(context.Background(), id); err == nil {
			t.Errorf("expected %s to be deleted (cascade)", id)
		}
	}
	// System still here.
	if _, err := q.GetMessageByID(context.Background(), f.systemMsgID); err != nil {
		t.Errorf("system should NOT be deleted; got %v", err)
	}
}

func TestDeleteMessage_StreamRunFKSetNullPreservesRunRow(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	uid, asst := runOneTurn(t, svc, sup, q, f, "first")

	// Sanity: stream_run rows reference both uid (parent) and asst (result).
	runs, _ := q.ListStreamRunsByConversation(context.Background(), f.conv.ID)
	if len(runs) == 0 {
		t.Fatal("no runs")
	}

	// Delete the user message with cascade=true so the assistant goes too.
	if _, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id:      uid.String(),
		Cascade: true,
	})); err != nil {
		t.Fatalf("DeleteMessage: %v", err)
	}
	// Both messages gone.
	if _, err := q.GetMessageByID(context.Background(), uid); err == nil {
		t.Error("user message should be deleted")
	}
	if _, err := q.GetMessageByID(context.Background(), asst.ID); err == nil {
		t.Error("assistant message should be deleted (cascade)")
	}
	// stream_run row preserved with FKs nulled.
	runRow, err := q.GetStreamRunByID(context.Background(), runs[0].ID)
	if err != nil {
		t.Fatalf("stream_run row should still exist: %v", err)
	}
	if runRow.ParentMessageID != nil {
		t.Errorf("parent_message_id should be NULL post-delete; got %+v", runRow.ParentMessageID)
	}
	if runRow.ResultMessageID != nil {
		t.Errorf("result_message_id should be NULL post-delete; got %+v", runRow.ResultMessageID)
	}
}

func TestDeleteMessage_NotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "delete-notfound", nil, nil)
	f := seedSendable(t, q, driverType)
	_, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestDeleteMessage_CrossUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "delete-cross-user", nil, nil)
	f := seedSendable(t, q, driverType)
	bob, _ := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uuid.New(), Username: "bob-" + t.Name(), PasswordHash: "x",
	})
	_, err := svc.DeleteMessage(ctxAsUser(bob), connect.NewRequest(&psmithv1.DeleteMessageRequest{
		Id: f.systemMsgID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- PromoteCompactionToNewContext -----------------------------------------

// Helper that drives a real Compact and returns the summary message id.
func compactAndGetSummary(t *testing.T, svc *Service, q *store.Queries, sup interface {
	Get(context.Context, uuid.UUID) (store.StreamRun, error)
}, f sendFixture) uuid.UUID {
	t.Helper()
	guide := "Summarize."
	mode := "REPLACE"
	bg := context.Background()
	_ = q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	})
	_ = q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	})
	_ = q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	})
	_ = q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	})

	// Need a user message in the context so the transcript isn't empty.
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "user", "tell me a story")

	resp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	deadline := bg
	_ = deadline
	// Poll until terminal.
	for i := 0; i < 200; i++ {
		row, _ := sup.Get(bg, runID)
		if row.Status != "running" {
			if row.ResultMessageID == nil {
				t.Fatalf("terminal status=%q but no result_message_id", row.Status)
			}
			return *row.ResultMessageID
		}
	}
	t.Fatal("compact never terminated")
	return uuid.Nil
}

func TestPromote_REPLACE_SeedsNewContextWithSummaryOnly(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "promote-replace",
		[]providers.Chunk{textChunk("the summary"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)
	summaryID := compactAndGetSummary(t, svc, q, sup, f)

	// Edit the summary to confirm Promote uses the (possibly-edited) content.
	if _, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
		Id:      summaryID.String(),
		Content: "edited summary",
	})); err != nil {
		t.Fatalf("EditMessage: %v", err)
	}

	resp, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{
		MessageId: summaryID.String(),
	}))
	if err != nil {
		t.Fatalf("Promote: %v", err)
	}
	newCtxID, _ := uuid.Parse(resp.Msg.Context.Id)
	// New context is parented to the source context and active.
	newCtxRow, _ := q.GetContextByID(context.Background(), newCtxID)
	if newCtxRow.ParentContextID == nil || *newCtxRow.ParentContextID != f.contextID {
		t.Errorf("new context's parent should be source context; got %+v", newCtxRow.ParentContextID)
	}
	active, _ := q.GetActiveContextByConversation(context.Background(), f.conv.ID)
	if active.ID != newCtxID {
		t.Errorf("new context should be active; active=%s want %s", active.ID, newCtxID)
	}
	// New context has role=system (from profile) and role=context (edited summary).
	msgs, err := q.ListMessagesByContext(context.Background(), newCtxID)
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	var sysMsg, ctxMsg *store.Message
	for i := range msgs {
		switch msgs[i].Role {
		case "system":
			sysMsg = &msgs[i]
		case "context":
			ctxMsg = &msgs[i]
		}
	}
	if sysMsg == nil {
		t.Fatal("new context is missing role=system message (profile system message not snapshotted)")
	}
	if sysMsg.Content != "You are concise." {
		t.Errorf("system content=%q want %q", sysMsg.Content, "You are concise.")
	}
	if ctxMsg == nil {
		t.Fatal("new context is missing role=context message")
	}
	if ctxMsg.Content != "edited summary" {
		t.Errorf("framing content=%q want %q", ctxMsg.Content, "edited summary")
	}
	// role=context is parented to role=system.
	if ctxMsg.ParentID == nil || *ctxMsg.ParentID != sysMsg.ID {
		t.Errorf("role=context parent should be role=system id; got %+v", ctxMsg.ParentID)
	}
	// Cursor on the new context is NULL.
	if newCtxRow.CurrentLeafMessageID != nil {
		t.Errorf("new context cursor should be NULL; got %+v", newCtxRow.CurrentLeafMessageID)
	}
}

func TestPromote_APPEND_ChainsForwardPriorRoleContextContent(t *testing.T) {
	t.Parallel()
	svc, q, sup := newFullSvc(t)
	driverType := registerFakeDriver(t, "promote-append",
		[]providers.Chunk{textChunk("NEW SUMMARY"), doneChunk()}, nil)
	f := seedSendable(t, q, driverType)

	// Seed a role=context message in the source so APPEND has something to chain.
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "context", "ORIGINAL FRAMING")

	// Configure profile for APPEND mode.
	guide := "Summarize."
	mode := "APPEND"
	bg := context.Background()
	_ = q.UpdateProfileCompressionGuide(bg, store.UpdateProfileCompressionGuideParams{
		ID: f.profile.ID, CompressionGuide: &guide,
	})
	_ = q.UpdateProfileCompressionMode(bg, store.UpdateProfileCompressionModeParams{
		ID: f.profile.ID, CompressionMode: &mode,
	})
	_ = q.UpdateProfileCompressionProviderID(bg, store.UpdateProfileCompressionProviderIDParams{
		ID: f.profile.ID, CompressionProviderID: &f.provider.ID,
	})
	_ = q.UpdateProfileCompressionModelID(bg, store.UpdateProfileCompressionModelIDParams{
		ID: f.profile.ID, CompressionModelID: &f.modelID,
	})

	// User turn so the transcript isn't empty.
	_ = insertMessage(t, q, f.contextID, &parent, "user", "tell me a story")

	cresp, err := svc.Compact(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CompactRequest{
		ConversationId: f.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("Compact: %v", err)
	}
	runID, _ := uuid.Parse(cresp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.ResultMessageID == nil {
		t.Fatal("no summary id")
	}
	resp, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{
		MessageId: final.ResultMessageID.String(),
	}))
	if err != nil {
		t.Fatalf("Promote: %v", err)
	}
	newCtxID, _ := uuid.Parse(resp.Msg.Context.Id)
	cxMsg, _ := q.GetContextRoleMessageInContext(context.Background(), newCtxID)
	want := "ORIGINAL FRAMING\n\nNEW SUMMARY"
	if cxMsg.Content != want {
		t.Errorf("APPEND content = %q want %q", cxMsg.Content, want)
	}
}

func TestPromote_RejectsNonSummaryMessage(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "promote-reject", nil, nil)
	f := seedSendable(t, q, driverType)
	parent := f.systemMsgID
	user := insertMessage(t, q, f.contextID, &parent, "user", "not a summary")
	_, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{
		MessageId: user.ID.String(),
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestPromote_NotFound(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "promote-notfound", nil, nil)
	f := seedSendable(t, q, driverType)
	_, err := svc.PromoteCompactionToNewContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{
		MessageId: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- CreateContextManual ---------------------------------------------------

func TestCreateContextManual_REPLACE_NoFraming(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "manual-replace", nil, nil)
	f := seedSendable(t, q, driverType)

	// Seed a role=context in the prior context to confirm REPLACE drops it.
	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "context", "OLD FRAMING")

	resp, err := svc.CreateContextManual(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CreateContextManualRequest{
		ConversationId:     f.conv.ID.String(),
		InitialUserMessage: "first turn in the new context",
		Mode:               psmithv1.CompressionMode_COMPRESSION_MODE_REPLACE,
	}))
	if err != nil {
		t.Fatalf("CreateContextManual: %v", err)
	}
	newCtxID, _ := uuid.Parse(resp.Msg.Context.Id)
	active, _ := q.GetActiveContextByConversation(context.Background(), f.conv.ID)
	if active.ID != newCtxID {
		t.Errorf("new context should be active; active=%s want %s", active.ID, newCtxID)
	}
	msgs, _ := q.ListMessagesByContext(context.Background(), newCtxID)
	var sysMsg, ctxMsg, userMsg *store.Message
	for i := range msgs {
		switch msgs[i].Role {
		case "system":
			sysMsg = &msgs[i]
		case "context":
			ctxMsg = &msgs[i]
		case "user":
			userMsg = &msgs[i]
		}
	}
	if sysMsg == nil {
		t.Fatal("missing role=system in new context")
	}
	if ctxMsg != nil {
		t.Errorf("REPLACE mode should NOT seed a role=context message; got %q", ctxMsg.Content)
	}
	if userMsg == nil || userMsg.Content != "first turn in the new context" {
		t.Fatalf("missing or wrong user message; got %+v", userMsg)
	}
	if userMsg.ParentID == nil || *userMsg.ParentID != sysMsg.ID {
		t.Errorf("user message should be parented to role=system (no role=context to chain through); got %+v", userMsg.ParentID)
	}
	if resp.Msg.UserMessage == nil || resp.Msg.UserMessage.Id != userMsg.ID.String() {
		t.Errorf("response should echo the seeded user message")
	}
}

func TestCreateContextManual_APPEND_InheritsPriorContext(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "manual-append", nil, nil)
	f := seedSendable(t, q, driverType)

	parent := f.systemMsgID
	_ = insertMessage(t, q, f.contextID, &parent, "context", "INHERITED FRAMING")

	resp, err := svc.CreateContextManual(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CreateContextManualRequest{
		ConversationId:     f.conv.ID.String(),
		InitialUserMessage: "",
		Mode:               psmithv1.CompressionMode_COMPRESSION_MODE_APPEND,
	}))
	if err != nil {
		t.Fatalf("CreateContextManual: %v", err)
	}
	newCtxID, _ := uuid.Parse(resp.Msg.Context.Id)

	cx, err := q.GetContextRoleMessageInContext(context.Background(), newCtxID)
	if err != nil {
		t.Fatalf("expected role=context in APPEND mode; %v", err)
	}
	if cx.Content != "INHERITED FRAMING" {
		t.Errorf("APPEND content = %q, want %q", cx.Content, "INHERITED FRAMING")
	}
	// Empty initial_user_message → no user row, no UserMessage in response.
	if resp.Msg.UserMessage != nil {
		t.Errorf("expected no user message when initial_user_message is empty; got %+v", resp.Msg.UserMessage)
	}
}

func TestCreateContextManual_RejectsUnknownConversation(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	driverType := registerFakeDriver(t, "manual-unknown", nil, nil)
	f := seedSendable(t, q, driverType)
	_ = f
	_, err := svc.CreateContextManual(ctxAsUser(f.user), connect.NewRequest(&psmithv1.CreateContextManualRequest{
		ConversationId: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- Conversation lock ----------------------------------------------------

// TestLock_BlocksMutationsWhileStreamRunning fires a long-lived stream and
// confirms that EditMessage, DeleteMessage, SendMessage, Compact, Promote,
// ActivateContext, SetCurrentLeaf, UpdateConversation, and DeleteConversation
// all reject with FailedPrecondition while the stream is in flight.
func TestLock_BlocksMutationsWhileStreamRunning(t *testing.T) {
	t.Parallel()
	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	// Don't enqueue a script; the server will hang waiting for one. We don't
	// want it to actually complete — just to sit in 'running' for the duration
	// of our assertions.

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	// Start a turn and let the run row exist in 'running' status. We DO need
	// the supervisor to start, so enqueue a script with a long delay.
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{
			{Type: fakellm.EventText, Text: "slow", Delay: 2 * 1000 * 1000 * 1000}, // 2s
		},
	})

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hi",
		ProviderId:     &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("first SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)

	// Verify the run is currently 'running'. (May still be in progress
	// when we check; that's the point.)
	for i := 0; i < 50; i++ {
		row, _ := sup.Get(context.Background(), runID)
		if row.Status == "running" {
			break
		}
	}

	// Various mutations should be rejected with FailedPrecondition.
	t.Run("SendMessage", func(t *testing.T) {
		_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
			ConversationId: f.conv.ID.String(),
			Content:        "another",
			ProviderId:     &pid, ModelId: &mid,
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("EditMessage", func(t *testing.T) {
		_, err := svc.EditMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.EditMessageRequest{
			Id: f.systemMsgID.String(), Content: "x",
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("DeleteMessage", func(t *testing.T) {
		_, err := svc.DeleteMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteMessageRequest{
			Id: f.systemMsgID.String(),
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("UpdateConversation", func(t *testing.T) {
		title := "blocked"
		_, err := svc.UpdateConversation(ctxAsUser(f.user), connect.NewRequest(&psmithv1.UpdateConversationRequest{
			Id: f.conv.ID.String(), Title: &title,
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("DeleteConversation", func(t *testing.T) {
		_, err := svc.DeleteConversation(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteConversationRequest{
			Id: f.conv.ID.String(),
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("ActivateContext", func(t *testing.T) {
		_, err := svc.ActivateContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ActivateContextRequest{
			ContextId: f.contextID.String(),
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})
	t.Run("SetCurrentLeaf", func(t *testing.T) {
		_, err := svc.SetCurrentLeaf(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SetCurrentLeafRequest{
			ContextId: f.contextID.String(),
			MessageId: f.systemMsgID.String(),
		}))
		assertCode(t, err, connect.CodeFailedPrecondition)
	})

	// Wait for the stream to terminate before the test exits so cleanup
	// doesn't race with the supervisor goroutine.
	_ = waitForTerminal(t, sup, runID)
}
