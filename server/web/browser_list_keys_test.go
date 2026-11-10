package web

import (
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

// listBlur takes the cursor out of any field so single-key shortcuts apply.
func listBlur() chromedp.Action {
	return chromedp.Evaluate(`document.activeElement && document.activeElement.blur()`, nil)
}

// The list's single-key shortcuts each land where the shortcuts panel
// says they do.
func TestBrowser_ListShortcutKeys(t *testing.T) {
	e := newBrowserEnv(t)
	cases := []struct {
		key, code, from, want string
	}{
		{"c", "KeyC", "/chats", `location.pathname === "/new"`},
		{",", "Comma", "/chats", `location.pathname.startsWith("/settings")`},
		{"?", "Slash", "/c/" + e.convID, `location.pathname === "/shortcuts" && !!document.getElementById('shortcuts')`},
		{"x", "KeyX", "/chats", `!!document.querySelector('#list[data-select]')`},
		{"j", "KeyJ", "/chats", `location.pathname === "/c/` + e.convID + `"`},
	}
	for _, c := range cases {
		e.open(t, c.from)
		e.keys(t, listBlur(), shortcut(c.key, c.code))
		waitUntil(t, e, c.key+" from "+c.from, c.want+` && document.readyState === 'complete'`, 5*time.Second)
	}

	// Esc leaves select mode and the shortcuts panel.
	e.open(t, "/chats?select=1")
	e.keys(t, listBlur(), shortcut("Escape", "Escape"))
	waitUntil(t, e, "esc leaves select", `!document.querySelector('#list[data-select]') && document.readyState === 'complete'`, 5*time.Second)
	e.open(t, "/shortcuts?c="+e.convID)
	e.keys(t, listBlur(), shortcut("Escape", "Escape"))
	waitUntil(t, e, "esc closes shortcuts", `location.pathname === "/c/`+e.convID+`" && !document.getElementById('shortcuts')`, 5*time.Second)
}
