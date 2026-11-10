package web

import (
	"testing"

	"github.com/chromedp/chromedp"
)

// Below 1180px the inspector is a page: the header's toggle (and I) opens
// it in the conversation's place, tabs stay on the page, and its back
// button returns to the conversation.
func TestBrowser_InspNarrowInspectorIsAPage(t *testing.T) {
	e := newBrowserEnv(t)
	e.keys(t, chromedp.EmulateViewport(1024, 768))
	e.open(t, "/c/"+e.convID)
	if eval[bool](t, e, `(() => { const i = document.getElementById('inspector'); return !!i && getComputedStyle(i).display !== 'none' })()`) {
		t.Fatal("the inspector shows beside the conversation at 1024px")
	}
	e.inspClick(t, "#conv-head [data-toggle-inspector]")
	inspWaitPath(t, e, "/c/"+e.convID+"?tab=context")
	visible := `(sel) => { const el = document.querySelector(sel); if (!el) return false; const r = el.getBoundingClientRect(); return getComputedStyle(el).display !== 'none' && r.width > 0 && r.height > 0 }`
	if !eval[bool](t, e, `(`+visible+`)('#inspector')`) {
		t.Fatal("the inspector page doesn't show the inspector")
	}
	if w := eval[float64](t, e, `document.getElementById('inspector').getBoundingClientRect().width`); w < 700 {
		t.Errorf("the inspector page is %.0fpx wide at 1024px; it should take the page", w)
	}
	if eval[bool](t, e, `(`+visible+`)('#composer-text')`) {
		t.Error("the composer shows under the inspector page")
	}
	e.inspShot(t, "context-page")

	e.inspClick(t, `#inspector [role=tab][href$="?tab=settings"]`)
	inspWaitPath(t, e, "/c/"+e.convID+"?tab=settings")
	if !eval[bool](t, e, `(`+visible+`)('#cs-temperature')`) {
		t.Error("the Settings tab doesn't show on the inspector page")
	}
	if !eval[bool](t, e, `(`+visible+`)('#inspector .insp-page-back')`) {
		t.Fatal("no back button on the inspector page")
	}
	e.inspShot(t, "settings-page")

	// The model card opens the picker as a page; its back returns to the
	// Settings page it came from.
	e.inspClick(t, `#inspector a.model-card`)
	inspWaitPath(t, e, "/c/"+e.convID+"/model")
	if !eval[bool](t, e, `(`+visible+`)('[data-pick-filter]')`) {
		t.Error("the model picker doesn't show as a page at 1024px")
	}
	e.inspShot(t, "model-page")
	e.inspClick(t, `#inspector .insp-page-back`)
	inspWaitPath(t, e, "/c/"+e.convID+"?tab=settings")

	// From a tab, back is the conversation.
	e.inspClick(t, `#inspector .insp-page-back`)
	inspWaitPath(t, e, "/c/"+e.convID)
	if !eval[bool](t, e, `(`+visible+`)('#composer-text')`) {
		t.Error("back from the inspector page didn't land on the conversation")
	}
}
