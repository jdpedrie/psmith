package conversations

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/devicetools"
)

func TestDeviceToolsService_RegisterCapabilities_PopulatesRegistry(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, _, _ := seedUserAndConversation(t, q)

	handler := svc.DeviceToolsService()
	ctx := auth.ContextWithUser(context.Background(),
		auth.User{ID: user.ID, Username: user.Username})

	_, err := handler.RegisterCapabilities(ctx, connect.NewRequest(&spaltv1.RegisterCapabilitiesRequest{
		SupportedToolNames: []string{"calendar_list_events", "reminders_list"},
		ClientAttributes:   map[string]string{"os": "iOS", "version": "26.5"},
	}))
	if err != nil {
		t.Fatalf("RegisterCapabilities: %v", err)
	}

	// Registry should report the union via the (user, nil-conv)
	// key — that's what the handler uses since this RPC isn't
	// conversation-scoped today.
	set := svc.deviceToolRegistry.SupportedSet(user.ID, uuid.Nil)
	if _, ok := set["calendar_list_events"]; !ok {
		t.Errorf("calendar_list_events should be registered; got %v", set)
	}
	attrs := svc.deviceToolRegistry.Attributes(user.ID, uuid.Nil)
	if attrs["os"] != "iOS" {
		t.Errorf("attrs missing os=iOS: %v", attrs)
	}
}

func TestDeviceToolsService_RegisterCapabilities_RequiresAuth(t *testing.T) {
	t.Parallel()
	svc, _, _ := newFullSvc(t)
	handler := svc.DeviceToolsService()

	_, err := handler.RegisterCapabilities(context.Background(),
		connect.NewRequest(&spaltv1.RegisterCapabilitiesRequest{}))
	if err == nil {
		t.Fatal("want Unauthenticated error")
	}
	if cerr, ok := err.(*connect.Error); !ok || cerr.Code() != connect.CodeUnauthenticated {
		t.Errorf("want CodeUnauthenticated; got %v", err)
	}
}

func TestDeviceToolsService_ListSupportedTools_ReturnsCatalog(t *testing.T) {
	t.Parallel()
	svc, _, _ := newFullSvc(t)
	handler := svc.DeviceToolsService()

	resp, err := handler.ListSupportedTools(context.Background(),
		connect.NewRequest(&spaltv1.ListSupportedToolsRequest{}))
	if err != nil {
		t.Fatalf("ListSupportedTools: %v", err)
	}
	if len(resp.Msg.Tools) == 0 {
		t.Fatal("catalog should be non-empty")
	}
	// Verify the shape mirrors devicetools.All — schema bytes,
	// category, required-permissions list.
	var sawCalendar bool
	for _, tool := range resp.Msg.Tools {
		if tool.Name == "calendar_list_events" {
			sawCalendar = true
			if tool.Category != "Calendar" {
				t.Errorf("calendar_list_events.Category=%q want Calendar", tool.Category)
			}
			if len(tool.InputSchema) == 0 {
				t.Error("calendar_list_events should ship a non-empty schema")
			}
		}
	}
	if !sawCalendar {
		t.Errorf("calendar_list_events missing from catalog: %v",
			toolNames(resp.Msg.Tools))
	}
}

func TestDeviceToolsService_ListDeviceToolCalls_ScopedToCaller(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)
	otherUser, otherConv, _ := seedUserAndConversation(t, q)

	now := time.Now().UTC()
	// One row for the caller + one for a different user. The
	// caller should only see their own.
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID: uuid.New(), ConversationID: conv.ID,
		ToolName: "calendar_list_events",
		Input:    json.RawMessage(`{}`), Output: json.RawMessage(`{}`),
		Status: "ok", InvokedAt: now, CompletedAt: now,
	})
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID: uuid.New(), ConversationID: otherConv.ID,
		ToolName: "reminders_list",
		Input:    json.RawMessage(`{}`), Output: json.RawMessage(`{}`),
		Status: "ok", InvokedAt: now, CompletedAt: now,
	})

	handler := svc.DeviceToolsService()
	ctx := auth.ContextWithUser(context.Background(),
		auth.User{ID: user.ID, Username: user.Username})

	resp, err := handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{}))
	if err != nil {
		t.Fatalf("ListDeviceToolCalls: %v", err)
	}
	if len(resp.Msg.Calls) != 1 {
		t.Fatalf("got %d calls, want 1 (caller-scope); got tools=%v",
			len(resp.Msg.Calls), callNames(resp.Msg.Calls))
	}
	if resp.Msg.Calls[0].ToolName != "calendar_list_events" {
		t.Errorf("wrong call: %s", resp.Msg.Calls[0].ToolName)
	}

	// Pull-by-conversation: the caller's own conversation succeeds.
	convStr := conv.ID.String()
	resp, err = handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{
			ConversationId: &convStr,
		}))
	if err != nil {
		t.Fatalf("ListDeviceToolCalls by conv: %v", err)
	}
	if len(resp.Msg.Calls) != 1 {
		t.Errorf("got %d calls in own conv", len(resp.Msg.Calls))
	}

	// And: a probe for someone else's conversation gets NotFound
	// rather than leaking the row count.
	otherConvStr := otherConv.ID.String()
	_, err = handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{
			ConversationId: &otherConvStr,
		}))
	if err == nil {
		t.Fatal("want NotFound on cross-user conv probe")
	}
	if cerr, ok := err.(*connect.Error); !ok || cerr.Code() != connect.CodeNotFound {
		t.Errorf("want CodeNotFound; got %v", err)
	}
	_ = otherUser
}

