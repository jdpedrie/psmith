package plugins

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func newObsidianForTest(t *testing.T, configJSON string) *obsidian {
	t.Helper()
	pl, err := newObsidian(json.RawMessage(configJSON))
	if err != nil {
		t.Fatalf("newObsidian: %v", err)
	}
	return pl.(*obsidian)
}

func TestObsidian_Descriptor(t *testing.T) {
	t.Parallel()
	p := newObsidianForTest(t, "")
	if p.Name() != ObsidianName {
		t.Errorf("Name=%q", p.Name())
	}
	if p.DisplayName() == "" || p.Description() == "" {
		t.Error("DisplayName/Description must be non-empty")
	}
	cfg := Plugin(p).(Configurable)
	if len(cfg.ConfigFields()) != len(obsidianCatalog) {
		t.Errorf("ConfigFields=%d want %d", len(cfg.ConfigFields()), len(obsidianCatalog))
	}
	tp := Plugin(p).(ToolProvider)
	tools := tp.Tools()
	// Default config: read-only tools on, write tools off.
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	if !names["obsidian_read_note"] || !names["obsidian_list_notes"] || !names["obsidian_search_text"] {
		t.Errorf("expected read-only tools enabled by default; got %v", names)
	}
	if names["obsidian_append_note"] || names["obsidian_create_note"] {
		t.Errorf("write tools should default off; got %v", names)
	}
}

func TestObsidian_ConfigOverridesDefault(t *testing.T) {
	t.Parallel()
	p := newObsidianForTest(t,
		`{"enabled":{"obsidian_append_note":true,"obsidian_read_note":false}}`)
	tools := p.Tools()
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	if names["obsidian_read_note"] {
		t.Error("explicit false should disable read")
	}
	if !names["obsidian_append_note"] {
		t.Error("explicit true should enable append")
	}
}

func TestObsidian_ExecuteTool_HappyPath(t *testing.T) {
	t.Parallel()
	stub := &stubDeviceToolBroker{resp: json.RawMessage(`{"notes":[]}`)}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newObsidianForTest(t, "")
	res, err := p.ExecuteTool(ctx, "obsidian_list_notes", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if string(res.Output) != `{"notes":[]}` {
		t.Errorf("Output=%s", res.Output)
	}
	if stub.lastTool != "obsidian_list_notes" {
		t.Errorf("broker called with %q", stub.lastTool)
	}
}

func TestObsidian_ExecuteTool_NoBookmarkSurfacesFriendlyError(t *testing.T) {
	t.Parallel()
	// Client connected but hasn't bookmarked a vault — registry
	// reports an empty supported set for obsidian_*. The plugin
	// should report a clear "open Settings → Obsidian" message
	// the model can relay.
	stub := &stubDeviceToolBroker{
		supportedNames: map[string]struct{}{"calendar_list_events": {}},
	}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newObsidianForTest(t, "")
	_, err := p.ExecuteTool(ctx, "obsidian_list_notes", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "Settings → Obsidian") {
		t.Errorf("want friendly bookmark error, got %v", err)
	}
}

func TestObsidian_ExecuteTool_DisabledRejected(t *testing.T) {
	t.Parallel()
	p := newObsidianForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "obsidian_append_note",
		json.RawMessage(`{"path":"x.md","content":"y"}`))
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Errorf("want disabled error, got %v", err)
	}
}

func TestObsidian_ExecuteTool_UnknownToolRejected(t *testing.T) {
	t.Parallel()
	p := newObsidianForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "obsidian_nope", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("want unknown-tool error, got %v", err)
	}
}
