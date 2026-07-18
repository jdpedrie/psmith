package conversations

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
)

func TestDeleteContext_RemovesContextMessagesAndRuns(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "ok"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())
	original := f.contextID

	// Give the original context a real turn: user + assistant messages
	// plus a stream_run row (stream_runs.context_id has no cascade —
	// this is the FK edge the delete has to clear itself).
	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "turn in the doomed context",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	waitForTerminal(t, sup, runID)

	// A newer context takes over as active; the original becomes
	// deletable. Parent it to the original so re-parenting has an
	// observable effect.
	origPtr := original
	newer, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID: uuid.New(), ConversationID: f.conv.ID,
		ParentContextID:       &origPtr,
		ContextActivationTime: func() time.Time { time.Sleep(5 * time.Millisecond); return time.Now().UTC() }(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	msgsBefore, err := q.ListMessagesByContext(context.Background(), original)
	if err != nil || len(msgsBefore) == 0 {
		t.Fatalf("expected messages in original context, got %d (err=%v)", len(msgsBefore), err)
	}

	if _, err := svc.DeleteContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteContextRequest{
		ContextId: original.String(),
	})); err != nil {
		t.Fatalf("DeleteContext: %v", err)
	}

	// Context row gone.
	if _, err := q.GetContextByID(context.Background(), original); err == nil {
		t.Error("original context still exists after delete")
	}
	// Messages gone.
	msgsAfter, err := q.ListMessagesByContext(context.Background(), original)
	if err != nil {
		t.Fatalf("ListMessagesByContext after delete: %v", err)
	}
	if len(msgsAfter) != 0 {
		t.Errorf("expected 0 messages after delete, got %d", len(msgsAfter))
	}
	// Child context re-parented to the deleted context's parent (nil —
	// the original was a root).
	child, err := q.GetContextByID(context.Background(), newer.ID)
	if err != nil {
		t.Fatalf("GetContextByID(newer): %v", err)
	}
	if child.ParentContextID != nil {
		t.Errorf("child parent_context_id = %v, want nil after reparent", child.ParentContextID)
	}
	// The stream run for the deleted context is gone.
	if _, err := q.GetStreamRunByID(context.Background(), runID); err == nil {
		t.Error("stream_run for deleted context still exists")
	}
}

func TestDeleteContext_ActiveRefused(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://unused.invalid")

	_, err := svc.DeleteContext(ctxAsUser(f.user), connect.NewRequest(&psmithv1.DeleteContextRequest{
		ContextId: f.contextID.String(),
	}))
	if err == nil {
		t.Fatal("expected error deleting the active context")
	}
	var cerr *connect.Error
	if !errors.As(err, &cerr) || cerr.Code() != connect.CodeFailedPrecondition {
		t.Errorf("error = %v, want FailedPrecondition", err)
	}
	// Still present.
	if _, err := q.GetContextByID(context.Background(), f.contextID); err != nil {
		t.Errorf("active context should survive the refused delete: %v", err)
	}
}

func TestDeleteContext_OtherUsersContextNotFound(t *testing.T) {
	t.Parallel()

	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://unused.invalid")
	stranger, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uuid.New(), Username: "stranger-" + uuid.NewString()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	_, err = svc.DeleteContext(ctxAsUser(stranger), connect.NewRequest(&psmithv1.DeleteContextRequest{
		ContextId: f.contextID.String(),
	}))
	if err == nil {
		t.Fatal("expected error deleting another user's context")
	}
	var cerr *connect.Error
	if !errors.As(err, &cerr) || cerr.Code() != connect.CodeNotFound {
		t.Errorf("error = %v, want NotFound", err)
	}
}

// Structure-only tree listing: skeleton rows with ids/parents/roles and
// no content — the branch switcher's payload diet.
func TestListMessages_StructureOnly(t *testing.T) {
	t.Parallel()

	fake := fakellm.NewServer(t, fakellm.FlavorAnthropic)
	fake.Enqueue(fakellm.Script{Events: []fakellm.Event{{Type: fakellm.EventText, Text: "a perfectly weighty reply"}}})

	svc, q, sup := newFullSvc(t)
	f := seedAnthropicSendable(t, q, fake.URL())

	pid := f.provider.ID.String()
	mid := f.modelID
	resp, err := svc.SendMessage(ctxAsUser(f.user), connect.NewRequest(&psmithv1.SendMessageRequest{
		ConversationId: f.conv.ID.String(),
		Content:        "hello there",
		ProviderId:     &pid,
		ModelId:        &mid,
	}))
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	runID, _ := uuid.Parse(resp.Msg.StreamRun.Id)
	waitForTerminal(t, sup, runID)

	full, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId: f.contextID.String(),
		FullTree:  true,
	}))
	if err != nil {
		t.Fatalf("ListMessages(full): %v", err)
	}
	skel, err := svc.ListMessages(ctxAsUser(f.user), connect.NewRequest(&psmithv1.ListMessagesRequest{
		ContextId:     f.contextID.String(),
		FullTree:      true,
		StructureOnly: true,
	}))
	if err != nil {
		t.Fatalf("ListMessages(structure): %v", err)
	}

	if len(skel.Msg.Messages) != len(full.Msg.Messages) {
		t.Fatalf("structure rows = %d, full rows = %d — must match", len(skel.Msg.Messages), len(full.Msg.Messages))
	}
	fullByID := map[string]*psmithv1.Message{}
	for _, m := range full.Msg.Messages {
		fullByID[m.Id] = m
	}
	for _, m := range skel.Msg.Messages {
		ref, ok := fullByID[m.Id]
		if !ok {
			t.Fatalf("structure row %s missing from full listing", m.Id)
		}
		if m.Content != "" {
			t.Errorf("structure row %s carries content (%d bytes) — must be empty", m.Id, len(m.Content))
		}
		if m.Role != ref.Role {
			t.Errorf("structure row %s role = %v, want %v", m.Id, m.Role, ref.Role)
		}
		refParent := ""
		if ref.ParentId != nil {
			refParent = *ref.ParentId
		}
		gotParent := ""
		if m.ParentId != nil {
			gotParent = *m.ParentId
		}
		if gotParent != refParent {
			t.Errorf("structure row %s parent = %q, want %q", m.Id, gotParent, refParent)
		}
	}
}
