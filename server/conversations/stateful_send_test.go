package conversations

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// fakeStatefulDriver stands in for a harness. It mints a handle per turn the
// way a real one does (Codex forks, Claude Code resumes into a new session id)
// and records every call so a test can assert on what the send path decided.
type fakeStatefulDriver struct {
	typeName string

	mu       sync.Mutex
	starts   []providers.SessionConfig
	sends    []statefulSendCall
	turnSeq  int
	startErr error
}

type statefulSendCall struct {
	handle   string
	message  providers.WireMessage
	settings providers.CallSettings
}

func (f *fakeStatefulDriver) Type() string   { return f.typeName }
func (f *fakeStatefulDriver) Stateful() bool { return true }
func (f *fakeStatefulDriver) DiscoverModels(_ context.Context) ([]providers.Model, error) {
	return nil, nil
}
func (f *fakeStatefulDriver) RenderThinkingToText(_ json.RawMessage) string { return "" }

func (f *fakeStatefulDriver) StartSession(_ context.Context, _ string, cfg providers.SessionConfig) (string, error) {
	if f.startErr != nil {
		return "", f.startErr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.starts = append(f.starts, cfg)
	return "session-root", nil
}

func (f *fakeStatefulDriver) TerminateSession(_ context.Context, _ string) error { return nil }

func (f *fakeStatefulDriver) SendInSession(_ context.Context, handle string, msg providers.WireMessage, settings providers.CallSettings) (<-chan providers.Chunk, error) {
	f.mu.Lock()
	f.sends = append(f.sends, statefulSendCall{handle: handle, message: msg, settings: settings})
	f.turnSeq++
	next := fmt.Sprintf("%s/turn-%d", handle, f.turnSeq)
	f.mu.Unlock()

	ch := make(chan providers.Chunk, 3)
	raw, _ := json.Marshal(map[string]string{"session_id": next})
	ch <- providers.Chunk{Type: providers.ChunkSessionHandle, Payload: raw}
	ch <- textChunk("ok")
	ch <- doneChunk()
	close(ch)
	return ch, nil
}

func (f *fakeStatefulDriver) calls() ([]providers.SessionConfig, []statefulSendCall) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]providers.SessionConfig(nil), f.starts...), append([]statefulSendCall(nil), f.sends...)
}

func registerFakeStatefulDriver(t *testing.T) (string, *fakeStatefulDriver) {
	t.Helper()
	typeName := uniqueDriverName(t, "fake-stateful")
	// One instance shared across Builds. The send path builds a driver per
	// turn, and these assertions are about the sequence across turns.
	d := &fakeStatefulDriver{typeName: typeName}
	providers.Register(typeName, func(_ providers.Deps, _ json.RawMessage) (providers.Provider, error) {
		return d, nil
	})
	return typeName, d
}

func sendStateful(t *testing.T, svc *Service, fx sendFixture, content string, mutate ...func(*psmithv1.SendMessageRequest)) *psmithv1.SendMessageResponse {
	t.Helper()
	provID := fx.provider.ID.String()
	modelID := fx.modelID
	msg := &psmithv1.SendMessageRequest{
		ConversationId: fx.conv.ID.String(),
		Content:        content,
		ProviderId:     &provID,
		ModelId:        &modelID,
	}
	for _, m := range mutate {
		m(msg)
	}
	resp, err := svc.SendMessage(ctxAsUser(fx.user), connect.NewRequest(msg))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	return resp.Msg
}

// A stateful driver gets one session opened, one message per turn, and a
// handle that advances with the conversation.
func TestStatefulSend_OpensOnceAndChainsHandles(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	typeName, drv := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, typeName)

	first := sendStateful(t, svc, fx, "hello")
	runID, err := uuid.Parse(first.StreamRun.Id)
	if err != nil {
		t.Fatalf("parse run id: %v", err)
	}
	waitForTerminal(t, sup, runID)

	second := sendStateful(t, svc, fx, "again")
	runID2, err := uuid.Parse(second.StreamRun.Id)
	if err != nil {
		t.Fatalf("parse run id: %v", err)
	}
	waitForTerminal(t, sup, runID2)

	starts, sends := drv.calls()
	if len(starts) != 1 {
		t.Fatalf("StartSession called %d times, want exactly 1 (the second turn must reuse the branch's handle)", len(starts))
	}
	if starts[0].SystemPrompt != "You are concise." {
		t.Errorf("session system prompt = %q, want the profile's system message", starts[0].SystemPrompt)
	}
	if len(sends) != 2 {
		t.Fatalf("SendInSession called %d times, want 2", len(sends))
	}
	if sends[0].handle != "session-root" {
		t.Errorf("first send handle = %q, want the freshly-opened session", sends[0].handle)
	}
	// The second turn extends the handle the FIRST turn produced, not the one
	// the session opened with. That is what makes the harness's state and the
	// message tree agree.
	if sends[1].handle != "session-root/turn-1" {
		t.Errorf("second send handle = %q, want the handle stamped on the first assistant row", sends[1].handle)
	}

	// Only the latest message travels. The system row and the prior turn are
	// the harness's problem, not ours.
	if got := sends[1].message.Content; got != "again" {
		t.Errorf("second send content = %q, want only the newest user message", got)
	}
	if sends[1].message.Role != "user" {
		t.Errorf("second send role = %q, want user", sends[1].message.Role)
	}
}

