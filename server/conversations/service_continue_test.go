package conversations

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/store"
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

// The chain query and chainRowToProto both list columns explicitly, so a new
// message column reaches clients only if it is added in BOTH places. Persona
// was dropped in exactly that way: it was written correctly, visible in the
// database, and absent from every client. The unit converter passed the whole
// time, because it is not the converter that was wrong.
//
// This asserts the path clients actually use, end to end through the RPC.
func TestListMessages_CarriesPersonaOnTheChainPath(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	persona := "Skeptic"
	var idx int32 = 2
	user := insertMessage(t, q, f.contextID, nil, "user", "q")
	asst := insertMessage(t, q, f.contextID, &user.ID, "assistant", "a")
	// Set the columns directly: the supervisor writes them at materialization,
	// and this test is about the READ path.
	if _, err := q.SetMessagePersonaForTest(context.Background(), store.SetMessagePersonaForTestParams{
		ID: asst.ID, Persona: &persona, PersonaIndex: &idx,
	}); err != nil {
		t.Fatalf("set persona: %v", err)
	}

	resp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	var found *psmithv1.Message
	for _, m := range resp.Msg.Messages {
		if m.Role == psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT {
			found = m
		}
	}
	if found == nil {
		t.Fatal("no assistant message returned")
	}
	if found.Persona == nil || *found.Persona != persona {
		t.Errorf("persona did not reach the wire: %v", found.Persona)
	}
	if found.PersonaIndex == nil || *found.PersonaIndex != idx {
		t.Errorf("persona index did not reach the wire: %v", found.PersonaIndex)
	}
}

// prepareTurn resolves and validates without writing. That is the property
// that made extracting it from SendMessage safe, and the one a future edit
// could quietly break by moving an insert up into it — at which point a
// rejected send would start leaving rows behind.
func TestPrepareTurn_WritesNothing(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	count := func() int {
		rows, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{ContextID: f.contextID})
		if err != nil {
			t.Fatalf("ListMessagesByContext: %v", err)
		}
		return len(rows)
	}
	before := count()

	pid := f.provider.ID.String()
	mid := f.modelID
	_, prepared, err := svc.prepareTurn(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hello",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("prepareTurn: %v", err)
	}
	if after := count(); after != before {
		t.Errorf("prepareTurn wrote %d rows; it must resolve only", after-before)
	}

	// And it resolved what the send needs, so a passing "wrote nothing" is not
	// just an early return.
	if prepared.modelID != f.modelID {
		t.Errorf("model not resolved: %q", prepared.modelID)
	}
	if prepared.providerID != f.provider.ID {
		t.Errorf("provider not resolved: %v", prepared.providerID)
	}
	if prepared.conv.ID != f.conv.ID {
		t.Errorf("conversation not resolved: %v", prepared.conv.ID)
	}
}

// A rejection must also leave nothing behind.
func TestPrepareTurn_RejectsWithoutWriting(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	before, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{ContextID: f.contextID})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	// No content and no attachment on a non-extending send.
	if _, _, err := svc.prepareTurn(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
	})); err == nil {
		t.Fatal("expected a rejection for an empty send")
	}
	after, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{ContextID: f.contextID})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(after) != len(before) {
		t.Errorf("a rejected send left %d rows behind", len(after)-len(before))
	}
}

// A full-tree read is bounded, and truncation is REPORTED rather than served
// silently. Half a tree is not a smaller tree: a fork whose sibling fell off
// the end renders as no fork at all, so a client has to be able to tell.
func TestListMessages_FullTreeReportsTruncation(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	// Well under the cap: the ordinary case must not claim truncation.
	root := insertMessage(t, q, f.contextID, nil, "user", "q")
	_ = insertMessage(t, q, f.contextID, &root.ID, "assistant", "a")

	resp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
		FullTree:  true,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if resp.Msg.Truncated {
		t.Error("a small context must not report truncation")
	}
	if len(resp.Msg.Messages) < 2 {
		t.Errorf("expected the seeded messages, got %d", len(resp.Msg.Messages))
	}

	// Same for the structure-only path, which has its own query and its own
	// truncation check.
	structResp, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		FullTree:      true,
		StructureOnly: true,
	}))
	if err != nil {
		t.Fatalf("ListMessages structureOnly: %v", err)
	}
	if structResp.Msg.Truncated {
		t.Error("a small context must not report truncation on the skeleton path")
	}
}

// The cap is enforced in SQL, so a caller cannot be handed an unbounded set
// even if the handler's slicing were wrong.
func TestListMessagesByContext_RespectsTheRowLimit(t *testing.T) {
	t.Parallel()
	_, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	var parent *uuid.UUID
	for i := 0; i < 6; i++ {
		row := insertMessage(t, q, f.contextID, parent, "user", "m")
		id := row.ID
		parent = &id
	}

	limited, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{
		ContextID: f.contextID, RowLimit: 3,
	})
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	if len(limited) != 3 {
		t.Errorf("row limit ignored: got %d rows, want 3", len(limited))
	}

	// Zero means unbounded, the same convention as every other row_limit.
	all, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{
		ContextID: f.contextID,
	})
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	if len(all) <= 3 {
		t.Errorf("zero limit should be unbounded, got %d rows", len(all))
	}
}
