package web

import (
	"context"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	"github.com/jdpedrie/psmith/server/store"
)

// listArchive archives a conversation straight in the database.
func (e *browserEnv) listArchive(t *testing.T, id string) {
	t.Helper()
	if err := e.q.SetConversationArchived(context.Background(), store.SetConversationArchivedParams{ID: uuid.MustParse(id), Archived: true}); err != nil {
		t.Fatalf("archive: %v", err)
	}
}

// On a phone there's no hover, so every row shows its more button and the
// menu's items are touch-sized (board PhoneRowMenu). Archive from it works.
func TestBrowser_ListPhoneRowMenu(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Tax documents checklist")
	e.keys(t, chromedp.EmulateViewport(390, 844))
	e.open(t, "/chats")
	more := `[data-row="` + id + `"] .rmore > summary`
	r := e.listRect(t, more)
	if r.Right-r.Left < 44 || r.Bottom-r.Top < 44 {
		t.Fatalf("the more button is %.0f×%.0f, want a 44×44 target showing without hover", r.Right-r.Left, r.Bottom-r.Top)
	}
	if !eval[bool](t, e, `getComputedStyle(document.querySelector('[data-row="`+id+`"] .row-time')).display !== 'none'`) {
		t.Error("the time hides behind the more button")
	}
	e.keys(t, chromedp.Click(more, chromedp.ByQuery))
	waitUntil(t, e, "menu open", `!!document.querySelector('[data-row="`+id+`"] .rmore[open]')`, 3*time.Second)
	if h := eval[float64](t, e, `document.querySelector('[data-row="`+id+`"] .rmenu [role=menuitem]').getBoundingClientRect().height`); h < 44 {
		t.Errorf("menu items are %.0fpx tall, want 44", h)
	}
	m := e.listRect(t, `[data-row="`+id+`"] .rmenu`)
	if m.Left < 0 || m.Right > 390 {
		t.Errorf("the menu spans %.0f–%.0f, off a 390px screen", m.Left, m.Right)
	}
	e.keys(t, chromedp.Click(`[data-row="`+id+`"] .rmenu form[action$="/archive"] button`, chromedp.ByQuery))
	waitUntil(t, e, "archived", `!document.querySelector('[data-row="`+id+`"]')`, 5*time.Second)
	c, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(id))
	if err != nil || c.ArchivedAt == nil {
		t.Errorf("not archived in the database (err %v)", err)
	}
}

// An archived row on a phone shows Unarchive and Delete without hover.
func TestBrowser_ListPhoneArchivedRowActions(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Kubernetes ingress notes")
	e.listArchive(t, id)
	e.keys(t, chromedp.EmulateViewport(390, 844))
	e.open(t, "/chats?f=archived")
	for _, sel := range []string{".unarch", ".rdel"} {
		r := e.listRect(t, `[data-row="`+id+`"] `+sel)
		if r.Bottom-r.Top < 44 {
			t.Errorf("%s is %.0fpx tall without hover, want a 44px target", sel, r.Bottom-r.Top)
		}
	}
	title, del := e.listRect(t, `[data-row="`+id+`"] .row-top b`), e.listRect(t, `[data-row="`+id+`"] .unarch`)
	if title.Right > del.Left {
		t.Errorf("the title runs under Unarchive (%.0f > %.0f)", title.Right, del.Left)
	}
}

// Delete on an archived row confirms in place and deletes.
func TestBrowser_ListArchivedDeleteInPlace(t *testing.T) {
	e := newBrowserEnv(t)
	id := e.addConversation(t, "Doomed archive")
	e.listArchive(t, id)
	e.open(t, "/chats?f=archived")
	e.keys(t, chromedp.Evaluate(`document.querySelector('[data-row="`+id+`"]').classList.add('hover')`, nil))
	waitUntil(t, e, "Delete showing", `(() => { const b = document.querySelector('[data-row="`+id+`"] .rdel'); return !!b && b.getBoundingClientRect().width > 0 })()`, 3*time.Second)
	e.keys(t, chromedp.Click(`[data-row="`+id+`"] .rdel`, chromedp.ByQuery))
	waitUntil(t, e, "confirm", `!!document.querySelector('.ritem.confirm')`, 3*time.Second)
	e.keys(t, chromedp.Click(`.ritem.confirm button.destructive`, chromedp.ByQuery))
	waitUntil(t, e, "gone", `document.readyState === 'complete' && !document.getElementById('rows').innerText.includes('Doomed archive')`, 5*time.Second)
	if got := e.listTitle(t, id); got != "<gone>" {
		t.Errorf("conversation still in the database: %q", got)
	}
}