// The handle lands on the assistant row that produced it, which is the whole
// basis for resolving it by walking a branch.
func TestStatefulSend_StampsHandleOnAssistantRow(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	typeName, _ := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, typeName)

	resp := sendStateful(t, svc, fx, "hello")
	runID, _ := uuid.Parse(resp.StreamRun.Id)
	waitForTerminal(t, sup, runID)

	rows, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{
		ContextID: fx.contextID,
		RowLimit:  100,
	})
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	var assistant *store.Message
	for i := range rows {
		switch rows[i].Role {
		case "assistant":
			assistant = &rows[i]
		case "user":
			if rows[i].HarnessHandle != nil {
				t.Errorf("user row carries a harness handle %q; only the turn that produced it should", *rows[i].HarnessHandle)
			}
		}
	}
	if assistant == nil {
		t.Fatal("no assistant row materialized")
	}
	if assistant.HarnessHandle == nil {
		t.Fatal("assistant row has no harness handle; the next turn would reopen the session")
	}
	if *assistant.HarnessHandle != "session-root/turn-1" {
		t.Errorf("handle = %q, want the one the driver emitted for this turn", *assistant.HarnessHandle)
	}
}

// Two branches off one parent each resolve to their own handle. This is the
// property that makes editing an old message fork the harness rather than
// mutate it.
func TestResolveHarnessHandle_PerBranch(t *testing.T) {
	svc, q, _, pool := newFullSvcWithPool(t)
	ctx := context.Background()
	typeName, _ := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, typeName)

	mk := func(parent *uuid.UUID, role, content, handle string) store.Message {
		t.Helper()
		id, _ := uuid.NewV7()
		var h *string
		if handle != "" {
			h = &handle
		}
		row, err := q.CreateMessage(ctx, store.CreateMessageParams{
			ID: id, ContextID: fx.contextID, ParentID: parent, Role: role, Content: content,
		})
		if err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		if h != nil {
			// Written with raw SQL rather than a store query: production only
			// ever sets this at assistant-insert time, and a setter that
			// exists purely for tests would read like a supported operation.
			if _, err := pool.Exec(ctx, `UPDATE messages SET harness_handle = $2 WHERE id = $1`, row.ID, *h); err != nil {
				t.Fatalf("set harness_handle: %v", err)
			}
			row.HarnessHandle = h
		}
		return row
	}

	//   u1 → a1(handle-1) → ┬ u2a → a2a(handle-2a)
	//                       └ u2b
	u1 := mk(&fx.systemMsgID, "user", "q1", "")
	a1 := mk(&u1.ID, "assistant", "a1", "handle-1")
	u2a := mk(&a1.ID, "user", "q2a", "")
	a2a := mk(&u2a.ID, "assistant", "a2a", "handle-2a")
	u2b := mk(&a1.ID, "user", "q2b", "")

	cases := []struct {
		name string
		from uuid.UUID
		want string
	}{
		{"tip of the deep branch", a2a.ID, "handle-2a"},
		{"user row walks past itself to its parent", u2a.ID, "handle-1"},
		{"sibling branch sees only the shared ancestor", u2b.ID, "handle-1"},
		{"the assistant row itself", a1.ID, "handle-1"},
		{"above any harness turn", u1.ID, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := svc.resolveHarnessHandle(ctx, tc.from)
			if err != nil {
				t.Fatalf("resolveHarnessHandle: %v", err)
			}
			if got != tc.want {
				t.Errorf("resolveHarnessHandle = %q, want %q", got, tc.want)
			}
		})
	}
}

