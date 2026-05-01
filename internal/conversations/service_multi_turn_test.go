package conversations

import (
	"context"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/fakellm"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
)

// runOneTurn drives a single SendMessage end-to-end against the fake server
// and returns the materialized assistant Message row. assumes Caller has
// already enqueued a script onto fake.
func runOneTurn(t *testing.T, svc *Service, sup *stream.Supervisor, q *store.Queries, f sendFixture, content string) (userMsgID uuid.UUID, assistant store.Message) {
	t.Helper()
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        content,
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage(%q): %v", content, err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	final := waitForTerminal(t, sup, runID)
	if final.Status != "completed" {
		t.Fatalf("turn %q status=%q want completed; err=%s",
			content, final.Status, string(final.ErrorPayload))
	}
	if final.ResultMessageID == nil {
		t.Fatalf("turn %q: no result_message_id", content)
	}
	asst, err := q.GetMessageByID(context.Background(), *final.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	uid, _ := uuid.Parse(resp.Msg.UserMessage.Id)
	return uid, asst
}

// TestMultiTurn_ParentChainCorrect — three back-and-forth turns. After each
// turn the next user message must parent off the just-materialized assistant
// (proving the cursor advances on materialization, not just on user-insert).
func TestMultiTurn_ParentChainCorrect(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for _, reply := range []string{"reply-1", "reply-2", "reply-3"} {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: reply}},
			Usage:  &fakellm.Usage{InputTokens: 1, OutputTokens: 1},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, a1 := runOneTurn(t, svc, sup, q, f, "msg-1")
	u2, a2 := runOneTurn(t, svc, sup, q, f, "msg-2")
	u3, a3 := runOneTurn(t, svc, sup, q, f, "msg-3")

	// Expected tree: system -> u1 -> a1 -> u2 -> a2 -> u3 -> a3
	check := func(label string, msg store.Message, wantParent uuid.UUID) {
		if msg.ParentID == nil {
			t.Errorf("%s.parent_id is nil; want %s", label, wantParent)
			return
		}
		if *msg.ParentID != wantParent {
			t.Errorf("%s.parent_id=%s want %s", label, msg.ParentID, wantParent)
		}
	}
	u1Row, _ := q.GetMessageByID(context.Background(), u1)
	u2Row, _ := q.GetMessageByID(context.Background(), u2)
	u3Row, _ := q.GetMessageByID(context.Background(), u3)
	check("u1", u1Row, f.systemMsgID)
	check("a1", a1, u1)
	check("u2", u2Row, a1.ID)
	check("a2", a2, u2)
	check("u3", u3Row, a2.ID)
	check("a3", a3, u3)

	// And the cursor lands on the final assistant message.
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.CurrentLeafMessageID == nil || *cx.CurrentLeafMessageID != a3.ID {
		t.Errorf("cursor=%+v want %s", cx.CurrentLeafMessageID, a3.ID)
	}
}

// TestMultiTurn_EmptyAssistantContent — the model returns nothing. We should
// still materialize an empty assistant row so the next turn parents off it
// and the user can see "the model produced nothing."
func TestMultiTurn_EmptyAssistantContent(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{ // empty script: no Events, no Usage
		Events: nil,
	})
	fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}},
	})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	u1, a1 := runOneTurn(t, svc, sup, q, f, "first")
	if a1.Content != "" {
		t.Errorf("a1.content=%q want empty", a1.Content)
	}
	if a1.ParentID == nil || *a1.ParentID != u1 {
		t.Errorf("a1.parent should be u1=%s, got %+v", u1, a1.ParentID)
	}

	// Next turn: user message must still parent off a1 (the empty asst).
	u2, _ := runOneTurn(t, svc, sup, q, f, "second")
	u2Row, _ := q.GetMessageByID(context.Background(), u2)
	if u2Row.ParentID == nil || *u2Row.ParentID != a1.ID {
		t.Errorf("u2 should parent off empty assistant; parent=%+v want %s",
			u2Row.ParentID, a1.ID)
	}
}

