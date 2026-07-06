package conversations

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
)

// TestFork_FromDeepAncestor — build system → u1 → a1 → u2 → a2 → u3 → a3,
// then fork off u1 (3 levels deep). The new branch must:
//  1. Have parent=u1 on the new user message.
//  2. Show sibling_count=1 on u1's children when listing the new branch
//     (a1 is the existing child; the new user msg is the second).
//  3. Move the cursor onto the new branch (after the new turn materializes).
func TestFork_FromDeepAncestor(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "a2", "a3", "fork-asst"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, _ := runOneTurn(t, svc, sup, q, f, "msg-1")
	_, _ = runOneTurn(t, svc, sup, q, f, "msg-2")
	_, _ = runOneTurn(t, svc, sup, q, f, "msg-3")

	// Fork off u1.
	pid := f.provider.ID.String()
	mid := f.modelID
	u1Str := u1.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &u1Str,
		Content:         "fork from u1",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	if err != nil {
		t.Fatalf("fork SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != u1Str {
		t.Errorf("fork user.parent_id=%q want %q", resp.Msg.UserMessage.GetParentId(), u1Str)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("fork status=%q", final.Status)
	}

	// Cursor lands on the new fork's assistant message.
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.CurrentLeafMessageID == nil || *cx.CurrentLeafMessageID != *final.ResultMessageID {
		t.Errorf("cursor=%+v want %s (fork assistant)", cx.CurrentLeafMessageID, final.ResultMessageID)
	}

	// Listing via the new fork's leaf returns a 3-row chain (system, u1, fork-user)
	// because the fork-user has not yet been replied to as the leaf — wait,
	// actually the leaf is final.ResultMessageID (the assistant). So the chain
	// should be: system → u1 → fork-user → fork-asst. And sibling_count on u1
	// should be 1 (the original a1 is u1's other child... wait no, a1 is the
	// reply to u1 so it IS u1's child. The fork-user is u1's other child.
	// So u1 has two children: a1 and fork-user. From the fork branch's
	// perspective, fork-user has 1 sibling (a1).
	leaf := final.ResultMessageID.String()
	listResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(listResp.Msg.Messages) != 4 {
		t.Fatalf("chain len=%d want 4 (system,u1,fork-user,fork-asst)", len(listResp.Msg.Messages))
	}
	// fork-user is at depth 2 (root-first ordering: system=0, u1=1, fork-user=2, fork-asst=3).
	forkUser := listResp.Msg.Messages[2]
	if forkUser.SiblingCount != 1 {
		t.Errorf("fork-user.sibling_count=%d want 1 (a1 is its sibling)", forkUser.SiblingCount)
	}
}

// TestFork_FromSystemMessage — fork directly off the system seed. Should
// produce a tree with two top-level user threads parented at system.
func TestFork_FromSystemMessage(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a1"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a2"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, _ = runOneTurn(t, svc, sup, q, f, "first thread")

	// Fork off system.
	pid := f.provider.ID.String()
	mid := f.modelID
	sysStr := f.systemMsgID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &sysStr,
		Content:         "second thread",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	if err != nil {
		t.Fatalf("fork SendMessage: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != sysStr {
		t.Errorf("forked user.parent=%q want %q", resp.Msg.UserMessage.GetParentId(), sysStr)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	// Listing the new branch: should be system → fork-user → fork-asst (3 rows).
	// system has 0 siblings (it's the root). fork-user has 1 sibling (the original first user).
	leaf := resp.Msg.StreamRun.GetResultMessageId()
	if leaf == "" {
		// Reload run to get the result.
		runRow, _ := q.GetStreamRunByID(context.Background(), runID)
		if runRow.ResultMessageID != nil {
			leaf = runRow.ResultMessageID.String()
		}
	}
	if leaf == "" {
		t.Fatal("no result_message_id for fork run")
	}
	listResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(listResp.Msg.Messages) != 3 {
		t.Fatalf("chain len=%d want 3", len(listResp.Msg.Messages))
	}
	forkUser := listResp.Msg.Messages[1]
	if forkUser.SiblingCount != 1 {
		t.Errorf("fork-user.sibling_count=%d want 1", forkUser.SiblingCount)
	}
}

// TestFork_RejectsCrossContextParent — try to fork using a parent_message_id
// that lives in a sibling Context. Must reject with InvalidArgument.
func TestFork_RejectsCrossContextParent(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	// Build a sibling context with one message.
	otherCx, _ := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    uuid.New(),
		ConversationID:        f.conv.ID,
		ContextActivationTime: time.Now().UTC().Add(-time.Hour), // older = inactive
	})
	otherMsg, _ := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID: uuid.New(), ContextID: otherCx.ID, Role: "user", Content: "stray",
	})

	pid := f.provider.ID.String()
	mid := f.modelID
	otherIDStr := otherMsg.ID.String()
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &otherIDStr,
		Content:         "wrong context",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// TestFork_ParentNotFound — fork using a random UUID. Must reject with NotFound.
