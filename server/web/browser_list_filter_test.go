package web

import (
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

// Filtering, sorting and searching the list beside an open conversation
// change the list, not what's open.
func TestBrowser_ListFilterKeepsConversationOpen(t *testing.T) {
	e := newBrowserEnv(t)
	e.addConversation(t, "Another one")
	open := `!!document.getElementById('main') && document.getElementById('main').getAttribute('data-conv') === "` + e.convID + `"`

	e.open(t, "/c/"+e.convID)
	e.keys(t, chromedp.Click(`#list .chips a.chip:nth-child(2)`, chromedp.ByQuery))
	waitUntil(t, e, "archived chip keeps the conversation", `new URLSearchParams(location.search).get('f') === 'archived' && `+open, 5*time.Second)

	e.open(t, "/c/"+e.convID)
	e.keys(t, chromedp.SetValue(`#list select[name="sort"]`, "created", chromedp.ByQuery),
		chromedp.Evaluate(`document.querySelector('#list select[name="sort"]').dispatchEvent(new Event('change', {bubbles: true}))`, nil))
	waitUntil(t, e, "sorting keeps the conversation", `new URLSearchParams(location.search).get('sort') === 'created' && `+open, 5*time.Second)

	e.open(t, "/c/"+e.convID)
	e.keys(t, chromedp.Evaluate(`(document.getElementById('search').value = 'Another', document.querySelector('form.search-wrap').submit(), true)`, nil))
	waitUntil(t, e, "a title search keeps the conversation", `new URLSearchParams(location.search).get('q') === 'Another' && `+open, 5*time.Second)
}
