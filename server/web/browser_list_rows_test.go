package web

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"
)

// listTitle reads a conversation's title from the database.
func (e *browserEnv) listTitle(t *testing.T, id string) string {
	t.Helper()
	c, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(id))
	if err != nil {
		return "<gone>"
	}
	if c.Title == nil {
		return ""
	}
	return *c.Title
}

// listOpenMenu opens a row's more menu with a real click.
func (e *browserEnv) listOpenMenu(t *testing.T, id string) {
	t.Helper()
	sel := `[data-row="` + id + `"] .rmore > summary`
	e.keys(t, chromedp.Evaluate(`document.querySelector('[data-row="`+id+`"]').classList.add('hover')`, nil), chromedp.Click(sel, chromedp.ByQuery))
	waitUntil(t, e, "menu open", `!!document.querySelector('[data-row="`+id+`"] .rmore[open]')`, 3*time.Second)
}

// Rename from the row menu: the row becomes a field with the title
// selected, Enter saves, and the list shows the new title.
func TestBrowser_ListRenameFromMenu(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Old title")
	e.open(t, "/chats")
	e.listOpenMenu(t, id)
	e.keys(t, chromedp.Click(`[data-row="`+id+`"] .rmenu a[role="menuitem"]`, chromedp.ByQuery))
	waitUntil(t, e, "rename field focused", `document.activeElement && document.activeElement.id === 'rename'`, 3*time.Second)
	e.keys(t, chromedp.KeyEvent("New title"), chromedp.KeyEvent(kb.Enter))
	waitUntil(t, e, "renamed in list", `document.getElementById('rows').innerText.includes('New title') && !document.getElementById('rename')`, 5*time.Second)
	if got := e.listTitle(t, id); got != "New title" {
		t.Errorf("title in the database = %q", got)
	}
}

// Esc leaves a rename without saving and puts the row back.
func TestBrowser_ListRenameEscCancels(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Keep me")
	e.open(t, "/chats?renaming="+id)
	waitUntil(t, e, "rename field focused", `document.activeElement && document.activeElement.id === 'rename'`, 3*time.Second)
	e.keys(t, chromedp.KeyEvent("Typed"), shortcut("Escape", "Escape"))
	waitUntil(t, e, "row back", `!document.getElementById('rename') && !!document.querySelector('[data-row="`+id+`"] a.row')`, 5*time.Second)
	if got := e.listTitle(t, id); got != "Keep me" {
		t.Errorf("Esc saved the title: %q", got)
	}
}

// Delete from the row menu asks in place; Delete removes it.
func TestBrowser_ListDeleteInPlace(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Doomed")
	e.open(t, "/chats")
	e.listOpenMenu(t, id)
	e.keys(t, chromedp.Click(`[data-row="`+id+`"] .rmenu a.danger`, chromedp.ByQuery))
	waitUntil(t, e, "confirm", `!!document.querySelector('.ritem.confirm')`, 3*time.Second)
	if !strings.Contains(eval[string](t, e, `document.querySelector('.ritem.confirm').innerText`), "Delete “Doomed”?") {
		t.Error("confirm doesn't name the conversation")
	}
	e.keys(t, chromedp.Click(`.ritem.confirm button.destructive`, chromedp.ByQuery))
	waitUntil(t, e, "gone", `!document.getElementById('rows').innerText.includes('Doomed')`, 5*time.Second)
	if got := e.listTitle(t, id); got != "<gone>" {
		t.Errorf("conversation still in the database: %q", got)
	}
}

// Pin from the row menu moves the row under Pinned without a reload.
func TestBrowser_ListPinFromMenu(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Pin me")
	e.open(t, "/chats")
	e.listOpenMenu(t, id)
	e.keys(t, chromedp.Click(`[data-row="`+id+`"] .rmenu form:nth-of-type(1) button`, chromedp.ByQuery))
	waitUntil(t, e, "pinned head", `(document.querySelector('#rows .group-head') || {}).innerText === 'Pinned' && !!document.querySelector('[data-row="`+id+`"] .row-time.pinned')`, 5*time.Second)
}

