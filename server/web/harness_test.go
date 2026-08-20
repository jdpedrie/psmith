package web

import (
	"context"
	"strings"
	"testing"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The web client renders from templ fragments rather than a view model a test
// can inspect, so these render the fragments directly. What they pin is the
// decision, not the styling: whether the attach control exists at all, and
// whether the picker says why a provider is missing.

// An unbound conversation keeps the paperclip.
func TestComposer_UnboundKeepsAttachControl(t *testing.T) {
	t.Parallel()
	html := renderComp(context.Background(), composer("conv-1", pickerModelVM{Value: "p|m", DisplayName: "Opus"}, nil))
	if !strings.Contains(html, "composer-attach") {
		t.Error("attach control missing from an unbound conversation's composer")
	}
	if !strings.Contains(html, `id="composer-file"`) {
		t.Error("file input missing from an unbound conversation's composer")
	}
}

// A harness conversation loses it outright rather than showing a control that
// errors on submit.
func TestComposer_BoundDropsAttachControl(t *testing.T) {
	t.Parallel()
	h := &harnessVM{
		ProviderID:    "prov-1",
		ProviderLabel: "Codex",
		DriverType:    "codex-app-server",
		FrozenPrompt:  true,
		NoAttachments: true,
	}
	html := renderComp(context.Background(), composer("conv-1", pickerModelVM{Value: "p|m", DisplayName: "GPT"}, h))
	if strings.Contains(html, "composer-attach") {
		t.Error("attach control rendered for a conversation that cannot receive attachments")
	}
	if strings.Contains(html, `id="composer-file"`) {
		t.Error("file input rendered for a conversation that cannot receive attachments")
	}
	// The rest of the composer must be intact — this removes one control, not
	// the ability to talk.
	if !strings.Contains(html, "composer-send") {
		t.Error("send button went missing along with the attach control")
	}
}

// A harness that grows file support gets the control back with no code change.
func TestComposer_BoundWithFileSupportKeepsAttachControl(t *testing.T) {
	t.Parallel()
	h := &harnessVM{ProviderID: "prov-1", ProviderLabel: "Codex", NoAttachments: false}
	html := renderComp(context.Background(), composer("conv-1", pickerModelVM{Value: "p|m"}, h))
	if !strings.Contains(html, "composer-attach") {
		t.Error("attach control withheld from a harness that accepts attachments")
	}
}

// A shorter model list must read as a rule rather than as missing data.
func TestModelPickerList_ShowsTheBindingNotice(t *testing.T) {
	t.Parallel()
	data := pickerData{
		ConvID: "conv-1",
		Total:  1,
		Notice: "Codex holds this conversation's transcript, so it stays on this provider.",
		Groups: []providerGroupVM{{
			ProviderID: "prov-1",
			Label:      "Codex",
			Models:     []pickerModelVM{{Value: "prov-1|gpt", DisplayName: "GPT"}},
		}},
	}
	html := renderComp(context.Background(), modelPickerList(data))
	if !strings.Contains(html, "harness-notice") {
		t.Error("no notice rendered above a list the binding shortened")
	}
	if !strings.Contains(html, "stays on this provider") {
		t.Errorf("notice text missing from the picker: %s", html)
	}
}

func TestModelPickerList_NoNoticeWhenUnbound(t *testing.T) {
	t.Parallel()
	data := pickerData{ConvID: "conv-1", Total: 1, Groups: []providerGroupVM{{
		ProviderID: "prov-1", Label: "Anthropic",
		Models: []pickerModelVM{{Value: "prov-1|opus", DisplayName: "Opus"}},
	}}}
	html := renderComp(context.Background(), modelPickerList(data))
	if strings.Contains(html, "harness-notice") {
		t.Error("an unbound conversation's picker carried a notice")
	}
}

// The settings card is where all three constraints are explained together.
func TestHarnessCard_ListsEveryActiveConstraint(t *testing.T) {
	t.Parallel()
	full := renderComp(context.Background(), harnessCard(&harnessVM{
		ProviderLabel: "Codex", FrozenPrompt: true, NoAttachments: true,
	}))
	for _, want := range []string{"Codex", "Stays on this provider", "System prompt is fixed", "No attachments"} {
		if !strings.Contains(full, want) {
			t.Errorf("card missing %q", want)
		}
	}

	// Constraints that do not apply are absent, not listed as satisfied.
	partial := renderComp(context.Background(), harnessCard(&harnessVM{
		ProviderLabel: "Codex", FrozenPrompt: false, NoAttachments: false,
	}))
	if strings.Contains(partial, "No attachments") {
		t.Error("card listed an attachment restriction that does not apply")
	}
	if strings.Contains(partial, "System prompt is fixed") {
		t.Error("card listed a frozen prompt that does not apply")
	}
	if !strings.Contains(partial, "Stays on this provider") {
		t.Error("the provider pin applies to every binding and must always be listed")
	}
}

// The view-model conversion is where a nil binding has to stay nil: every
// template guards on it.
func TestHarnessVMFrom(t *testing.T) {
	t.Parallel()
	if harnessVMFrom(nil) != nil {
		t.Fatal("a nil binding produced a non-nil view model")
	}
	got := harnessVMFrom(&psmithv1.HarnessBinding{
		ProviderId:         "prov-1",
		ProviderLabel:      "Codex",
		DriverType:         "codex-app-server",
		SystemPromptFrozen: true,
		AcceptsAttachments: false,
	})
	if got == nil {
		t.Fatal("a present binding produced a nil view model")
	}
	// The proto says what IS accepted; the template asks what is NOT. Getting
	// this inversion wrong would hide the paperclip on every conversation.
	if !got.NoAttachments {
		t.Error("accepts_attachments=false should read as NoAttachments=true")
	}
	if !got.FrozenPrompt {
		t.Error("system_prompt_frozen did not survive conversion")
	}
	if got.ProviderLabel != "Codex" {
		t.Errorf("provider label = %q", got.ProviderLabel)
	}
}