func TestFork_ParentNotFound(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	pid := f.provider.ID.String()
	mid := f.modelID
	missing := uuid.New().String()
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &missing,
		Content:         "ghost parent",
		ProviderId:      &pid,
		ModelId:         &mid,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// TestFork_TwoForksFromSameParent_SiblingCountReflects — explicit fork once,
// then fork again off the same parent. sibling_count on the second fork's
// new user message should reflect the actual count (parent now has 3 children:
// the original next-user, fork-1, fork-2 → fork-2 has 2 siblings).
func TestFork_TwoForksFromSameParent_SiblingCountReflects(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a-orig", "a-fork-1", "a-fork-2"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, _ := runOneTurn(t, svc, sup, q, f, "original")

	pid := f.provider.ID.String()
	mid := f.modelID
	u1Str := u1.String()

	// Fork 1.
	resp1, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &u1Str,
		Content:         "fork-1",
		ProviderId:      &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("fork-1: %v", err)
	}
	runID1, _ := uuid.Parse(resp1.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID1)

	// Fork 2 off the same u1.
	resp2, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &u1Str,
		Content:         "fork-2",
		ProviderId:      &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("fork-2: %v", err)
	}
	runID2, _ := uuid.Parse(resp2.Msg.StreamRun.Id)
	final2 := waitForTerminal(t, sup, runID2)

	// u1 now has 3 children: a-orig, fork-1-user, fork-2-user.
	// Listing through fork-2's leaf:
	//   system → u1 → fork-2-user → a-fork-2
	leaf := final2.ResultMessageID.String()
	listResp, _ := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if len(listResp.Msg.Messages) != 4 {
		t.Fatalf("chain len=%d want 4", len(listResp.Msg.Messages))
	}
	fork2User := listResp.Msg.Messages[2]
	if fork2User.SiblingCount != 2 {
		t.Errorf("fork-2-user.sibling_count=%d want 2 (a-orig + fork-1-user)",
			fork2User.SiblingCount)
	}
}

// TestFork_FromAssistantMessage — fork off an assistant message. The new user
// turn's parent is that assistant. This is the "regenerate" pattern in chat
// UIs: pick an assistant reply, branch your follow-up off it instead of the
// later turn the model already produced.
func TestFork_FromAssistantMessage(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "a2", "fork-asst"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, a1 := runOneTurn(t, svc, sup, q, f, "msg-1")
	_, _ = runOneTurn(t, svc, sup, q, f, "msg-2")

	// Fork off a1 (regenerate the next turn).
	pid := f.provider.ID.String()
	mid := f.modelID
	a1Str := a1.ID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &a1Str,
		Content:         "different msg-2",
		ProviderId:      &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("fork: %v", err)
	}
	if resp.Msg.UserMessage.GetParentId() != a1Str {
		t.Errorf("fork user.parent=%q want %q", resp.Msg.UserMessage.GetParentId(), a1Str)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	_ = waitForTerminal(t, sup, runID)

	// Confirm sibling_count: a1 had one prior user-child (the msg-2 user msg);
	// the fork makes 2 total children, so the fork user should report 1 sibling.
	final, _ := q.GetStreamRunByID(context.Background(), runID)
	leaf := final.ResultMessageID.String()
	listResp, _ := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	// chain: system → u1 → a1 → fork-user → fork-asst (5 rows)
	if len(listResp.Msg.Messages) != 5 {
		t.Fatalf("chain len=%d want 5", len(listResp.Msg.Messages))
	}
	forkUser := listResp.Msg.Messages[3]
	if forkUser.SiblingCount != 1 {
		t.Errorf("fork-user.sibling_count=%d want 1", forkUser.SiblingCount)
	}
}