// A reply that finishes in another conversation while this one is open
// marks that row unread, as the apps do. The test doesn't wait to see the
// row live: the list often never does, which is why the mark follows the
// row's activity time. Opening it clears the mark, and
// the mark doesn't come back.
func TestBrowser_ListUnreadReply(t *testing.T) {
	e := newBrowserEnv(t)
	other := e.addConversation(t, "Council: pricing debate")
	var evs []fakellm.Event
	for i := 0; i < 12; i++ {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: "word ", Delay: 150 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs})
	e.open(t, "/c/"+e.convID)
	waitUntil(t, e, "list ready", `typeof htmx !== 'undefined' && !!document.querySelector('[data-row="`+other+`"]')`, 5*time.Second)
	model := modelValue(e.providerID, "claude-fake")
	e.keys(t, chromedp.Evaluate(`(() => { const f = new FormData(); f.append('message', 'Go'); f.append('model', '`+model+`'); fetch('/c/`+other+`/send', {method: 'POST', body: f}); })()`, nil))
	row := `#rows a.row[data-id="` + other + `"]`
	waitUntil(t, e, "row unread", `!!document.querySelector('`+row+`.unseen:not([data-live]) .row-time .unread[aria-label="Unread reply"]')`, 15*time.Second)
	if eval[bool](t, e, `!!document.querySelector('#rows a.row[data-id="`+e.convID+`"].unseen')`) {
		t.Error("the open conversation got marked unread")
	}

	e.open(t, "/c/"+other)
	waitUntil(t, e, "opened", `document.querySelector('#main') && document.querySelector('#main').getAttribute('data-conv') === '`+other+`'`, 5*time.Second)
	if eval[bool](t, e, `!!document.querySelector('`+row+`.unseen')`) {
		t.Error("the open conversation's row is still unread")
	}
	e.open(t, "/chats")
	waitUntil(t, e, "list", `!!document.querySelector('`+row+`')`, 5*time.Second)
	if eval[bool](t, e, `!!document.querySelector('`+row+`.unseen')`) {
		t.Error("the mark came back after the conversation was opened")
	}
}

// In select mode J and K don't tick the checkboxes: they move through
// conversations, and select mode has none to open.
func TestBrowser_ListSelectModeJKDontTick(t *testing.T) {
	e := newBrowserEnv(t)
	e.addConversation(t, "Alpha")
	e.addConversation(t, "Bravo")
	e.open(t, "/chats?select=1")
	waitUntil(t, e, "select mode", `!!document.querySelector('#list[data-select]') && typeof htmx !== 'undefined'`, 5*time.Second)
	e.keys(t, listBlur(), shortcut("j", "KeyJ"), shortcut("j", "KeyJ"), shortcut("k", "KeyK"))
	time.Sleep(300 * time.Millisecond)
	if n := eval[float64](t, e, `document.querySelectorAll('#rows input[name="id"]:checked').length`); n != 0 {
		t.Errorf("J and K ticked %v rows", n)
	}
}

// The search meta row ("N results · titles only", Include archived) sits
// on one line at the list's narrowest, as board ListSearch draws it.
func TestBrowser_ListSearchMetaOneLine(t *testing.T) {
	e := newBrowserEnv(t)
	for i := 0; i < 5; i++ {
		e.addConversation(t, "Tax documents checklist")
	}
	for _, w := range []int64{1440, 1180, 1000} {
		e.keys(t, chromedp.EmulateViewport(w, 900))
		e.open(t, "/chats?q=tax&arch=1")
		// Each label's text on one line, and the switch inside the row's
		// padding, clear of the count.
		for _, sel := range []string{".search-meta [role=status]", "#incarch"} {
			if n := eval[float64](t, e, `(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector('`+sel+`')); return new Set(Array.from(r.getClientRects()).map(x => Math.round(x.top))).size })()`); n != 1 {
				t.Errorf("at %dpx %s wraps onto %v lines", w, sel, n)
			}
		}
		m, sw := e.listRect(t, ".search-meta"), e.listRect(t, ".search-meta .switch")
		st, lbl := e.listRect(t, ".search-meta [role=status]"), e.listRect(t, "#incarch")
		if sw.Right > m.Right-15.5 || st.Right > lbl.Left || sw.Top < m.Top {
			t.Errorf("at %dpx the row (%.0f–%.0f) holds the count to %.0f, the label from %.0f and the switch to %.0f", w, m.Left, m.Right, st.Right, lbl.Left, sw.Right)
		}
	}
}
