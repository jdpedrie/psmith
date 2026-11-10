package web

import (
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/kb"

	"github.com/jdpedrie/psmith/fakellm"
)

// The context tab follows the conversation: when a reply lands, its turn
// count, cost and size update without a reload.
func TestBrowser_InspContextTabFollowsReplies(t *testing.T) {
	e := newBrowserEnv(t)
	e.fake.Enqueue(fakellm.Script{
		Events: []fakellm.Event{{Type: fakellm.EventText, Text: "Short answer.", Delay: 100 * time.Millisecond}},
		Usage:  &fakellm.Usage{InputTokens: 1200, OutputTokens: 300},
	})
	e.open(t, "/c/"+e.convID)
	turns := `(() => { const dt = [...document.querySelectorAll('#inspector .stats dt')].find(d => d.innerText === 'Turns'); return dt ? dt.nextElementSibling.innerText : '' })()`
	if got := eval[string](t, e, turns); got != "0" {
		t.Fatalf("turns before sending = %q", got)
	}
	e.keys(t, chromedp.SendKeys(`#composer-text`, "One question", chromedp.ByID), chromedp.KeyEvent(kb.Enter))
	waitUntil(t, e, "reply settles", `document.getElementById('messages').innerText.includes('Short answer.') && !document.querySelector('#messages .reply.live')`, 8*time.Second)

	end := time.Now().Add(4 * time.Second)
	tokens := `document.querySelector('#inspector .ctx-tokens').innerText`
	for time.Now().Before(end) && (eval[string](t, e, turns) != "1" || strings.HasPrefix(eval[string](t, e, tokens), "0 ")) {
		time.Sleep(150 * time.Millisecond)
	}
	if got := eval[string](t, e, turns); got != "1" {
		t.Errorf("the inspector's turn count is %q after the reply, want 1 without a reload", got)
	}
	if got := inspText(t, e, "#inspector .ctx-tokens"); strings.HasPrefix(got, "0 ") {
		t.Errorf("the context size still reads %q after a reply that used 1,500 tokens", got)
	}
	e.inspShot(t, "after-reply")
}
