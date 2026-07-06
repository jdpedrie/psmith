package plugins

import (
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/internal/providers"
)

func buildTextInjector(t *testing.T, configJSON string) *textInjector {
	t.Helper()
	pl, err := newTextInjector([]byte(configJSON))
	if err != nil {
		t.Fatalf("newTextInjector: %v", err)
	}
	ti, ok := pl.(*textInjector)
	if !ok {
		t.Fatalf("expected *textInjector, got %T", pl)
	}
	return ti
}

func TestTextInjector_DefaultsAreNoOps(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, "")
	if got := ti.PrependSystemMessage(); got != "" {
		t.Errorf("default PrependSystemMessage = %q; want empty", got)
	}
	if got := ti.AppendSystemMessage(); got != "" {
		t.Errorf("default AppendSystemMessage = %q; want empty", got)
	}
	in := providers.WireMessage{Role: "user", Content: "hi"}
	out := ti.TransformHistoryMessage(in, HistoryPos{FromHead: 0, FromHeadSameRole: 0})
	if out.Content != in.Content {
		t.Errorf("default transform should be a no-op; got %q", out.Content)
	}
}

func TestTextInjector_InvalidJSONRejected(t *testing.T) {
	t.Parallel()
	if _, err := newTextInjector([]byte(`{not json`)); err == nil {
		t.Fatal("expected error for invalid JSON config")
	}
}

func TestTextInjector_SystemPrefixSuffix(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, `{"system_prefix": "PREFIX", "system_suffix": "SUFFIX"}`)
	if got := ti.PrependSystemMessage(); got != "PREFIX" {
		t.Errorf("PrependSystemMessage = %q; want PREFIX", got)
	}
	if got := ti.AppendSystemMessage(); got != "SUFFIX" {
		t.Errorf("AppendSystemMessage = %q; want SUFFIX", got)
	}
}

func TestTextInjector_SkipsNonUserRoles(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, `{"user_prefix": "PRE", "user_suffix": "POST", "user_head_reminder": "REMIND"}`)
	for _, role := range []string{"system", "assistant", "context"} {
		in := providers.WireMessage{Role: role, Content: "body"}
		out := ti.TransformHistoryMessage(in, HistoryPos{FromHead: 0, FromHeadSameRole: 0})
		if out.Content != in.Content {
			t.Errorf("role %q should pass through; got %q", role, out.Content)
		}
	}
}

func TestTextInjector_UserPrefixSuffixOnEveryUserMessage(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, `{"user_prefix": "PRE", "user_suffix": "POST"}`)
	// pos is a non-head position so the head reminder doesn't fire
	// here; only prefix + suffix should land.
	in := providers.WireMessage{Role: "user", Content: "what time is it"}
	out := ti.TransformHistoryMessage(in, HistoryPos{FromHead: 4, FromHeadSameRole: 2})
	want := "PRE\n\nwhat time is it\n\nPOST"
	if out.Content != want {
		t.Errorf("got %q\nwant %q", out.Content, want)
	}
}

func TestTextInjector_HeadReminderOnlyAtHead(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, `{"user_head_reminder": "[system_reminder do the thing]"}`)
	// Head: reminder appended.
	head := ti.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		HistoryPos{FromHead: 0, FromHeadSameRole: 0},
	)
	if !strings.HasSuffix(head.Content, "[system_reminder do the thing]") {
		t.Errorf("head reminder missing; got %q", head.Content)
	}
	// Older user message: untouched.
	older := ti.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		HistoryPos{FromHead: 4, FromHeadSameRole: 2},
	)
	if older.Content != "ok" {
		t.Errorf("older user message should not get the head reminder; got %q", older.Content)
	}
}

func TestTextInjector_AllUserHooksCompose(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, `{
		"user_prefix": "BEFORE",
		"user_suffix": "AFTER",
		"user_head_reminder": "REMIND"
	}`)
	out := ti.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "body"},
		HistoryPos{FromHead: 0, FromHeadSameRole: 0},
	)
	want := "BEFORE\n\nbody\n\nAFTER\n\nREMIND"
	if out.Content != want {
		t.Errorf("got %q\nwant %q", out.Content, want)
	}
}

func TestTextInjector_ConfigFieldsCoverAllOptions(t *testing.T) {
	t.Parallel()
	ti := buildTextInjector(t, "")
	fields := ti.ConfigFields()
	wantNames := []string{"system_prefix", "system_suffix", "user_prefix", "user_suffix", "user_head_reminder"}
	if len(fields) != len(wantNames) {
		t.Fatalf("expected %d fields, got %d", len(wantNames), len(fields))
	}
	got := make(map[string]bool, len(fields))
	for _, f := range fields {
		got[f.Name] = true
		if f.Type != ConfigFieldTextarea {
			t.Errorf("field %q type = %v; want textarea", f.Name, f.Type)
		}
	}
	for _, n := range wantNames {
		if !got[n] {
			t.Errorf("missing config field %q", n)
		}
	}
}

func TestTextInjector_RegisteredAtInit(t *testing.T) {
	t.Parallel()
	pl, err := Build(TextInjectorName, []byte(`{"system_prefix": "x"}`))
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if _, ok := pl.(SystemPrompter); !ok {
		t.Error("text_injector must implement SystemPrompter")
	}
	if _, ok := pl.(HistoryTransformer); !ok {
		t.Error("text_injector must implement HistoryTransformer")
	}
	if _, ok := pl.(Configurable); !ok {
		t.Error("text_injector must implement Configurable")
	}
}
