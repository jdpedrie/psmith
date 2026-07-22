package plugins

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func newFilesForTest(t *testing.T, configJSON string) *files {
	t.Helper()
	pl, err := newFiles(json.RawMessage(configJSON))
	if err != nil {
		t.Fatalf("newFiles: %v", err)
	}
	return pl.(*files)
}

func TestFiles_Descriptor(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t, "")
	if p.Name() != FilesName {
		t.Errorf("Name=%q", p.Name())
	}
	if p.DisplayName() == "" || p.Description() == "" {
		t.Error("DisplayName/Description must be non-empty")
	}
	cfg := Plugin(p).(Configurable)
	if len(cfg.ConfigFields()) != len(filesCatalog) {
		t.Errorf("ConfigFields=%d want %d", len(cfg.ConfigFields()), len(filesCatalog))
	}
	tp := Plugin(p).(ToolProvider)
	tools := tp.Tools()
	// Default config: read-only tools on, write tools off.
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	if !names["files_read_note"] || !names["files_list_notes"] || !names["files_search_text"] {
		t.Errorf("expected read-only tools enabled by default; got %v", names)
	}
	if names["files_append_note"] || names["files_create_note"] {
		t.Errorf("write tools should default off; got %v", names)
	}
}

func TestFiles_ConfigOverridesDefault(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t,
		`{"enabled":{"files_append_note":true,"files_read_note":false}}`)
	tools := p.Tools()
	names := map[string]bool{}
	for _, t := range tools {
		names[t.Name] = true
	}
	if names["files_read_note"] {
		t.Error("explicit false should disable read")
	}
	if !names["files_append_note"] {
		t.Error("explicit true should enable append")
	}
}

func TestFiles_ExecuteTool_HappyPath(t *testing.T) {
	t.Parallel()
	stub := &stubDeviceToolBroker{resp: json.RawMessage(`{"notes":[]}`)}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newFilesForTest(t, "")
	res, err := p.ExecuteTool(ctx, "files_list_notes", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("ExecuteTool: %v", err)
	}
	if string(res.Output) != `{"notes":[]}` {
		t.Errorf("Output=%s", res.Output)
	}
	if stub.lastTool != "files_list_notes" {
		t.Errorf("broker called with %q", stub.lastTool)
	}
}

func TestFiles_ExecuteTool_NoBookmarkSurfacesFriendlyError(t *testing.T) {
	t.Parallel()
	// Client connected but hasn't bookmarked a vault — registry
	// reports an empty supported set for files_*. The plugin
	// should report a clear "open Settings → Files" message
	// the model can relay.
	stub := &stubDeviceToolBroker{
		supportedNames: map[string]struct{}{"calendar_list_events": {}},
	}
	ctx := WithDeviceToolBroker(context.Background(), stub)
	p := newFilesForTest(t, "")
	_, err := p.ExecuteTool(ctx, "files_list_notes", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "Settings → Files") {
		t.Errorf("want friendly bookmark error, got %v", err)
	}
}

func TestFiles_ExecuteTool_DisabledRejected(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "files_append_note",
		json.RawMessage(`{"path":"x.md","content":"y"}`))
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Errorf("want disabled error, got %v", err)
	}
}

func TestFiles_ExecuteTool_UnknownToolRejected(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t, "")
	ctx := WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "files_nope", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("want unknown-tool error, got %v", err)
	}
}
