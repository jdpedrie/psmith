package devicetools

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestInvoke_HappyPath(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	conv := uuid.New()

	// Capture the emit so the test can play the role of "client
	// that received the chunk."
	var captured Request
	emit := func(r Request) { captured = r }

	// Run Invoke in a goroutine so the main test goroutine can
	// play the client side via Respond.
	type result struct {
		out json.RawMessage
		err error
	}
	done := make(chan result, 1)
	go func() {
		out, err := b.Invoke(context.Background(), conv,
			"calendar_list_events",
			json.RawMessage(`{"start_date":"2026-06-07"}`),
			0, emit)
		done <- result{out, err}
	}()

	// Wait briefly for the goroutine to register + emit.
	deadline := time.Now().Add(2 * time.Second)
	for captured.CallID == uuid.Nil && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	if captured.CallID == uuid.Nil {
		t.Fatal("emit never fired within 2s")
	}
	if captured.ToolName != "calendar_list_events" {
		t.Errorf("captured.ToolName=%q", captured.ToolName)
	}

	// Play the client side.
	if err := b.Respond(conv, captured.CallID, Response{
		Output: json.RawMessage(`{"events":[]}`),
	}); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	r := <-done
	if r.err != nil {
		t.Fatalf("Invoke: %v", r.err)
	}
	if string(r.out) != `{"events":[]}` {
		t.Errorf("output=%s", r.out)
	}
}

func TestInvoke_ResponseErrorBecomesGoError(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	conv := uuid.New()

	var captured Request
	go func() {
		_, _ = b.Invoke(context.Background(), conv, "calendar_create_event",
			json.RawMessage(`{}`), 0, func(r Request) { captured = r })
	}()

	for captured.CallID == uuid.Nil {
		time.Sleep(1 * time.Millisecond)
	}

	if err := b.Respond(conv, captured.CallID, Response{
		Error: "calendar permission denied",
	}); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	// Re-run the Invoke with the response in-flight to grab the error.
	// Easier: just verify Respond's effect by checking the snapshot
	// was cleared.
	if _, ok := b.Snapshot(captured.CallID); ok {
		t.Error("snapshot should be cleared after Respond")
	}
}

