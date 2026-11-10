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

	"github.com/jdpedrie/psmith/server/store"
)

// The conversation's info view: rename with Enter, pin and archive from
// Actions, and delete through the in-place confirm (Cancel first).
func TestBrowser_InspInfoRenamePinDelete(t *testing.T) {
	e := newBrowserEnv(t)
	page := "/c/" + e.convID + "?tab=info"
	e.open(t, page)
	waitUntil(t, e, "info", `!!document.getElementById('info-title')`, 3*time.Second)
	e.keys(t, chromedp.Click(`#info-title`, chromedp.ByID), chromedp.SendKeys(`#info-title`, "Tidepool notes", chromedp.ByID), chromedp.KeyEvent(kb.Enter))
	var conv store.Conversation
	var err error
	for end := time.Now().Add(4 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
		if conv, err = e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID)); err == nil && inspDeref(conv.Title) == "Tidepool notes" {
			break
		}
	}
	inspWaitPath(t, e, page)
	if err != nil || conv.Title == nil || *conv.Title != "Tidepool notes" {
		t.Fatalf("title after Enter = %q (%v)", inspDeref(conv.Title), err)
	}
	if got := eval[string](t, e, `document.getElementById('info-title').value`); got != "Tidepool notes" {
		t.Errorf("the title field reads %q after saving", got)
	}

	// Pin stays on the info view and flips its label.
	before := inspText(t, e, `#inspector form[action$="/pin"] button`)
	e.inspClick(t, `#inspector form[action$="/pin"] button`)
	waitUntil(t, e, "pinned", fmt.Sprintf(`document.readyState === 'complete' && !!document.querySelector('#inspector form[action$="/pin"] button') && document.querySelector('#inspector form[action$="/pin"] button').innerText !== %q`, before), 5*time.Second)
	if p := eval[string](t, e, `location.pathname + location.search`); p != page {
		t.Errorf("Pin left the info view for %s", p)
	}
	if after := inspText(t, e, `#inspector form[action$="/pin"] button`); after == before {
		t.Errorf("the pin action still reads %q after pinning", after)
	}
	conv, _ = e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID))
	if conv.PinnedAt == nil {
		t.Error("the conversation isn't pinned")
	}

	// Delete: the confirm shows in place; Cancel keeps it; Delete goes.
	e.inspClick(t, `#inspector a.act.danger`)
	waitUntil(t, e, "confirm", `!!document.querySelector('#inspector .confirm')`, 3*time.Second)
	e.inspShot(t, "confirm")
	e.inspClick(t, `#inspector .confirm a.cbtn`)
	waitUntil(t, e, "cancelled", `document.readyState === 'complete' && !document.querySelector('#inspector .confirm') && !!document.querySelector('#inspector a.act.danger')`, 3*time.Second)
	e.inspClick(t, `#inspector a.act.danger`)
	e.inspClick(t, `#inspector .confirm button.del`)
	waitUntil(t, e, "deleted", `document.readyState === 'complete' && !location.pathname.startsWith('/c/')`, 5*time.Second)
	if _, err := e.q.GetConversationByID(context.Background(), uuid.MustParse(e.convID)); err == nil {
		t.Error("the conversation survived Delete")
	}
}

// Generate title with no title model falls back to the derived title, and
// the field shows it when the view comes back.
func TestBrowser_InspInfoGenerateTitle(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID+"?tab=info")
	e.inspClick(t, `#inspector button.info-gen`)
	waitUntil(t, e, "title filled", `!!document.getElementById('info-title') && document.getElementById('info-title').value !== ''`, 5*time.Second)
	if got := eval[string](t, e, `document.getElementById('info-title').value`); !strings.HasPrefix(got, "test (") {
		t.Errorf("the title field reads %q after Generate title", got)
	}
}
