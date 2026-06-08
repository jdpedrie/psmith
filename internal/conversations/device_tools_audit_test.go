package conversations

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/devicetools"
	"github.com/jdpedrie/reeve/internal/store"
)

// TestRecordDeviceToolCompletion_WritesRow exercises the broker
// completion-hook path end-to-end via the Service: a fake event
// is fed in, the hook resolves the conversation owner via the
// queries, writes a row to device_tool_calls.
func TestRecordDeviceToolCompletion_WritesRow(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)

	user, conv, _ := seedUserAndConversation(t, q)

	callID := uuid.New()
	invoked := time.Now().UTC().Add(-2 * time.Second)
	completed := invoked.Add(1 * time.Second)

	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID:         callID,
		ConversationID: conv.ID,
		ToolName:       "calendar_list_events",
		Input:          json.RawMessage(`{"start_date":"2026-06-07"}`),
		Output:         json.RawMessage(`{"events":[]}`),
		Status:         "ok",
		InvokedAt:      invoked,
		CompletedAt:    completed,
	})

	rows, err := q.ListDeviceToolCallsByUser(context.Background(),
		store.ListDeviceToolCallsByUserParams{
			UserID: user.ID, InvokedAt: time.Now().UTC().Add(time.Minute), Limit: 10,
		})
	if err != nil {
		t.Fatalf("ListDeviceToolCallsByUser: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	r := rows[0]
	if r.ID != callID {
		t.Errorf("ID=%s want %s", r.ID, callID)
	}
	if r.UserID != user.ID {
		t.Errorf("UserID=%s want %s", r.UserID, user.ID)
	}
	if r.ConversationID != conv.ID {
		t.Errorf("ConversationID=%s want %s", r.ConversationID, conv.ID)
	}
	if r.ToolName != "calendar_list_events" {
		t.Errorf("ToolName=%q", r.ToolName)
	}
	if r.Status != "ok" {
		t.Errorf("Status=%q", r.Status)
	}
	if r.ErrorMessage != nil {
		t.Errorf("ErrorMessage should be nil on ok status; got %q", *r.ErrorMessage)
	}
	if !jsonEqual(t, r.InputJson, `{"start_date":"2026-06-07"}`) {
		t.Errorf("InputJson=%s", r.InputJson)
	}
	if !jsonEqual(t, r.OutputJson, `{"events":[]}`) {
		t.Errorf("OutputJson=%s", r.OutputJson)
	}
}

// jsonEqual compares two JSON byte buffers structurally — Postgres
// normalises JSONB whitespace on storage, so a byte-for-byte
// equality check would fail on a trivial format difference.
func jsonEqual(t *testing.T, got []byte, want string) bool {
	t.Helper()
	var a, b any
	if err := json.Unmarshal(got, &a); err != nil {
		return false
	}
	if err := json.Unmarshal([]byte(want), &b); err != nil {
		return false
	}
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	return string(ja) == string(jb)
}

// Error events should land with status='error' + the error message
// populated. The model sees the error string verbatim on the next
// round; the audit row is the user's record of it.
func TestRecordDeviceToolCompletion_ErrorStatusCapturesMessage(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)

	now := time.Now().UTC()
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID:         uuid.New(),
		ConversationID: conv.ID,
		ToolName:       "obsidian_create_note",
		Input:          json.RawMessage(`{"path":"x.md"}`),
		Status:         "error",
		ErrorMessage:   "note already exists",
		InvokedAt:      now,
		CompletedAt:    now,
	})

	rows, err := q.ListDeviceToolCallsByUser(context.Background(),
		store.ListDeviceToolCallsByUserParams{
			UserID: user.ID, InvokedAt: time.Now().UTC().Add(time.Minute), Limit: 10,
		})
	if err != nil || len(rows) != 1 {
		t.Fatalf("expected 1 row, err=%v rows=%d", err, len(rows))
	}
	r := rows[0]
	if r.Status != "error" {
		t.Errorf("Status=%q", r.Status)
	}
	if r.ErrorMessage == nil || *r.ErrorMessage != "note already exists" {
		t.Errorf("ErrorMessage=%v", r.ErrorMessage)
	}
}

// A timeout event is the broker firing the hook from the deadline
// branch — should write status='timeout' with the underlying
// deadline-exceeded error as the message.
func TestRecordDeviceToolCompletion_TimeoutStatus(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)

	now := time.Now().UTC()
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID:         uuid.New(),
		ConversationID: conv.ID,
		ToolName:       "reminders_list",
		Input:          json.RawMessage(`{}`),
		Status:         "timeout",
		ErrorMessage:   "context deadline exceeded",
		InvokedAt:      now,
		CompletedAt:    now.Add(60 * time.Second),
	})
	rows, _ := q.ListDeviceToolCallsByUser(context.Background(),
		store.ListDeviceToolCallsByUserParams{
			UserID: user.ID, InvokedAt: time.Now().UTC().Add(time.Minute), Limit: 10,
		})
	if len(rows) != 1 || rows[0].Status != "timeout" {
		t.Errorf("expected one timeout row; got %+v", rows)
	}
}

// A drop-on-missing-conversation event: the conversation was
// deleted between the call firing and the hook completing. Hook
// should swallow silently rather than poison the broker.
func TestRecordDeviceToolCompletion_MissingConversationSilentlyDropped(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, _, _ := seedUserAndConversation(t, q)

	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID:         uuid.New(),
		ConversationID: uuid.New(), // bogus
		ToolName:       "x",
		Input:          json.RawMessage(`{}`),
		Status:         "ok",
		InvokedAt:      time.Now().UTC(),
		CompletedAt:    time.Now().UTC(),
	})
	rows, _ := q.ListDeviceToolCallsByUser(context.Background(),
		store.ListDeviceToolCallsByUserParams{
			UserID: user.ID, InvokedAt: time.Now().UTC().Add(time.Minute), Limit: 10,
		})
	if len(rows) != 0 {
		t.Errorf("missing-conv event should drop silently; got %d rows", len(rows))
	}
}

// seedUserAndConversation is the minimal fixture for audit tests:
// just a user + a profile + a conversation. Audit doesn't need
// messages or stream runs.
func seedUserAndConversation(t *testing.T, q *store.Queries) (store.User, store.Conversation, store.Profile) {
	t.Helper()
	ctx := context.Background()
	u, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uuid.New(), Username: "audit-" + uuid.NewString()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	p, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID: uuid.New(), UserID: u.ID, Name: "audit",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	title := "audit"
	c, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID: uuid.New(), UserID: u.ID, ProfileID: p.ID, Title: &title,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	return u, c, p
}
