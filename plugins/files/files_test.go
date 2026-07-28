package files

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
)

// Local copy: this stub lived in app_tools_test.go when every plugin
// shared one package. Duplicated rather than exported into a shared test
// helper, so each plugin's tests stand alone.
// stubDeviceToolBroker captures the most recent Invoke for assertions
// and returns a canned response. `supportedNames` controls
// SupportedTools; nil means "no client has registered" so the plugin
// shouldn't gate on it.
type stubDeviceToolBroker struct {
	lastTool       string
	lastInput      json.RawMessage
	resp           json.RawMessage
	err            error
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
	if p.Name() != Name {
		t.Errorf("Name=%q", p.Name())
	}
	if p.DisplayName() == "" || p.Description() == "" {
		t.Error("DisplayName/Description must be non-empty")
	}
	cfg := pluginapi.Plugin(p).(pluginapi.Configurable)
	if len(cfg.ConfigFields()) != len(filesCatalog) {
		t.Errorf("ConfigFields=%d want %d", len(cfg.ConfigFields()), len(filesCatalog))
	}
	tp := pluginapi.Plugin(p).(pluginapi.ToolProvider)
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
	ctx := host.WithDeviceToolBroker(context.Background(), stub)
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
	ctx := host.WithDeviceToolBroker(context.Background(), stub)
	p := newFilesForTest(t, "")
	_, err := p.ExecuteTool(ctx, "files_list_notes", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "Settings → Files") {
		t.Errorf("want friendly bookmark error, got %v", err)
	}
}

func TestFiles_ExecuteTool_DisabledRejected(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t, "")
	ctx := host.WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "files_append_note",
		json.RawMessage(`{"path":"x.md","content":"y"}`))
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Errorf("want disabled error, got %v", err)
	}
}

func TestFiles_ExecuteTool_UnknownToolRejected(t *testing.T) {
	t.Parallel()
	p := newFilesForTest(t, "")
	ctx := host.WithDeviceToolBroker(context.Background(), &stubDeviceToolBroker{})
	_, err := p.ExecuteTool(ctx, "files_nope", json.RawMessage(`{}`))
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("want unknown-tool error, got %v", err)
	}
}