// Select many: X enters it, ticking counts, Delete asks in the toolbar, and
// Delete deletes exactly the ticked ones.
func TestBrowser_ListSelectAndDelete(t *testing.T) {
	e := newBrowserEnv(t)
	a := e.addConversation(t, "Alpha")
	b := e.addConversation(t, "Bravo")
	c := e.addConversation(t, "Charlie")
	e.open(t, "/chats")
	e.keys(t, chromedp.Evaluate(`document.activeElement && document.activeElement.blur()`, nil), shortcut("x", "KeyX"))
	waitUntil(t, e, "select mode", `!!document.querySelector('#list[data-select]')`, 5*time.Second)
	e.keys(t,
		chromedp.Click(`input[name="id"][value="`+a+`"] + .check`, chromedp.ByQuery),
		chromedp.Click(`input[name="id"][value="`+b+`"] + .check`, chromedp.ByQuery),
	)
	if got := eval[string](t, e, `document.querySelector('[data-sel-count]').innerText`); got != "2 selected" {
		t.Errorf("count = %q, want 2 selected", got)
	}
	e.keys(t, chromedp.Click(`#bulk button.redfill`, chromedp.ByQuery))
	waitUntil(t, e, "confirm", `!!document.querySelector('.selbar-q')`, 5*time.Second)
	if got := eval[string](t, e, `document.querySelector('.selbar-q').innerText`); got != "Delete 2?" {
		t.Errorf("confirm reads %q", got)
	}
	e.keys(t, chromedp.Click(`#bulk button.destructive`, chromedp.ByQuery))
	waitUntil(t, e, "back to list", `!document.querySelector('#list[data-select]') && document.readyState === 'complete'`, 5*time.Second)
	if e.listTitle(t, a) != "<gone>" || e.listTitle(t, b) != "<gone>" {
		t.Error("a ticked conversation survived")
	}
	if e.listTitle(t, c) != "Charlie" {
		t.Error("an unticked conversation was deleted")
	}
}

// Show more appends the next page under the first.
func TestBrowser_ListShowMore(t *testing.T) {
	e := newBrowserEnv(t)
	for i := 0; i < 101; i++ {
		e.addConversation(t, "Bulk conversation")
	}
	e.open(t, "/chats")
	before := eval[float64](t, e, `document.querySelectorAll('#rows a.row').length`)
	e.keys(t, chromedp.Click(`#rows .more-rows`, chromedp.ByQuery))
	waitUntil(t, e, "more rows", fmt.Sprintf(`document.querySelectorAll('#rows a.row').length > %d`, int(before)), 5*time.Second)
	if eval[bool](t, e, `!!document.querySelector('#rows .more-rows')`) {
		t.Error("Show more stayed after the last page")
	}
}

// The bulk delete confirm is a URL like every other state: reloading it
// shows the same confirm rather than re-posting a form.
func TestBrowser_ListBulkConfirmIsAURL(t *testing.T) {
	e := newBrowserEnv(t)
	a := e.addConversation(t, "Alpha")
	e.open(t, "/chats?select=1")
	e.keys(t, chromedp.Click(`input[name="id"][value="`+a+`"] + .check`, chromedp.ByQuery), chromedp.Click(`#bulk button.redfill`, chromedp.ByQuery))
	waitUntil(t, e, "confirm", `!!document.querySelector('.selbar-q') && document.readyState === 'complete'`, 5*time.Second)
	if p := eval[string](t, e, `location.pathname`); p != "/chats" {
		t.Fatalf("confirm sits at %s, a POST target", p)
	}
	e.keys(t, chromedp.Reload())
	waitUntil(t, e, "confirm after reload", `!!document.querySelector('.selbar-q') && document.querySelector('.selbar-q').innerText === 'Delete 1?'`, 5*time.Second)
	if !eval[bool](t, e, `document.querySelector('input[name="id"][value="`+a+`"]').checked`) {
		t.Error("the ticked row lost its tick")
	}
}
