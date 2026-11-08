package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"
	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/fakellm"
	"github.com/jdpedrie/psmith/server/store"
)

// Keyboard behavior, driven with real key events in headless Chrome. These
// are the parts of app.js a server-side test can't see.

// eval reads one value from the page.
func eval[T any](t *testing.T, e *browserEnv, js string) T {
	t.Helper()
	var v T
	if err := chromedp.Run(e.ctx, chromedp.Evaluate(js, &v)); err != nil {
		t.Fatalf("eval %q: %v", js, err)
	}
	return v
}

// waitUntil polls a page condition for up to timeout.
func waitUntil(t *testing.T, e *browserEnv, what, js string, timeout time.Duration) {
	t.Helper()
	end := time.Now().Add(timeout)
	for time.Now().Before(end) {
		if eval[bool](t, e, js) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s: %s never became true", what, js)
}

func (e *browserEnv) open(t *testing.T, path string) {
	t.Helper()
	if err := chromedp.Run(e.ctx, chromedp.Navigate(e.srv.URL+path), chromedp.WaitReady("body")); err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
}

// shortcut presses a single-key shortcut as a browser delivers it: a key-down
// the page can cancel. chromedp's KeyEvent also sends the character
// separately, which lands in whatever field the shortcut just focused.
func shortcut(key, code string) chromedp.Action {
	return chromedp.ActionFunc(func(ctx context.Context) error {
		if err := input.DispatchKeyEvent(input.KeyRawDown).WithKey(key).WithCode(code).Do(ctx); err != nil {
			return err
		}
		return input.DispatchKeyEvent(input.KeyUp).WithKey(key).WithCode(code).Do(ctx)
	})
}

func (e *browserEnv) keys(t *testing.T, actions ...chromedp.Action) {
	t.Helper()
	if err := chromedp.Run(e.ctx, actions...); err != nil {
		t.Fatalf("keys: %v", err)
	}
}

// "/" puts the cursor in search; typing shows commands, conversations and
// settings in place of the list; the arrow keys and Enter run one.
func TestBrowser_SlashSearchRunsACommand(t *testing.T) {
	e := newBrowserEnv(t)
	e.open(t, "/c/"+e.convID)
	e.keys(t, shortcut("/", "Slash"))
	waitUntil(t, e, "slash", `document.activeElement && document.activeElement.id === "search"`, 3*time.Second)

	e.keys(t, chromedp.KeyEvent("appearance"))
	waitUntil(t, e, "results", `!!document.querySelector('#command-results [role="option"]')`, 5*time.Second)
	if eval[bool](t, e, `!document.getElementById('list-body') || !document.getElementById('list-body').hidden`) {
		t.Error("the list stayed visible under the results")
	}
	// The first result is the dark-appearance command; one down is the
	// Appearance settings page.
	e.keys(t, shortcut("ArrowDown", "ArrowDown"), shortcut("Enter", "Enter"))
	waitUntil(t, e, "run", `location.pathname.startsWith("/settings/appearance")`, 5*time.Second)
}

// J and K move through the list, and only while no field has the cursor.
func TestBrowser_JMovesToTheNextConversation(t *testing.T) {
	e := newBrowserEnv(t)
	second := e.addConversation(t, "Second conversation")
	e.open(t, "/c/"+e.convID)
	// The newest conversation is first in the list; ours is the older one.
	e.open(t, "/c/"+second)
	e.keys(t, chromedp.Evaluate(`document.activeElement && document.activeElement.blur()`, nil), shortcut("j", "KeyJ"))
	waitUntil(t, e, "j", `location.pathname === "/c/`+e.convID+`"`, 5*time.Second)
	e.keys(t, shortcut("k", "KeyK"))
	waitUntil(t, e, "k", `location.pathname === "/c/`+second+`"`, 5*time.Second)

	// Typing a j into the composer types it.
	e.keys(t, chromedp.Focus(`#composer-text`, chromedp.ByID), chromedp.KeyEvent("j"))
	time.Sleep(400 * time.Millisecond)
	if p := eval[string](t, e, `location.pathname`); p != "/c/"+second {
		t.Errorf("j in the composer navigated to %s", p)
	}
}

// Esc stops a reply in flight, including straight after sending, while the
// composer still has the cursor.
func TestBrowser_EscStopsTheReply(t *testing.T) {
	e := newBrowserEnv(t)
	var evs []fakellm.Event
	for i := 0; i < 60; i++ {
		evs = append(evs, fakellm.Event{Type: fakellm.EventText, Text: "word ", Delay: 100 * time.Millisecond})
	}
	e.fake.Enqueue(fakellm.Script{Events: evs})
	e.open(t, "/c/"+e.convID)
	e.keys(t, chromedp.SendKeys(`#composer-text`, "Talk for a while", chromedp.ByID), chromedp.KeyEvent(kb.Enter))
	waitUntil(t, e, "streaming", `!!document.querySelector('#messages .reply.live')`, 5*time.Second)

	e.keys(t, shortcut("Escape", "Escape"))
	// Sixty words at 100ms would run six seconds; stopped, the live row
	// settles well before.
	waitUntil(t, e, "stopped", `!document.querySelector('#messages .reply.live')`, 4*time.Second)
	if n := strings.Count(eval[string](t, e, `document.getElementById('messages').innerText`), "word"); n >= 60 {
		t.Errorf("the reply ran to the end (%d words) after Esc", n)
	}
}

// ⌘S saves a page with a save bar: the provider page's defaults.
func TestBrowser_CommandSSaves(t *testing.T) {
	e := newBrowserEnv(t)
	page := "/settings/providers/" + e.providerID
	e.open(t, page)
	e.keys(t,
		chromedp.SetValue(`#maxtok`, "", chromedp.ByID),
		chromedp.SendKeys(`#maxtok`, "4096", chromedp.ByID),
	)
	waitUntil(t, e, "save bar", `!document.querySelector('[data-savebar]').hidden`, 3*time.Second)
	e.keys(t, chromedp.KeyEvent("s", chromedp.KeyModifiers(input.ModifierMeta)))
	// The save posts and reloads the page with nothing left unsaved.
	waitUntil(t, e, "saved", `document.readyState === "complete" && !!document.querySelector('[data-savebar]') && document.querySelector('[data-savebar]').hidden && document.getElementById('maxtok').value.replace(/,/g, '') === "4096"`, 5*time.Second)
	e.open(t, page)
	if v := eval[string](t, e, `document.getElementById('maxtok').value`); strings.ReplaceAll(v, ",", "") != "4096" {
		t.Errorf("max output tokens after ⌘S and reload = %q, want 4096", v)
	}
}

// addConversation seeds another conversation for the signed-in user.
func (e *browserEnv) addConversation(t *testing.T, title string) string {
	t.Helper()
	ctx := context.Background()
	q := e.q
	conv, err := q.GetConversationByID(ctx, uuid.MustParse(e.convID))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := uuid.NewV7()
	c, err := q.CreateConversation(ctx, store.CreateConversationParams{ID: id, UserID: conv.UserID, ProfileID: conv.ProfileID, Title: &title})
	if err != nil {
		t.Fatal(err)
	}
	cx, _ := uuid.NewV7()
	if _, err := q.CreateContext(ctx, store.CreateContextParams{ID: cx, ConversationID: c.ID, ContextActivationTime: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	return c.ID.String()
}
