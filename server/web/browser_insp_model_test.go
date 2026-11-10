package web

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// inspAddModel enables another model on the fake provider.
func (e *browserEnv) inspAddModel(t *testing.T, id, name string) {
	t.Helper()
	if _, err := e.q.UpsertUserModel(context.Background(), store.UpsertUserModelParams{
		UserModelProviderID: uuid.MustParse(e.providerID), ModelID: id, DisplayName: name,
		MetadataSource: "manual", MetadataSnapshotAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
}

// The model picker: M opens it with the cursor in search, typing filters,
// Enter picks the first match and writes it to the conversation; "Use the
// profile's model" clears it again. The profile names a model, since
// without one that row has nothing to use and is disabled.
func TestBrowser_InspModelPickerPickAndClear(t *testing.T) {
	e := newBrowserEnv(t)
	e.inspAddModel(t, "claude-other", "Claude Other")
	conv, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	defaults := fmt.Sprintf(`{"default_provider_id":%q,"default_model_id":"claude-fake"}`, e.providerID)
	if err := e.q.UpdateProfileDefaultSettings(context.Background(), store.UpdateProfileDefaultSettingsParams{ID: conv.ProfileID, DefaultSettings: []byte(defaults)}); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/c/"+e.convID)
	e.keys(t, chromedp.Evaluate(`document.activeElement && document.activeElement.blur()`, nil), shortcut("m", "KeyM"))
	inspWaitPath(t, e, "/c/"+e.convID+"/model")
	waitUntil(t, e, "search focused", `document.activeElement && document.activeElement.hasAttribute('data-pick-filter')`, 3*time.Second)

	e.keys(t, chromedp.SendKeys(`[data-pick-filter]`, "other", chromedp.ByQuery))
	waitUntil(t, e, "filtered", `[...document.querySelectorAll('.pick-body .pick-row[data-pick-name]')].filter(r => !r.hidden).length === 1`, 2*time.Second)
	e.inspShot(t, "filtered")
	e.keys(t, shortcut("Enter", "Enter"))
	inspWaitPath(t, e, "/c/"+e.convID)
	s := e.inspConvSettings(t)
	if s.GetDefaultModelId() != "claude-other" || s.GetDefaultProviderId() != e.providerID {
		t.Fatalf("model after picking = %s|%s", s.GetDefaultProviderId(), s.GetDefaultModelId())
	}
	if got := inspText(t, e, "#conv-head"); !strings.Contains(got, "Claude Other") {
		t.Errorf("the header doesn't show the picked model: %q", got)
	}

	// Back to the profile's model.
	e.open(t, "/c/"+e.convID+"/model")
	e.inspClick(t, `.pick-body button.pick-row[value=""]`)
	inspWaitPath(t, e, "/c/"+e.convID)
	if s := e.inspConvSettings(t); s.DefaultModelId != nil {
		t.Errorf("the conversation still sets %s after Use the profile's model", s.GetDefaultModelId())
	}
}

// Arrow keys move through the rows from the search field, and Esc leaves the
// picker without changing anything.
func TestBrowser_InspModelPickerKeys(t *testing.T) {
	e := newBrowserEnv(t)
	e.inspAddModel(t, "claude-other", "Claude Other")
	e.open(t, "/c/"+e.convID+"/model")
	waitUntil(t, e, "search focused", `document.activeElement && document.activeElement.hasAttribute('data-pick-filter')`, 3*time.Second)
	e.keys(t, shortcut("ArrowDown", "ArrowDown"))
	if !eval[bool](t, e, `document.activeElement.classList.contains('pick-row')`) {
		t.Fatal("↓ from search didn't move to the first row")
	}
	e.keys(t, shortcut("ArrowDown", "ArrowDown"))
	second := eval[string](t, e, `document.activeElement.getAttribute('data-pick-name') || document.activeElement.innerText`)
	e.keys(t, shortcut("ArrowUp", "ArrowUp"), shortcut("ArrowUp", "ArrowUp"))
	if !eval[bool](t, e, `document.activeElement.hasAttribute('data-pick-filter')`) {
		t.Error("↑ from the first row didn't go back to search")
	}
	if second == "" {
		t.Error("↓ twice landed nowhere")
	}
	e.keys(t, shortcut("ArrowDown", "ArrowDown"), shortcut("Escape", "Escape"))
	inspWaitPath(t, e, "/c/"+e.convID)
	if s := e.inspConvSettings(t); s.DefaultModelId != nil {
		t.Errorf("Esc changed the model to %s", s.GetDefaultModelId())
	}
	// Esc in the search field clears what's typed first, then leaves, the
	// way it does from a row.
	e.open(t, "/c/"+e.convID+"/model")
	waitUntil(t, e, "search focused", `document.activeElement && document.activeElement.hasAttribute('data-pick-filter')`, 3*time.Second)
	e.keys(t, chromedp.SendKeys(`[data-pick-filter]`, "zzz", chromedp.ByQuery), shortcut("Escape", "Escape"))
	if v := eval[string](t, e, `document.querySelector('[data-pick-filter]').value`); v != "" {
		t.Errorf("the first Esc left %q in search", v)
	}
	if n := eval[int](t, e, `[...document.querySelectorAll('.pick-body .pick-row')].filter(r => !r.hidden).length`); n < 2 {
		t.Errorf("clearing search left %d rows showing", n)
	}
	e.keys(t, shortcut("Escape", "Escape"))
	end := time.Now().Add(2 * time.Second)
	for time.Now().Before(end) && eval[string](t, e, `location.pathname`) != "/c/"+e.convID {
		time.Sleep(100 * time.Millisecond)
	}
	if p := eval[string](t, e, `location.pathname`); p != "/c/"+e.convID {
		t.Errorf("Esc in the picker's search stayed on %s", p)
	}
}

// Opened from the Settings tab's model card, the picker's back returns to
// the Settings tab, not the Context tab.
func TestBrowser_InspModelPickerBackReturnsToTheTab(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID+"?tab=settings")
	e.inspClick(t, `#inspector a.model-card`)
	inspWaitPath(t, e, "/c/"+e.convID+"/model")
	if got := eval[string](t, e, `document.querySelector('#inspector .insp-back').getAttribute('aria-label')`); got != "Back to Settings" {
		t.Errorf("the back button says %q", got)
	}
	e.inspClick(t, `#inspector .insp-back`)
	inspWaitPath(t, e, "/c/"+e.convID+"?tab=settings")

	// Opened from the header's model chip, back is the conversation.
	e.open(t, "/c/"+e.convID)
	e.open(t, "/c/"+e.convID+"/model")
	if got := eval[string](t, e, `document.querySelector('#inspector .insp-back').getAttribute('href')`); got != "/c/"+e.convID {
		t.Errorf("back from a picker opened on the conversation goes to %q", got)
	}
}