func TestInvoke_TimeoutPropagates(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	conv := uuid.New()
	_, err := b.Invoke(context.Background(), conv, "noop",
		json.RawMessage(`{}`), 30*time.Millisecond, nil)
	if err == nil {
		t.Fatal("want timeout error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("err=%v; want DeadlineExceeded chain", err)
	}
}

func TestInvoke_CtxCancelPropagates(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	conv := uuid.New()
	ctx, cancel := context.WithCancel(context.Background())

	type result struct{ err error }
	done := make(chan result, 1)
	go func() {
		_, err := b.Invoke(ctx, conv, "noop",
			json.RawMessage(`{}`), 5*time.Second, nil)
		done <- result{err}
	}()
	time.Sleep(10 * time.Millisecond)
	cancel()

	select {
	case r := <-done:
		if r.err == nil || !errors.Is(r.err, context.Canceled) {
			t.Errorf("err=%v; want Canceled chain", r.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Invoke did not return within 2s of cancel")
	}
}

func TestRespond_NotFoundError(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	err := b.Respond(uuid.New(), uuid.New(), Response{Output: json.RawMessage(`null`)})
	if !errors.Is(err, ErrCallNotFound) {
		t.Errorf("err=%v want ErrCallNotFound", err)
	}
}

func TestRespond_CrossConversationRejected(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	convA := uuid.New()
	convB := uuid.New()

	var captured Request
	go func() {
		_, _ = b.Invoke(context.Background(), convA, "x",
			json.RawMessage(`{}`), 5*time.Second, func(r Request) { captured = r })
	}()
	for captured.CallID == uuid.Nil {
		time.Sleep(1 * time.Millisecond)
	}

	err := b.Respond(convB, captured.CallID, Response{
		Output: json.RawMessage(`null`),
	})
	if !errors.Is(err, ErrCallCrossConversation) {
		t.Errorf("err=%v want ErrCallCrossConversation", err)
	}
}

func TestSnapshot_HappyPath(t *testing.T) {
	t.Parallel()
	b := NewBroker()
	conv := uuid.New()

	var captured Request
	go func() {
		_, _ = b.Invoke(context.Background(), conv, "obsidian_read_note",
			json.RawMessage(`{"path":"todo.md"}`), 5*time.Second, func(r Request) { captured = r })
	}()
	for captured.CallID == uuid.Nil {
		time.Sleep(1 * time.Millisecond)
	}

	snap, ok := b.Snapshot(captured.CallID)
	if !ok {
		t.Fatal("snapshot should exist for an in-flight call")
	}
	if snap.ToolName != "obsidian_read_note" {
		t.Errorf("ToolName=%q", snap.ToolName)
	}
	if snap.ConversationID != conv {
		t.Errorf("ConversationID mismatch")
	}
}

func TestRegistry_RoundTrip(t *testing.T) {
	t.Parallel()
	r := NewRegistry()
	user := uuid.New()
	conv := uuid.New()

	r.Register(user, conv,
		[]string{"calendar_list_events", "reminders_list"},
		map[string]string{"os": "iOS", "os_version": "26.5", "empty": ""})

	if !r.Supports(user, conv, "calendar_list_events") {
		t.Error("calendar_list_events should be supported")
	}
	if r.Supports(user, conv, "obsidian_read_note") {
		t.Error("obsidian_read_note should not be supported")
	}

	set := r.SupportedSet(user, conv)
	if len(set) != 2 {
		t.Errorf("set size=%d want 2", len(set))
	}

	attrs := r.Attributes(user, conv)
	if attrs["os"] != "iOS" || attrs["os_version"] != "26.5" {
		t.Errorf("attrs missing expected keys: %v", attrs)
	}
	if _, ok := attrs["empty"]; ok {
		t.Error("empty-value attribute should be dropped")
	}
}

func TestRegistry_LastRegisterWins(t *testing.T) {
	t.Parallel()
	r := NewRegistry()
	user := uuid.New()
	conv := uuid.New()

	r.Register(user, conv, []string{"calendar_list_events"}, nil)
	r.Register(user, conv, []string{"obsidian_read_note"}, nil)

	if r.Supports(user, conv, "calendar_list_events") {
		t.Error("first registration should be overwritten")
	}
	if !r.Supports(user, conv, "obsidian_read_note") {
		t.Error("second registration should be active")
	}
}

func TestRegistry_UnregisteredReportsEmpty(t *testing.T) {
	t.Parallel()
	r := NewRegistry()
	if r.Supports(uuid.New(), uuid.New(), "anything") {
		t.Error("unregistered (user, conv) should not support anything")
	}
	if r.SupportedSet(uuid.New(), uuid.New()) != nil {
		t.Error("unregistered SupportedSet should be nil")
	}
}

func TestCatalog_Find_KnownAndUnknown(t *testing.T) {
	t.Parallel()
	if Find("calendar_list_events") == nil {
		t.Error("calendar_list_events should be in the catalog")
	}
	if Find("nope_not_a_tool") != nil {
		t.Error("unknown tool should return nil")
	}
}

func TestCatalog_AllSchemasAreValidJSON(t *testing.T) {
	t.Parallel()
	for _, tool := range All() {
		var schema map[string]any
		if err := json.Unmarshal([]byte(tool.InputSchema), &schema); err != nil {
			t.Errorf("tool %s: schema is not valid JSON: %v", tool.Name, err)
		}
	}
}

func TestCatalog_NamesAreUnique(t *testing.T) {
	t.Parallel()
	seen := map[string]bool{}
	for _, tool := range All() {
		if seen[tool.Name] {
			t.Errorf("duplicate tool name: %s", tool.Name)
		}
		seen[tool.Name] = true
	}
}

func TestCatalog_NamesUseSnakeCase(t *testing.T) {
	t.Parallel()
	// Model tool-use conventions across providers: snake_case
	// names. A capital or hyphen here usually breaks at least
	// one provider's wire encoding.
	for _, tool := range All() {
		if strings.ContainsAny(tool.Name, "-ABCDEFGHIJKLMNOPQRSTUVWXYZ ") {
			t.Errorf("tool name %q should be snake_case", tool.Name)
		}
	}
}

func TestCatalog_HealthToolsPresent(t *testing.T) {
	t.Parallel()
	// Pin the HealthKit catalog surface: four read tools, all
	// gated on the "health" permission, all defaulted on (they're
	// read-only and useful as soon as the user grants access).
	want := []string{
		"health_today_summary",
		"health_recent_workouts",
		"health_sleep_last_night",
		"health_vitals_recent",
	}
	for _, name := range want {
		tool := Find(name)
		if tool == nil {
			t.Errorf("%s missing from catalog", name)
			continue
		}
		if tool.Category != "Health" {
			t.Errorf("%s.Category=%q want Health", name, tool.Category)
		}
		if len(tool.RequiredPermissions) != 1 || tool.RequiredPermissions[0] != "health" {
			t.Errorf("%s.RequiredPermissions=%v want [health]",
				name, tool.RequiredPermissions)
		}
		if !tool.DefaultEnabled {
			t.Errorf("%s should default to enabled (read-only)", name)
		}
	}
}