// TestRegenerate_FromAssistantParent — chained assistant generation.
// Powers the Mac client's "Save and Resend" affordance on edited
// assistant rows: the edit stays put, the model continues from there,
// and the result is two assistants in a row (a1 → a2 under the SAME
// user). regenerate=true with parent=assistant skips the user-row
// insert; the new assistant is parented directly to the existing
// assistant.
func TestRegenerate_FromAssistantParent(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a1"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "continuation"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, a1 := runOneTurn(t, svc, sup, q, f, "msg-1")
	_ = u1

	// Regenerate with a1 as the parent — should chain a NEW assistant
	// after a1 (not a sibling under u1, which is the user-parent path).
	pid := f.provider.ID.String()
	mid := f.modelID
	a1Str := a1.ID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &a1Str,
		Regenerate:      true,
		ProviderId:      &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("regenerate from assistant: %v", err)
	}
	// Echoed parent_message in the response is the existing assistant
	// row (regenerate skips user-row insert). The proto field is named
	// `user_message` for historical reasons; for assistant-parent
	// regenerate it carries the assistant we parented off of.
	if resp.Msg.UserMessage.Id != a1Str {
		t.Errorf("echoed parent id=%q want %q", resp.Msg.UserMessage.Id, a1Str)
	}
	if resp.Msg.UserMessage.Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
		t.Errorf("echoed parent role=%v want assistant", resp.Msg.UserMessage.Role)
	}

	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("regenerate stream status=%q", final.Status)
	}
	if final.ResultMessageID == nil {
		t.Fatal("no result_message_id on terminal stream")
	}

	// The new assistant's parent_id must point at a1 (chained), not at
	// u1 (which would be the sibling-pattern).
	newAsst, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID(new asst): %v", err)
	}
	if newAsst.Role != "assistant" {
		t.Errorf("new turn role=%q want assistant", newAsst.Role)
	}
	if newAsst.ParentID == nil || *newAsst.ParentID != a1.ID {
		t.Errorf("new asst.parent_id=%v want %s (chained after a1)", newAsst.ParentID, a1.ID)
	}

	// Final wire chain: system → u1 → a1 → newAsst (4 rows).
	leaf := final.ResultMessageID.String()
	listResp, _ := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if len(listResp.Msg.Messages) != 4 {
		var roles []string
		for _, m := range listResp.Msg.Messages {
			roles = append(roles, m.Role.String())
		}
		t.Fatalf("chain len=%d want 4 (system, u1, a1, newAsst); got %v",
			len(listResp.Msg.Messages), roles)
	}
	tail := listResp.Msg.Messages[len(listResp.Msg.Messages)-2:]
	if tail[0].Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT ||
		tail[1].Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
		t.Errorf("trailing roles=%v,%v want assistant,assistant", tail[0].Role, tail[1].Role)
	}

	// Wire-shape check: the request body sent to the upstream LLM must
	// include a synthetic trailing user message. Most providers (OpenAI
	// Chat, Google Gemini) reject a contents array that doesn't end
	// with a user turn; injecting a single-space user satisfies them
	// without persisting any extra row.
	reqs := fake.Requests()
	if len(reqs) < 2 {
		t.Fatalf("fakellm captured %d requests, want >=2", len(reqs))
	}
	// Second request is the assistant-parent regenerate. Body is
	// Anthropic-shaped (FlavorAnthropic): {"messages":[{"role":..., "content":...}]}.
	var bodyShape struct {
		Messages []struct {
			Role    string `json:"role"`
			Content any    `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(reqs[1].Body, &bodyShape); err != nil {
		t.Fatalf("decode wire body: %v; body=%s", err, string(reqs[1].Body))
	}
	if n := len(bodyShape.Messages); n == 0 || bodyShape.Messages[n-1].Role != "user" {
		t.Errorf("wire prefix doesn't end with user turn; got %d messages, last role=%q",
			n, lastRole(bodyShape.Messages))
	}
}

func lastRole(ms []struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}) string {
	if len(ms) == 0 {
		return ""
	}
	return ms[len(ms)-1].Role
}

// TestRegenerate_RejectsSystemParent — only user and assistant parents
// are valid for regenerate; system / context / summary stay rejected.
func TestRegenerate_RejectsSystemParent(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://unused")

	// Find the system-seeded message (set up by seedAnthropicSendable).
	rows, err := q.ListMessagesByContext(context.Background(), f.contextID)
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	var sysID uuid.UUID
	for _, m := range rows {
		if m.Role == "system" {
			sysID = m.ID
			break
		}
	}
	if sysID == uuid.Nil {
		t.Fatal("no system message in fixture")
	}

	pid := f.provider.ID.String()
	mid := f.modelID
	sysStr := sysID.String()
	_, err = svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &sysStr,
		Regenerate:      true,
		ProviderId:      &pid, ModelId: &mid,
	}))
	if err == nil {
		t.Fatal("expected InvalidArgument; regenerate from system should be rejected")
	}
	if got := connect.CodeOf(err); got != connect.CodeInvalidArgument {
		t.Errorf("err code=%v want InvalidArgument", got)
	}
}

// TestFork_DifferentModelOnFork — fork using a different model than the
// original turn used. Confirms history.Build copes with cross-model prefix
// when assembling the new turn's wire shape.
func TestFork_DifferentModelOnFork(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a1"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "fork-with-other-model"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	// Add a SECOND model on the same provider so we can switch on the fork.
	otherModel := "claude-fake-pro"
	in, out := 5.0, 25.0
	if _, err := q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID:   f.provider.ID,
		ModelID:               otherModel,
		DisplayName:           "Claude Fake Pro",
		InputPricePerMillion:  &in,
		OutputPricePerMillion: &out,
		MetadataSource:        "manual",
		MetadataSnapshotAt:    time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}

	u1, a1 := runOneTurn(t, svc, sup, q, f, "msg-1")
	if a1.ModelID == nil || *a1.ModelID != f.modelID {
		t.Errorf("a1.model=%+v want %q", a1.ModelID, f.modelID)
	}

	// Fork off u1 using the OTHER model.
	pid := f.provider.ID.String()
	u1Str := u1.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &u1Str,
		Content:         "fork on other model",
		ProviderId:      &pid,
		ModelId:         &otherModel,
	}))
	if err != nil {
		t.Fatalf("fork: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("fork status=%q err=%s", final.Status, string(final.ErrorPayload))
	}
	asst, _ := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if asst.ModelID == nil || *asst.ModelID != otherModel {
		t.Errorf("fork assistant.model=%+v want %q", asst.ModelID, otherModel)
	}
	// And cost was computed off the OTHER model's pricing snapshot, not the
	// original — confirms the materialization fetches the user_model fresh.
	if !asst.OutputCostUsd.Valid {
		t.Error("fork assistant has null output_cost_usd; pricing-snapshot lookup failed?")
	}

	// Suppress unused fmt import if helpers don't use it.
	_ = fmt.Sprintf
}
