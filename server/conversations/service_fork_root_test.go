package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// A context with no system row starts at its first user message, which has
// no parent. Save and Resend there must fork beside it, not continue from the
// leaf: fork_at_root says so.
func TestFork_AtRoot(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, txt := range []string{"a1", "a2", "alt-asst"} {
		fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: txt}}})
	}
	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	if err := q.DeleteMessageByID(context.Background(), f.systemMsgID); err != nil {
		t.Fatalf("drop the system row: %v", err)
	}

	u1, _ := runOneTurn(t, svc, sup, q, f, "first")
	_, _ = runOneTurn(t, svc, sup, q, f, "second")

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "first, edited",
		ProviderId:     &pid,
		ModelId:        &mid,
		ForkAtRoot:     true,
	}))
	if err != nil {
		t.Fatalf("fork at root: %v", err)
	}
	if p := resp.Msg.UserMessage.GetParentId(); p != "" {
		t.Fatalf("the fork's parent is %q, want none", p)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("fork status=%q", final.Status)
	}

	leaf := final.ResultMessageID.String()
	list, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		LeafMessageId: &leaf,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	msgs := list.Msg.Messages
	if len(msgs) != 2 || msgs[0].Content != "first, edited" {
		t.Fatalf("the new branch is %d rows starting %q; want 2 starting with the fork", len(msgs), msgs[0].Content)
	}
	if msgs[0].SiblingCount != 1 {
		t.Errorf("the fork's sibling_count=%d, want 1 (the original first message)", msgs[0].SiblingCount)
	}
	if _, err := q.GetMessageByID(context.Background(), u1); err != nil {
		t.Errorf("the original first message is gone: %v", err)
	}
}

func TestFork_AtRootRejectsAParentOrARegenerate(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	sys := f.systemMsgID.String()

	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(), Content: "x", ParentMessageId: &sys, ForkAtRoot: true,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)

	_, err = svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(), ParentMessageId: &sys, Regenerate: true, ForkAtRoot: true,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}