// A branch with no harness turn above it is not an error: it is the signal to
// open a session.
func TestResolveHarnessHandle_UnknownMessage(t *testing.T) {
	svc, _, _ := newFullSvc(t)
	id, _ := uuid.NewV7()
	got, err := svc.resolveHarnessHandle(context.Background(), id)
	if err != nil {
		t.Fatalf("resolveHarnessHandle on an unknown id: %v", err)
	}
	if got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// Regenerating off an old user message forks the harness from that message's
// state rather than the branch tip. Without a per-message handle there is
// nothing to fork from and the retry would carry the abandoned turn.
func TestStatefulSend_RegenerateForksFromTheParentsHandle(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	typeName, drv := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, typeName)

	first := sendStateful(t, svc, fx, "hello")
	r1, _ := uuid.Parse(first.StreamRun.Id)
	waitForTerminal(t, sup, r1)
	firstUserID := first.UserMessage.Id

	second := sendStateful(t, svc, fx, "again")
	r2, _ := uuid.Parse(second.StreamRun.Id)
	waitForTerminal(t, sup, r2)

	// Back to the first question. The tip is now two turns ahead of it.
	regen := sendStateful(t, svc, fx, "", func(m *psmithv1.SendMessageRequest) {
		m.Regenerate = true
		m.ParentMessageId = &firstUserID
	})
	r3, _ := uuid.Parse(regen.StreamRun.Id)
	waitForTerminal(t, sup, r3)

	_, sends := drv.calls()
	if len(sends) != 3 {
		t.Fatalf("SendInSession called %d times, want 3", len(sends))
	}
	// The first turn's user row has no handle of its own, so the walk lands on
	// whatever preceded it: nothing. A fresh session, which is right — the
	// state before the first question is the empty one.
	if sends[2].handle != "session-root" {
		t.Errorf("regenerate handle = %q, want the state as of the first question, not the branch tip %q",
			sends[2].handle, sends[1].handle)
	}
	if sends[2].handle == "session-root/turn-2" {
		t.Error("regenerate reused the branch tip; the discarded turn is still in the harness's transcript")
	}
}

// A harness cannot receive attachments, and the refusal has to arrive before
// the user's message is persisted: a message stranded in the tree with no turn
// behind it is worse than an error the client can show.
func TestStatefulSend_RejectsAttachmentsWithoutPersisting(t *testing.T) {
	svc, q, _ := newFullSvc(t)
	typeName, drv := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, typeName)

	fileID := uuid.New()
	if _, err := q.CreateFile(ctxAsUser(fx.user), store.CreateFileParams{
		ID: fileID, UserID: fx.user.ID, Sha256: "sha-harness-attach",
		MimeType: "image/png", SizeBytes: 64,
	}); err != nil {
		t.Fatalf("CreateFile: %v", err)
	}

	provID := fx.provider.ID.String()
	modelID := fx.modelID
	_, err := svc.SendMessage(ctxAsUser(fx.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId:    fx.conv.ID.String(),
		Content:           "look at this",
		ProviderId:        &provID,
		ModelId:           &modelID,
		AttachmentFileIds: []string{fileID.String()},
	}))
	if err == nil {
		t.Fatal("SendMessage accepted an attachment for a harness driver")
	}
	if got := connect.CodeOf(err); got != connect.CodeInvalidArgument {
		t.Errorf("code = %v, want %v", got, connect.CodeInvalidArgument)
	}

	if _, sends := drv.calls(); len(sends) != 0 {
		t.Errorf("driver saw %d sends, want 0", len(sends))
	}
	rows, err := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{
		ContextID: fx.contextID, RowLimit: 100,
	})
	if err != nil {
		t.Fatalf("ListMessagesByContext: %v", err)
	}
	for _, r := range rows {
		if r.Role == "user" {
			t.Fatalf("a user row was persisted for a refused send: %q", r.Content)
		}
	}
}

// Once a harness has answered, the conversation belongs to it. Sending to a
// different provider is refused: the handles are the other harness's, and
// there is no prefix to hand a stateless one.
func TestStatefulSend_BoundConversationRefusesAnotherProvider(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	harnessType, _ := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, harnessType)

	first := sendStateful(t, svc, fx, "hello")
	r1, _ := uuid.Parse(first.StreamRun.Id)
	waitForTerminal(t, sup, r1)

	// A second, perfectly good provider on the same account.
	otherType := registerFakeDriver(t, "bound-other",
		[]providers.Chunk{textChunk("hi"), doneChunk()}, nil)
	other := seedSecondProvider(t, q, fx.user.ID, otherType)

	otherID := other.ID.String()
	modelID := fx.modelID
	_, err := svc.SendMessage(ctxAsUser(fx.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: fx.conv.ID.String(),
		Content:        "switch to something else",
		ProviderId:     &otherID,
		ModelId:        &modelID,
	}))
	if err == nil {
		t.Fatal("SendMessage let a bound conversation change provider")
	}
	if got := connect.CodeOf(err); got != connect.CodeFailedPrecondition {
		t.Errorf("code = %v, want %v", got, connect.CodeFailedPrecondition)
	}
	// The message the user typed must not be sitting in the tree.
	rows, _ := q.ListMessagesByContext(context.Background(), store.ListMessagesByContextParams{
		ContextID: fx.contextID, RowLimit: 100,
	})
	for _, r := range rows {
		if r.Content == "switch to something else" {
			t.Fatal("the refused message was persisted")
		}
	}
}