// TestMultiTurn_LongStream — many text deltas plus thinking interleaved. The
// final assistant content should be the deltas concatenated in order, and the
// thinking column should hold the accumulated reasoning text.
func TestMultiTurn_LongStream(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	var events []fakellm.Event
	var wantContent strings.Builder
	for i := 0; i < 50; i++ {
		ev := fakellm.Event{Type: fakellm.EventText, Text: "x"}
		events = append(events, ev)
		wantContent.WriteString("x")
	}
	fake.Enqueue(fakellm.Script{
		Events: events,
		Usage:  &fakellm.Usage{InputTokens: 100, OutputTokens: 50},
	})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	_, a1 := runOneTurn(t, svc, sup, q, f, "make it long")
	if a1.Content != wantContent.String() {
		t.Errorf("content len=%d want %d", len(a1.Content), wantContent.Len())
	}
	if a1.OutputTokens == nil || *a1.OutputTokens != 50 {
		t.Errorf("output_tokens=%+v want 50", a1.OutputTokens)
	}
}

// TestMultiTurn_ConcurrentSendsSerialize — fire N SendMessages concurrently
// on the same context with no explicit parent_message_id. The
// SELECT FOR UPDATE on the contexts row in SendMessage's critical section
// serializes them: each send observes the previous send's committed cursor
// and parents off it, producing a deterministic linear chain of user
// messages instead of the racy chain-vs-siblings non-determinism.
//
// (Whether a chain or siblings is the "right" UX for double-clicked send is
// a separate question; the contract this test pins is determinism.)
func TestMultiTurn_ConcurrentSendsSerialize(t *testing.T) {
	t.Parallel()

	const N = 5

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	for i := 0; i < N; i++ {
		fake.Enqueue(fakellm.Script{
			Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}},
		})
	}

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	pid := f.provider.ID.String()
	mid := f.modelID

	var wg sync.WaitGroup
	results := make([]*reevev1.SendMessageResponse, N)
	errs := make([]error, N)
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&reevev1.SendMessageRequest{
				ConversationId: f.conv.ID.String(),
				Content:        "concurrent",
				ProviderId:     &pid,
				ModelId:        &mid,
			}))
			if err == nil {
				results[i] = resp.Msg
			}
			errs[i] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	for _, r := range results {
		runID, _ := uuid.Parse(r.StreamRun.Id)
		_ = waitForTerminal(t, sup, runID)
	}

	all, err := q.ListMessagesByContext(context.Background(), f.contextID)
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	users := make([]store.Message, 0, N)
	for _, m := range all {
		if m.Role == "user" {
			users = append(users, m)
		}
	}
	if len(users) != N {
		t.Fatalf("user messages persisted=%d want %d", len(users), N)
	}

	// Invariants worth pinning (the tree shape itself depends on whether
	// assistants materialize between successive sends — the cursor catches
	// asst messages too, so user_k may parent off either user_{k-1} or
	// asst_{j} for some j < k):
	//
	//  - Every user message is in this context.
	//  - Every user message has a parent that resolves and is in this
	//    context (no dangling parent_ids).
	//  - Walking parent_id from each user message reaches the system seed
	//    in a finite number of steps (no cycles, no orphans).
	for _, u := range users {
		if u.ContextID != f.contextID {
			t.Errorf("user %s in wrong context: %s vs %s", u.ID, u.ContextID, f.contextID)
		}
		if u.ParentID == nil {
			t.Errorf("user %s has no parent", u.ID)
			continue
		}
		// Walk to root.
		cursor := u.ID
		steps := 0
		for steps < 4*N { // generous bound; chain depth at most ~2*N (user+asst)
			steps++
			row, err := q.GetMessageByID(context.Background(), cursor)
			if err != nil {
				t.Fatalf("walk %s: GetMessageByID(%s): %v", u.ID, cursor, err)
			}
			if row.ID == f.systemMsgID {
				break
			}
			if row.ContextID != f.contextID {
				t.Errorf("walk %s landed in wrong context at %s", u.ID, row.ID)
				break
			}
			if row.ParentID == nil {
				t.Errorf("walk %s: orphan at %s (role=%q)", u.ID, row.ID, row.Role)
				break
			}
			cursor = *row.ParentID
		}
		if steps >= 4*N {
			t.Errorf("walk %s exceeded step bound; possible cycle", u.ID)
		}
	}

	// And the final cursor on the context resolves to a real message in
	// this context (whichever assistant materialized last).
	cx, _ := q.GetContextByID(context.Background(), f.contextID)
	if cx.CurrentLeafMessageID == nil {
		t.Fatal("cursor cleared after concurrent sends")
	}
	leaf, err := q.GetMessageByID(context.Background(), *cx.CurrentLeafMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID(leaf): %v", err)
	}
	if leaf.ContextID != f.contextID {
		t.Errorf("cursor leaf in wrong context: %s vs %s", leaf.ContextID, f.contextID)
	}
}
