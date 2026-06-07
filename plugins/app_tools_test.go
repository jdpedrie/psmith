package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// stubDeviceToolBroker captures the most recent Invoke for assertions
// and returns a canned response. `supportedNames` controls
// SupportedTools; nil means "no client has registered" so the plugin
// shouldn't gate on it.
type stubDeviceToolBroker struct {
	lastTool     string
	lastInput    json.RawMessage
	resp         json.RawMessage
	err          error
	supportedNames map[string]struct{}
}

func (s *stubDeviceToolBroker) Invoke(_ context.Context, toolName string, input json.RawMessage) (json.RawMessage, error) {
	s.lastTool = toolName
	s.lastInput = input
	if s.err != nil {
		return nil, s.err
	}
	return s.resp, nil
}

func (s *stubDeviceToolBroker) SupportedTools(_ context.Context) map[string]struct{} {
	return s.supportedNames
}

func newAppToolsForTest(t *testing.T, configJSON string) *appTools {
	t.Helper()
	pl, err := newAppTools(json.RawMessage(configJSON))
	if err != nil {
		t.Fatalf("newAppTools: %v", err)
	}
	return pl.(*appTools)
}

func TestAppTools_Descriptor(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, "")
	if p.Name() != AppToolsName {
		t.Errorf("Name=%q", p.Name())
	}
	if p.DisplayName() == "" || p.Description() == "" {
		t.Error("DisplayName/Description must be non-empty")
	}

	cfg, ok := Plugin(p).(Configurable)
	if !ok {
		t.Fatal("app_tools must implement Configurable")
	}
	fields := cfg.ConfigFields()
	if len(fields) == 0 {
		t.Error("expected one ConfigField per catalog tool, got 0")
	}

	tp, ok := Plugin(p).(ToolProvider)
	if !ok {
		t.Fatal("app_tools must implement ToolProvider")
	}
	// Default config: only tools with DefaultEnabled=true should show up.
	if len(tp.Tools()) == 0 {
		t.Error("expected some tools enabled by default (read-only ops should be on)")
	}
}

func TestAppTools_DefaultEnableMatchesCatalog(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, "")
	tools := p.Tools()
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	// Catalog says calendar_list_events defaults on; calendar_create_event
	// defaults off. The plugin should match.
	if !names["calendar_list_events"] {
		t.Error("calendar_list_events should be enabled by default")
	}
	if names["calendar_create_event"] {
		t.Error("calendar_create_event should be disabled by default")
	}
}

func TestAppTools_ConfigOverridesCatalogDefault(t *testing.T) {
	t.Parallel()
	// Flip: enable create, disable list.
	p := newAppToolsForTest(t, `{"enabled":{"calendar_create_event":true,"calendar_list_events":false}}`)
	tools := p.Tools()
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	if names["calendar_list_events"] {
		t.Error("explicit false in config should disable the tool")
	}
	if !names["calendar_create_event"] {
		t.Error("explicit true in config should enable the tool")
	}
}

func TestAppTools_ToolsForClientIntersectsSupported(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, `{"enabled":{"calendar_list_events":true,"obsidian_read_note":true,"reminders_list":true}}`)
	// Client supports only calendar_list_events.
	supported := map[string]struct{}{"calendar_list_events": {}}
	tools := p.ToolsForClient(supported)
	if len(tools) != 1 || tools[0].Name != "calendar_list_events" {
		t.Errorf("filtered tools=%v want [calendar_list_events]", tools)
	}
}

func TestAppTools_ToolsForClientNilSupportedFallsBackToTools(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, "")
	if len(p.ToolsForClient(nil)) != len(p.Tools()) {
		t.Error("nil supported set should fall back to Tools() unfiltered")
	}
}

func TestAppTools_ExecuteTool_HappyPath(t *testing.T) {
	t.Parallel()
	stub := &stubDeviceToolBroker{resp: json.RawMessage(`{"events":[]}`)}
	ctx := WithDeviceToolBroker(context.Background(), stub)

	p := newAppToolsForTest(t, "")
	res, err := p.ExecuteTool(ctx, "calendar_list_events",
		json.RawMessage(`{"start_date":"2026-06-07","end_date":"2026-06-08"}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if string(res.Output) != `{"events":[]}` {
		t.Errorf("Output=%s", res.Output)
	}
	if stub.lastTool != "calendar_list_events" {
		t.Errorf("broker.lastTool=%q", stub.lastTool)
	}
}

func TestAppTools_ExecuteTool_UnknownToolErrors(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "not_a_tool", nil)
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("want unknown-tool error, got %v", err)
	}
}

func TestAppTools_ExecuteTool_DisabledToolErrors(t *testing.T) {
	t.Parallel()
	// calendar_create_event defaults off and we don't enable it.
	p := newAppToolsForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "calendar_create_event", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Errorf("want disabled error, got %v", err)
	}
}

func TestAppTools_ExecuteTool_NoBrokerErrors(t *testing.T) {
	t.Parallel()
	p := newAppToolsForTest(t, "")
	_, err := p.ExecuteTool(context.Background(), "calendar_list_events", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "no DeviceToolBroker") {
		t.Errorf("want no-broker error, got %v", err)
	}
}

func TestAppTools_ExecuteTool_UnsupportedToolErrors(t *testing.T) {
	t.Parallel()
	// Client says it only supports reminders_list, but model calls
	// calendar_list_events (which is enabled).
	stub := &stubDeviceToolBroker{
		supportedNames: map[string]struct{}{"reminders_list": {}},
	}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newAppToolsForTest(t, "")
	_, err := p.ExecuteTool(ctx, "calendar_list_events", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "not supported by the connected device") {
		t.Errorf("want unsupported error, got %v", err)
	}
}

func TestAppTools_ExecuteTool_BrokerErrorPropagates(t *testing.T) {
	t.Parallel()
	stub := &stubDeviceToolBroker{err: errors.New("calendar permission denied")}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newAppToolsForTest(t, "")
	_, err := p.ExecuteTool(ctx, "calendar_list_events", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("want propagated error, got %v", err)
	}
}
