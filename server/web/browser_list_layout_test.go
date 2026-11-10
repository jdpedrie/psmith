package web

import (
	"testing"

	"github.com/chromedp/chromedp"
)

// listRect reads an element's box.
type listRect struct{ Left, Right, Top, Bottom float64 }

func (e *browserEnv) listRect(t *testing.T, sel string) listRect {
	t.Helper()
	return eval[listRect](t, e, `(() => { const r = document.querySelector(`+"`"+sel+"`"+`).getBoundingClientRect(); return {Left: r.left, Right: r.right, Top: r.top, Bottom: r.bottom} })()`)
}

// A long account name stops short of the connection status instead of
// running under it. The browser env names the user after the test, so
// this test's long name is the case.
func TestBrowser_ListAccountNameDoesntOverlapStatusWithAVeryLongName(t *testing.T) {
	e := newBrowserEnv(t)
	for _, w := range []int64{1440, 1000, 390} {
		e.keys(t, chromedp.EmulateViewport(w, 860))
		e.open(t, "/chats")
		// The text's own box, not the element's: text that overflows
		// paints past a box that fits.
		who := eval[listRect](t, e, `(() => { const el = document.querySelector('.list-foot .who'); const r = document.createRange(); r.selectNodeContents(el); const b = r.getBoundingClientRect(); const c = el.getBoundingClientRect(); return {Left: b.left, Right: getComputedStyle(el).overflow === 'hidden' ? Math.min(b.right, c.right) : b.right} })()`)
		status := e.listRect(t, "#conn-status")
		if who.Right > status.Left {
			t.Errorf("at %dpx the name ends at %.0f, past the status at %.0f", w, who.Right, status.Left)
		}
	}
}

// The shortcuts panel shows at every width. Below 1180px there's no room
// for a third column, so it is the page, as the inspector is.
func TestBrowser_ListShortcutsShowAtEveryWidth(t *testing.T) {
	e := newBrowserEnv(t)
	for _, w := range []int64{1440, 1000, 390} {
		e.keys(t, chromedp.EmulateViewport(w, 860))
		e.open(t, "/shortcuts?c="+e.convID)
		r := e.listRect(t, "#shortcuts")
		if r.Right-r.Left < 280 || r.Left < 0 || r.Right > float64(w)+1 {
			t.Errorf("at %dpx the shortcuts panel spans %.0f–%.0f", w, r.Left, r.Right)
		}
		if !eval[bool](t, e, `document.querySelector('#shortcuts .sc-close').getBoundingClientRect().width > 0`) {
			t.Errorf("at %dpx the close button doesn't show", w)
		}
	}
}

// Opening a conversation far down the list (J, a link, search) shows its
// row: the list loads scrolled to it, not to the top.
func TestBrowser_ListShowsTheOpenRow(t *testing.T) {
	e := newBrowserEnv(t)
	var ids []string
	for i := 0; i < 40; i++ {
		ids = append(ids, e.addConversation(t, "Conversation"))
	}
	far := ids[2] // newest first, so the third made is near the bottom
	e.open(t, "/c/"+far)
	row, list := e.listRect(t, `#rows a.row[aria-current]`), e.listRect(t, "#rows")
	if row.Top < list.Top || row.Bottom > list.Bottom {
		t.Errorf("the open row (%.0f–%.0f) is outside the list's view (%.0f–%.0f)", row.Top, row.Bottom, list.Top, list.Bottom)
	}
}
