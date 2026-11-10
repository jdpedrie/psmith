package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/store"
)

// The provider page's in-place actions, driven with real clicks: none of them
// may throw away an edit typed elsewhere on the page and not saved yet.

// Replace opens the key field in place and Cancel closes it, keeping a rename
// typed before. Replace used to be a link that reloaded the page.
func TestBrowserSeta_ReplaceKeyKeepsEdits(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/"+e.providerID)
	e.setaType(t, "#pname", "Renamed provider")
	e.setaClick(t, "#keyrow a.btn")
	waitUntil(t, e, "key field", `!!document.querySelector('#pkey')`, 5*time.Second)
	state := `document.querySelector('#pname').value + '|' + location.search + '|' + document.querySelector('[data-dirty-count]').textContent`
	if got := eval[string](t, e, state); got != "Renamed provider||1 unsaved change" {
		t.Fatalf("after Replace: %q", got)
	}
	e.setaType(t, "#pkey", "sk-new-key")
	waitUntil(t, e, "the key counts", `document.querySelector('[data-dirty-count]').textContent === '2 unsaved changes'`, 3*time.Second)

	e.setaClick(t, "#keyrow a.btn")
	waitUntil(t, e, "key row back", `!document.querySelector('#pkey') && !!document.querySelector('#keyrow .secret')`, 5*time.Second)
	if got := eval[string](t, e, state); got != "Renamed provider||1 unsaved change" {
		t.Errorf("after Cancel: %q", got)
	}
}

// At phone width the header's Remove asks in place, keeping a rename typed
// before. It used to be a link that reloaded the page.
func TestBrowserSeta_PhoneRemoveKeepsEdits(t *testing.T) {
	e, _ := newSetaBrowser(t)
	if err := chromedp.Run(e.ctx, chromedp.EmulateViewport(390, 844)); err != nil {
		t.Fatal(err)
	}
	e.open(t, "/settings/providers/"+e.providerID)
	e.setaType(t, "#pname", "Renamed provider")
	e.setaClick(t, ".ptacts a.btn.danger.phone")
	waitUntil(t, e, "confirm", `/Remove .*\?/.test(document.querySelector('#premove').textContent)`, 5*time.Second)
	if got := eval[string](t, e, `document.querySelector('#pname').value + '|' + location.search`); got != "Renamed provider|" {
		e.setaShot(t, "phone-remove")
		t.Errorf("after Remove: %q; the rename was lost", got)
	}
}

// Test on a model row reports in that row and leaves the page as it was.
func TestBrowserSeta_RowTestInPlace(t *testing.T) {
	e, _ := newSetaBrowser(t)
	e.open(t, "/settings/providers/"+e.providerID)
	e.setaType(t, "#pname", "Renamed provider")
	e.setaClick(t, "#model-rows td.mtest button")
	waitUntil(t, e, "row outcome", `/Answered in|Test failed/.test((document.querySelector('#mtest-0 .result')||{}).textContent||'')`, 15*time.Second)
	if got := eval[string](t, e, `document.querySelector('#pname').value + '|' + document.querySelector('[data-savebar]').hidden`); got != "Renamed provider|false" {
		t.Errorf("after Test: %q; the rename was lost", got)
	}
}

// A hand-added model turned off keeps an off row. Its Delete asks in place,
// Cancel puts the row back, and Delete model removes it for good.
func TestBrowserSeta_OffRowDelete(t *testing.T) {
	e, _ := newSetaBrowser(t)
	prov := "/settings/providers/" + e.providerID
	e.open(t, prov)
	e.setaClick(t, `#model-rows button.switch`)
	waitUntil(t, e, "row off", `!!document.querySelector('#model-rows tr.off td.mtest a')`, 5*time.Second)
	e.setaType(t, "#pname", "Renamed provider")

	e.setaClick(t, `#model-rows tr.off td.mtest a`)
	waitUntil(t, e, "row asks", `!!document.querySelector('#model-rows .rowconfirm')`, 5*time.Second)
	if got := eval[string](t, e, `document.querySelector('#model-rows .rowconfirm').textContent`); !strings.Contains(got, "Delete Claude Fake?") {
		t.Errorf("confirm reads %q", got)
	}
	if got := eval[string](t, e, `document.querySelector('#pname').value`); got != "Renamed provider" {
		t.Errorf("Delete threw away the rename: %q", got)
	}
	e.setaClick(t, `#model-rows .rowconfirm a.btn`)
	waitUntil(t, e, "row back", `!document.querySelector('#model-rows .rowconfirm') && !!document.querySelector('#model-rows tr.off')`, 5*time.Second)

	e.setaClick(t, `#model-rows tr.off td.mtest a`)
	waitUntil(t, e, "row asks again", `!!document.querySelector('#model-rows .rowconfirm')`, 5*time.Second)
	e.setaClick(t, `#model-rows .rowconfirm button.destructive`)
	waitUntil(t, e, "row gone", `document.readyState === 'complete' && document.querySelectorAll('#model-rows tr').length === 0`, 5*time.Second)
	if _, err := e.q.GetUserModel(context.Background(), store.GetUserModelParams{UserModelProviderID: uuid.MustParse(e.providerID), ModelID: "claude-fake"}); err == nil {
		t.Error("the model is still stored")
	}
}
