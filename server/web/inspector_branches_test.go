package web

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"github.com/a-h/templ"
)

func TestBranchRows_ListsEachBranchPointInOrder(t *testing.T) {
	items := []msgItem{
		{ID: "u1", Role: "user", Text: "No siblings here"},
		{ID: "u2", Role: "user", Text: "\n  And the card?\nsecond line", Branch: &branchVM{Index: 2, Count: 2}},
		{ID: "a2", Role: "assistant", Text: "Same reason.", Branch: &branchVM{Index: 2, Count: 3}},
	}
	want := []branchRowVM{
		{Label: "Your message · And the card?", Pos: "2 of 2", Href: "#m-u2"},
		{Label: "Reply · Same reason.", Pos: "2 of 3", Href: "#m-a2"},
	}
	if got := branchRows(items); !reflect.DeepEqual(got, want) {
		t.Errorf("branchRows = %+v, want %+v", got, want)
	}
	if got := branchRows(items[:1]); got != nil {
		t.Errorf("no branches gave %+v", got)
	}
}

// With branches the section takes the keyboard section's place.
func TestContextTab_BranchesReplaceKeyboard(t *testing.T) {
	vm := boardBranches()
	html := renderString(t, contextTab(vm))
	if !strings.Contains(html, "<h2>Branches</h2>") || !strings.Contains(html, `href="#m-a2"`) {
		t.Error("the Branches section is missing")
	}
	if strings.Contains(html, "Keyboard") {
		t.Error("Keyboard still shows beside Branches")
	}
	vm.Inspector.Branches = nil
	if html := renderString(t, contextTab(vm)); !strings.Contains(html, "Keyboard") || strings.Contains(html, "Branches") {
		t.Error("without branches the tab should show Keyboard and no Branches")
	}
}

func renderString(t *testing.T, c templ.Component) string {
	t.Helper()
	var b strings.Builder
	if err := c.Render(context.Background(), &b); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

// A harness conversation's Settings tab explains the binding in place of
// call settings, listing only the rules that apply.
func TestInspector_HarnessPanelTakesSettingsPlace(t *testing.T) {
	vm := boardHarness()
	vm.Inspector.Settings = &callSettingsVM{ConvID: vm.ID}
	vm.Harness.NoAttachments = false
	html := renderString(t, inspector(vm))
	for _, want := range []string{"Claude Code binding", "Stays on this provider", "System prompt is fixed", `href="/new?profile=p-demo"`} {
		if !strings.Contains(html, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(html, "No attachments") {
		t.Error("No attachments shows for a binding that allows them")
	}
	if strings.Contains(html, `id="insp-settings"`) {
		t.Error("call settings render beside the harness panel")
	}
}