func TestDeviceToolsService_ListDeviceToolCalls_HonoursCursor(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)

	// Three rows at distinct timestamps in the recent past. Past
	// timestamps so they all satisfy the handler's default
	// before=NOW() cutoff (otherwise rows-in-the-future get
	// silently excluded on the first page).
	now := time.Now().UTC()
	for i := 0; i < 3; i++ {
		ts := now.Add(time.Duration(i-3) * time.Second) // -3s, -2s, -1s
		svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
			CallID:         uuid.New(),
			ConversationID: conv.ID,
			ToolName:       "calendar_list_events",
			Input:          json.RawMessage(`{}`),
			Output:         json.RawMessage(`{}`),
			Status:         "ok",
			InvokedAt:      ts,
			CompletedAt:    ts,
		})
	}

	handler := svc.DeviceToolsService()
	ctx := auth.ContextWithUser(context.Background(),
		auth.User{ID: user.ID, Username: user.Username})

	// First page: all three.
	resp, err := handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{}))
	if err != nil || len(resp.Msg.Calls) != 3 {
		t.Fatalf("first page err=%v count=%d", err, len(resp.Msg.Calls))
	}

	// Cursor from row[1] (the middle one) — page should return
	// only the row[0] (oldest).
	cursor := resp.Msg.Calls[1].InvokedAt
	resp, err = handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{
			Before: timestamppb.New(cursor.AsTime()),
		}))
	if err != nil {
		t.Fatalf("paginated err: %v", err)
	}
	if len(resp.Msg.Calls) != 1 {
		t.Errorf("paginated count=%d want 1 (oldest after middle)", len(resp.Msg.Calls))
	}
}

// callsToProto is a private helper but easy to exercise via
// ListDeviceToolCalls. Verify shape: nullable fields surface
// correctly (message_id absent, error_message absent on OK).
func TestDeviceToolsService_CallsToProto_NullableFields(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	user, conv, _ := seedUserAndConversation(t, q)

	// Two rows: one ok (no error), one error (with message).
	now := time.Now().UTC()
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID: uuid.New(), ConversationID: conv.ID,
		ToolName: "calendar_list_events", Input: json.RawMessage(`{}`),
		Output: json.RawMessage(`{}`), Status: "ok",
		InvokedAt: now, CompletedAt: now,
	})
	svc.recordDeviceToolCompletion(devicetools.CompletionEvent{
		CallID: uuid.New(), ConversationID: conv.ID,
		ToolName: "obsidian_create_note", Input: json.RawMessage(`{}`),
		Status: "error", ErrorMessage: "vault not found",
		InvokedAt: now.Add(time.Millisecond), CompletedAt: now.Add(time.Millisecond),
	})

	handler := svc.DeviceToolsService()
	ctx := auth.ContextWithUser(context.Background(),
		auth.User{ID: user.ID, Username: user.Username})
	resp, err := handler.ListDeviceToolCalls(ctx,
		connect.NewRequest(&spaltv1.ListDeviceToolCallsRequest{}))
	if err != nil {
		t.Fatalf("ListDeviceToolCalls: %v", err)
	}

	for _, c := range resp.Msg.Calls {
		// All rows have no message_id by design (audit hook
		// doesn't have the materialised assistant id yet).
		if c.MessageId != nil {
			t.Errorf("MessageId should be nil; got %v", c.MessageId)
		}
		// Error rows carry error_message; ok rows don't.
		if c.Status == "ok" && c.ErrorMessage != "" {
			t.Errorf("ok row leaked error_message: %q", c.ErrorMessage)
		}
		if c.Status == "error" && c.ErrorMessage == "" {
			t.Errorf("error row missing error_message")
		}
	}
}

// Helpers ------------------------------------------------------------

func toolNames(in []*spaltv1.SupportedTool) []string {
	out := make([]string, len(in))
	for i, t := range in {
		out[i] = t.Name
	}
	return out
}

func callNames(in []*spaltv1.DeviceToolCall) []string {
	out := make([]string, len(in))
	for i, c := range in {
		out[i] = c.ToolName
	}
	return out
}
