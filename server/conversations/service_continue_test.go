package conversations

import (
	"testing"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/fakellm"
)

// continue_discussion extends a turn with another speaker instead of replacing
// the answer. Structurally it is the regenerate path: no user row is inserted
// and the new assistant parents off the leaf.
func TestContinue_ChainsAnotherAssistantWithoutAUserRow(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "first speaker"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "second speaker"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, a1 := runOneTurn(t, svc, sup, q, f, "who should decide?")

	pid := f.provider.ID.String()
	mid := f.modelID
	leaf := a1.ID.String()
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:     f.conv.ID.String(),
		ParentMessageId:    &leaf,
		ContinueDiscussion: true,
		ProviderId:         &pid, ModelId: &mid,
	}))
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	// No user row was inserted: the echoed message is the assistant we
	// parented off.
	if resp.Msg.UserMessage.Id != leaf {
		t.Errorf("echoed id = %q want the leaf %q", resp.Msg.UserMessage.Id, leaf)
	}
	if resp.Msg.UserMessage.Role != psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
		t.Errorf("continue must not create a user row; got role %v", resp.Msg.UserMessage.Role)
	}
}

// Content is meaningless when extending a turn, the same as for regenerate.
func TestContinue_NeedsNoContent(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	leaf := "not-a-uuid"
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:     f.conv.ID.String(),
		ParentMessageId:    &leaf,
		ContinueDiscussion: true,
	}))
	// It must fail on the bad parent, NOT on missing content.
	if err == nil {
		t.Fatal("expected an error for the malformed parent")
	}
	if got := connect.CodeOf(err); got != connect.CodeInvalidArgument {
		t.Fatalf("code = %v want invalid_argument", got)
	}
	if msg := err.Error(); contains(msg, "content or attachment is required") {
		t.Errorf("continue must not require content: %v", msg)
	}
}

func TestContinue_RequiresParentMessageID(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:     f.conv.ID.String(),
		ContinueDiscussion: true,
	}))
	if err == nil {
		t.Fatal("continue without a parent must be rejected")
	}
	if !contains(err.Error(), "continue_discussion requires parent_message_id") {
		t.Errorf("error should name the flag that failed: %v", err)
	}
}

// Two clients tapping continue at the same moment must not each add a speaker
// to the same turn. The second sees a stale leaf and is refused.
func TestContinue_RefusesAStaleLeaf(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a1"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a2"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, a1 := runOneTurn(t, svc, sup, q, f, "q")

	// u1 is a real message but no longer the leaf: a1 is.
	stale := u1.String()
	pid := f.provider.ID.String()
	mid := f.modelID
	_, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:     f.conv.ID.String(),
		ParentMessageId:    &stale,
		ContinueDiscussion: true,
		ProviderId:         &pid, ModelId: &mid,
	}))
	if err == nil {
		t.Fatal("continuing from a stale leaf must be refused")
	}
	if got := connect.CodeOf(err); got != connect.CodeAborted {
		t.Errorf("code = %v want aborted, so clients can retry against the new leaf", got)
	}
	_ = a1
}

// Regenerate deliberately keeps working from a non-leaf message: forking off
// an older turn is the whole point of it.
func TestRegenerate_StillAllowsANonLeafParent(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a1"}}})
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "alt"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, _ := runOneTurn(t, svc, sup, q, f, "q")

	stale := u1.String()
	pid := f.provider.ID.String()
	mid := f.modelID
	if _, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:  f.conv.ID.String(),
		ParentMessageId: &stale,
		Regenerate:      true,
		ProviderId:      &pid, ModelId: &mid,
	})); err != nil {
		t.Fatalf("regenerate from a non-leaf parent must still work: %v", err)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (haystack == needle ||
		len(needle) == 0 || indexOfStr(haystack, needle) >= 0)
}

func indexOfStr(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