// The other direction: a conversation a regular provider has already answered
// cannot be handed to a harness, which would start its transcript at the
// switch and never see anything before it.
func TestStatefulSend_HarnessRefusesAnAnsweredConversation(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	statelessType := registerFakeDriver(t, "bound-stateless",
		[]providers.Chunk{textChunk("regular reply"), doneChunk()}, nil)
	fx := seedSendable(t, q, statelessType)

	first := sendStateful(t, svc, fx, "hello")
	r1, _ := uuid.Parse(first.StreamRun.Id)
	waitForTerminal(t, sup, r1)

	harnessType, drv := registerFakeStatefulDriver(t)
	harness := seedSecondProvider(t, q, fx.user.ID, harnessType)

	hID := harness.ID.String()
	modelID := fx.modelID
	_, err := svc.SendMessage(ctxAsUser(fx.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: fx.conv.ID.String(),
		Content:        "take over",
		ProviderId:     &hID,
		ModelId:        &modelID,
	}))
	if err == nil {
		t.Fatal("a harness picked up a conversation it cannot see the history of")
	}
	if got := connect.CodeOf(err); got != connect.CodeFailedPrecondition {
		t.Errorf("code = %v, want %v", got, connect.CodeFailedPrecondition)
	}
	if starts, _ := drv.calls(); len(starts) != 0 {
		t.Errorf("StartSession was called %d times for a refused send", len(starts))
	}
}

// A fresh conversation is not bound, so picking a harness for its first turn
// works. Guards against the check being read as "harness sends are refused".
func TestStatefulSend_UnansweredConversationAcceptsAHarness(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	harnessType, drv := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, harnessType)

	resp := sendStateful(t, svc, fx, "first thing anyone has said here")
	rid, _ := uuid.Parse(resp.StreamRun.Id)
	if row := waitForTerminal(t, sup, rid); row.Status != "completed" {
		t.Fatalf("run status = %q, want completed", row.Status)
	}
	if _, sends := drv.calls(); len(sends) != 1 {
		t.Errorf("driver saw %d sends, want 1", len(sends))
	}
}

// The binding rides on the conversation proto so clients do not have to join
// provider type to driver statefulness themselves.
func TestGetConversation_ReportsTheHarnessBinding(t *testing.T) {
	svc, q, sup := newFullSvc(t)
	harnessType, _ := registerFakeStatefulDriver(t)
	fx := seedSendable(t, q, harnessType)

	before, err := svc.GetConversation(ctxAsUser(fx.user), connect.NewRequest(&psmithv1.GetConversationRequest{
		Id: fx.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if before.Msg.Conversation.Harness != nil {
		t.Error("an unanswered conversation reported a binding; nothing has committed it yet")
	}

	resp := sendStateful(t, svc, fx, "hello")
	rid, _ := uuid.Parse(resp.StreamRun.Id)
	waitForTerminal(t, sup, rid)

	after, err := svc.GetConversation(ctxAsUser(fx.user), connect.NewRequest(&psmithv1.GetConversationRequest{
		Id: fx.conv.ID.String(),
	}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	b := after.Msg.Conversation.Harness
	if b == nil {
		t.Fatal("no binding reported after a harness answered")
	}
	if b.ProviderId != fx.provider.ID.String() {
		t.Errorf("provider_id = %q, want %q", b.ProviderId, fx.provider.ID)
	}
	if b.DriverType != harnessType {
		t.Errorf("driver_type = %q, want %q", b.DriverType, harnessType)
	}
	if b.ProviderLabel == "" {
		t.Error("provider_label is empty; the client has nothing to name in an explanation")
	}
	if b.AcceptsAttachments {
		t.Error("accepts_attachments is true, but the send path refuses them")
	}
	if !b.SystemPromptFrozen {
		t.Error("system_prompt_frozen is false, but the session pinned it at StartSession")
	}
}

func seedSecondProvider(t *testing.T, q *store.Queries, userID uuid.UUID, driverType string) store.UserModelProvider {
	t.Helper()
	ctx := context.Background()
	id, _ := uuid.NewV7()
	prov, err := q.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{
		ID: id, UserID: userID, Type: driverType, Label: "second " + driverType,
		ConfigEncrypted: []byte("{}"),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	if _, err := q.UpsertUserModel(ctx, store.UpsertUserModelParams{
		UserModelProviderID: prov.ID,
		ModelID:             "fake-model",
		DisplayName:         "Fake Model",
		MetadataSource:      "manual",
		MetadataSnapshotAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertUserModel: %v", err)
	}
	return prov
}
