package web

import (
	"context"
	"strings"
	"testing"
)

// The web client renders from templ fragments, so these render the fragments
// directly. What they pin is the decision, not the styling: whether the
// attach control exists at all, and whether the screen says why a provider
// or a control is missing.

func composerHTML(h *harnessVM) string {
	return renderComp(context.Background(), composer2(convVM{ID: "conv-1", Harness: h, Placeholder: "Message Demo",
		Model: modelChipVM{Value: "p|m", Name: "Opus"}}))
}

// An unbound conversation keeps the paperclip.
func TestComposer_UnboundKeepsAttachControl(t *testing.T) {
	t.Parallel()
	if html := composerHTML(nil); !strings.Contains(html, `type="file"`) {
		t.Error("attach control missing from an unbound conversation's composer")
	}
}

// A harness conversation loses it outright rather than showing a control that
// errors on submit; the rest of the composer stays.
func TestComposer_BoundDropsAttachControl(t *testing.T) {
	t.Parallel()
	html := composerHTML(&harnessVM{ProviderID: "prov-1", ProviderLabel: "Codex", DriverType: "codex-app-server", FrozenPrompt: true, NoAttachments: true})
	if strings.Contains(html, `type="file"`) {
		t.Error("attach control rendered for a conversation that cannot receive attachments")
	}
	if !strings.Contains(html, `name="message"`) {
		t.Error("the message field went missing along with the attach control")
	}
}

// A harness that grows file support gets the control back with no code change.
func TestComposer_BoundWithFileSupportKeepsAttachControl(t *testing.T) {
	t.Parallel()
	if html := composerHTML(&harnessVM{ProviderID: "prov-1", ProviderLabel: "Codex"}); !strings.Contains(html, `type="file"`) {
		t.Error("attach control withheld from a harness that accepts attachments")
	}
}

// A shorter model list must read as a rule rather than as missing data.
func TestPicker_ShowsTheBindingNotice(t *testing.T) {
	t.Parallel()
	p := &pickerVM{ConvID: "conv-1", Notice: "Codex holds this conversation's transcript, so it stays on this provider.",
		Groups: []providerGroupVM{{ProviderID: "prov-1", Label: "Codex", Models: []pickerModelVM{{Value: "prov-1|gpt", DisplayName: "GPT"}}}}}
	html := renderComp(context.Background(), pickerView(convVM{ID: "conv-1"}, p))
	if !strings.Contains(html, "stays on this provider") {
		t.Errorf("notice text missing from the picker: %s", html)
	}
}

func TestPicker_NoNoticeWhenUnbound(t *testing.T) {
	t.Parallel()
	p := &pickerVM{ConvID: "conv-1", Groups: []providerGroupVM{{ProviderID: "prov-1", Label: "Anthropic",
		Models: []pickerModelVM{{Value: "prov-1|opus", DisplayName: "Opus"}}}}}
	if html := renderComp(context.Background(), pickerView(convVM{ID: "conv-1"}, p)); strings.Contains(html, "pick-notice") {
		t.Error("an unbound conversation's picker carried a notice")
	}
}

// The strip names every constraint that applies and none that don't.
func TestHarnessNote_ListsEveryActiveConstraint(t *testing.T) {
	t.Parallel()
	full := harnessNote(&harnessVM{ProviderLabel: "Codex", FrozenPrompt: true, NoAttachments: true})
	for _, want := range []string{"Codex", "system prompt fixed", "no attachments"} {
		if !strings.Contains(full, want) {
			t.Errorf("note missing %q: %s", want, full)
		}
	}
	partial := harnessNote(&harnessVM{ProviderLabel: "Codex"})
	if strings.Contains(partial, "no attachments") || strings.Contains(partial, "system prompt fixed") {
		t.Errorf("note listed a constraint that does not apply: %s", partial)
	}
}
