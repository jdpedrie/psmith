package web

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

// The list column is swapped whole whenever the account's conversations
// change (another tab, a reply finishing, a row action). These tests drive
// the list across such a swap: whatever the user had going in the column
// has to survive it.

// listChange changes a conversation from the page itself, as another tab
// would, so the server publishes "conversation changed" and every open
// list refreshes. It returns once the old #list element is gone.
func (e *browserEnv) listChange(t *testing.T, id, title string) {
	t.Helper()
	eval[bool](t, e, `(window.__oldList = document.getElementById('list'), true)`)
	eval[bool](t, e, fmt.Sprintf(`(fetch('/chats/%s/rename', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'title=' + encodeURIComponent(%q)}), true)`, id, title))
	waitUntil(t, e, "list refresh", `document.getElementById('list') !== window.__oldList && document.getElementById('list').innerText.includes(`+fmt.Sprintf("%q", title)+`)`, 8*time.Second)
}

// listWaitEvents waits until the account event stream is open, so a change
// made next reaches the page.
func (e *browserEnv) listWaitEvents(t *testing.T) {
	t.Helper()
	eval[bool](t, e, `(window.__sseOpen = false, document.body.addEventListener('htmx:sseOpen', () => window.__sseOpen = true), true)`)
	// The stream may already be open; give it a beat either way.
	end := time.Now().Add(3 * time.Second)
	for time.Now().Before(end) && !eval[bool](t, e, `window.__sseOpen`) {
		time.Sleep(100 * time.Millisecond)
	}
}

// Typing in search after the list refreshed still shows commands.
func TestBrowser_ListSearchWorksAfterRefresh(t *testing.T) {
	e := newBrowserEnv(t)
	other := e.addConversation(t, "Other conversation")
	e.open(t, "/c/"+e.convID)
	e.listWaitEvents(t)
	e.listChange(t, other, "Renamed elsewhere")

	e.keys(t, chromedp.Click(`#search`, chromedp.ByID), chromedp.SendKeys(`#search`, "appearance", chromedp.ByID))
	waitUntil(t, e, "results after refresh", `!!document.querySelector('#command-results [role="option"]') && document.getElementById('list-body').hidden`, 5*time.Second)
}

// A refresh while the user is typing a search keeps what they typed and the
// results under it.
func TestBrowser_ListRefreshKeepsTypedSearch(t *testing.T) {
	e := newBrowserEnv(t)
	other := e.addConversation(t, "Other conversation")
	e.open(t, "/c/"+e.convID)
	e.listWaitEvents(t)
	e.keys(t, chromedp.Click(`#search`, chromedp.ByID), chromedp.SendKeys(`#search`, "appear", chromedp.ByID))
	waitUntil(t, e, "results", `!!document.querySelector('#command-results [role="option"]')`, 5*time.Second)

	eval[bool](t, e, fmt.Sprintf(`(fetch('/chats/%s/rename', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'title=Renamed'}), true)`, other))
	frames := e.listRecord(t, 3*time.Second, `document.getElementById('search').value + '|' + !!document.querySelector('#command-results [role="option"]')`)
	for i, f := range frames {
		if f != "appear|true" {
			t.Fatalf("frame %d: search and results = %q, want the typed query and its results throughout", i, f)
		}
	}
}

// listRecord samples a page expression every 150ms for d.
func (e *browserEnv) listRecord(t *testing.T, d time.Duration, js string) []string {
	t.Helper()
	var out []string
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		out = append(out, eval[string](t, e, js))
		time.Sleep(150 * time.Millisecond)
	}
	return out
}

// A refresh keeps the list where the user scrolled it.
func TestBrowser_ListRefreshKeepsScroll(t *testing.T) {
	e := newBrowserEnv(t)
	var last string
	for i := 0; i < 40; i++ {
		last = e.addConversation(t, fmt.Sprintf("Conversation %02d", i))
	}
	e.open(t, "/chats")
	e.listWaitEvents(t)
	eval[bool](t, e, `(document.getElementById('rows').scrollTop = 600, true)`)
	before := eval[float64](t, e, `document.getElementById('rows').scrollTop`)
	if before < 500 {
		t.Fatalf("list didn't scroll (scrollTop %v); not enough rows", before)
	}
	e.listChange(t, last, "Renamed elsewhere")
	if after := eval[float64](t, e, `document.getElementById('rows').scrollTop`); after != before {
		t.Errorf("list scrollTop after refresh = %v, want %v", after, before)
	}
}

// A row's unsent draft still shows after the list refreshes.
func TestBrowser_ListRefreshKeepsDrafts(t *testing.T) {
	e := newBrowserEnv(t)
	other := e.addConversation(t, "Other conversation")
	e.open(t, "/chats")
	eval[bool](t, e, `(localStorage.setItem('psmith.draft.`+e.convID+`', 'half a thought'), true)`)
	e.open(t, "/chats")
	draft := `document.querySelector('[data-id="` + e.convID + `"] .row-sub').innerText`
	if got := eval[string](t, e, draft); !strings.Contains(got, "half a thought") {
		t.Fatalf("row sub before refresh = %q", got)
	}
	e.listWaitEvents(t)
	e.listChange(t, other, "Renamed elsewhere")
	if got := eval[string](t, e, draft); !strings.Contains(got, "half a thought") {
		t.Errorf("row sub after refresh = %q, want the draft", got)
	}
}

// A refresh held back while search results showed runs when they close, so
// the list doesn't stay stale.
func TestBrowser_ListHeldRefreshRunsAfterSearch(t *testing.T) {
	e := newBrowserEnv(t)
	other := e.addConversation(t, "Other conversation")
	e.open(t, "/chats")
	e.listWaitEvents(t)
	e.keys(t, chromedp.Click(`#search`, chromedp.ByID), chromedp.SendKeys(`#search`, "appear", chromedp.ByID))
	waitUntil(t, e, "results", `!!document.querySelector('#command-results [role="option"]')`, 5*time.Second)
	eval[bool](t, e, fmt.Sprintf(`(fetch('/chats/%s/rename', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'title=Renamed%%20meanwhile'}), true)`, other))
	time.Sleep(time.Second)
	e.keys(t, shortcut("Escape", "Escape"))
	waitUntil(t, e, "caught up", `!document.getElementById('list-body').hidden && document.getElementById('rows').innerText.includes('Renamed meanwhile')`, 5*time.Second)
}
